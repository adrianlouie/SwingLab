import Foundation

/// Finds the key swing positions within a clip (or, for long clips, within the
/// window `SwingWindowScanner` selected).
///
/// The anchors are deliberately defined by *body position* rather than by
/// speed alone:
///
///   top     — where the hand path reverses direction, not where the hands are
///             highest; for many amateurs the highest point comes a frame or
///             two after the reversal
///   impact  — where the hands return to their address height, with speed only
///             as a cross-check. Defining impact as "fastest frame" is both
///             unreliable (a fast follow-through steals it) and would make the
///             casting check meaningless, since that check is precisely
///             whether hand speed peaks *before* impact
///   address — the last quiet stretch before the top, searched backwards, so a
///             pre-shot waggle can't be mistaken for the setup
///
/// Intermediate checkpoints come from anatomical landmarks (crossing the
/// shoulder line) rather than fractions of the hand-path arc length, which
/// accumulated over waggles and walk-ins.
enum PositionDetector {

    struct Tuning {
        /// Longest plausible downswing, by shot type.
        func maximumDownswing(for shot: ShotType) -> Double {
            switch shot {
            case .fullSwing: return 0.50
            case .pitch: return 0.70
            case .chip, .putt: return 1.20
            }
        }
        /// How long after the fastest frame impact may still occur. Anchoring
        /// to the speed burst rather than the top keeps a pause at the top from
        /// pushing impact outside the search window.
        ///
        /// Wide on purpose: Vision's wrist confidence routinely drops below
        /// the tracking threshold for several frames right through the
        /// fastest part of the downswing (motion blur on the hands/club),
        /// which hides the true speed peak from `indexOfMaximumSpeed` and
        /// anchors "burst" a touch early — confirmed against real footage
        /// where the genuine impact frame (hands back within 0.01 torso
        /// lengths of address height) landed 0.5s after the detected burst,
        /// well outside the old 0.30s allowance, so `findImpact` fell back
        /// to a much worse match at 0.40 confidence instead of finding it.
        var postBurstAllowance = 0.60
        /// Hands count as "back to address height" within this many torso
        /// lengths.
        var impactHeightTolerance = 0.12
        var impactHeightToleranceRelaxed = 0.25
        /// Quiet means below this fraction of peak speed.
        var quietFraction = 0.15
        var quietFloor = 0.5
        /// Address needs this much continuous quiet.
        var addressQuietDuration = 0.25
        /// Finish needs this much continuous quiet, starting at least this far
        /// after impact.
        var finishQuietDuration = 0.30
        var finishMinimumDelay = 0.35
        /// At the top, the hands should not be far below the shoulders.
        var topMinimumLift = -0.35
        /// Below this peak hand speed (torso lengths per second) there is no
        /// swing here at all — just camera noise on someone standing still.
        /// Real swings measure well above 2.
        var minimumPeakSpeed = 0.8
        static let `default` = Tuning()
    }

    // MARK: - Public entry point

    static func detectPositions(frames: [PoseFrame],
                                shotType: ShotType,
                                space: PoseSpace = .square,
                                tuning: Tuning = .default) -> [DetectedPosition] {
        guard frames.count >= 8 else {
            return fallbackPositions(frames: frames, shotType: shotType)
        }

        let signal = SwingSignal.build(frames: frames, space: space)
        guard signal.peakSpeed >= tuning.minimumPeakSpeed,
              let anchors = detectAnchors(signal: signal, shotType: shotType, tuning: tuning) else {
            return fallbackPositions(frames: frames, shotType: shotType)
        }

        var found: [SwingPosition: (index: Int, confidence: Double)] = [
            .address: (anchors.address, anchors.addressConfidence),
            .top: (anchors.top, anchors.topConfidence),
            .impact: (anchors.impact, anchors.impactConfidence),
            .finish: (anchors.finish, anchors.finishConfidence),
        ]

        // Takeaway: hands a quarter of the way up to the top.
        if let takeaway = heightFraction(0.25, from: anchors.address, to: anchors.top, signal: signal) {
            found[.takeaway] = (takeaway, 0.7)
        }
        // Halfway back / wrist hinge: hands cross the shoulder line going up.
        if let halfway = shoulderLineCrossing(from: anchors.address, to: anchors.top,
                                              signal: signal, rising: true) {
            found[.halfwayBack] = (halfway, 0.7)
        } else if let halfway = heightFraction(0.62, from: anchors.address, to: anchors.top, signal: signal) {
            found[.halfwayBack] = (halfway, 0.4)
        }
        // Transition: a beat after the top.
        found[.transition] = (indexAfter(anchors.top, seconds: 0.06, limit: anchors.impact, signal: signal), 0.6)
        // Delivery: hands cross the shoulder line coming down. This is where
        // plane deviation is measured, so it matters more than the others.
        if let delivery = shoulderLineCrossing(from: anchors.top, to: anchors.impact,
                                               signal: signal, rising: false) {
            found[.delivery] = (delivery, 0.7)
        } else if let delivery = heightFraction(0.70, from: anchors.top, to: anchors.impact, signal: signal) {
            found[.delivery] = (delivery, 0.4)
        }

        // Assemble in swing order and force chronology, so the UI can never
        // show positions that go backwards in time.
        var results: [DetectedPosition] = []
        var previousIndex = -1
        for position in shotType.positions {
            guard var entry = found[position] else { continue }
            if entry.index <= previousIndex {
                entry.index = min(previousIndex + 1, frames.count - 1)
                entry.confidence *= 0.5
            }
            guard frames.indices.contains(entry.index) else { continue }
            previousIndex = entry.index
            results.append(DetectedPosition(position: position,
                                            frameIndex: entry.index,
                                            time: frames[entry.index].time,
                                            confidence: entry.confidence))
        }
        return results
    }

    // MARK: - Anchors

    struct Anchors {
        var address: Int
        var top: Int
        var impact: Int
        var finish: Int
        var addressConfidence: Double = 1
        var topConfidence: Double = 1
        var impactConfidence: Double = 1
        var finishConfidence: Double = 1
    }

    static func detectAnchors(signal: SwingSignal,
                              shotType: ShotType,
                              tuning: Tuning = .default) -> Anchors? {
        let peak = signal.peakSpeed
        guard peak > 0 else { return nil }

        // The fastest frame is somewhere in the downswing — useful as a
        // landmark, but never as impact itself.
        guard let burst = indexOfMaximumSpeed(in: signal) else { return nil }

        guard let top = findTop(before: burst, signal: signal, tuning: tuning) else { return nil }
        let topLift = signal.lift[top] ?? 0
        let topConfidence = topLift >= tuning.topMinimumLift ? 1.0 : 0.5

        let address = findAddress(before: top, signal: signal, tuning: tuning)
        let (impact, impactConfidence) = findImpact(after: top, burst: burst, address: address.index,
                                                    signal: signal, shotType: shotType, tuning: tuning)
        let finish = findFinish(after: impact, signal: signal, tuning: tuning)

        return Anchors(address: address.index,
                       top: top,
                       impact: impact,
                       finish: finish,
                       addressConfidence: address.confidence,
                       topConfidence: topConfidence,
                       impactConfidence: impactConfidence,
                       finishConfidence: finish < signal.count - 1 ? 1.0 : 0.6)
    }

    private static func indexOfMaximumSpeed(in signal: SwingSignal) -> Int? {
        var best: Int?
        var bestValue = -Double.infinity
        for i in signal.speed.indices {
            guard let s = signal.speed[i], signal.quality[i] > 0.4 else { continue }
            if s > bestValue { bestValue = s; best = i }
        }
        return best
    }

    /// The top is where the hand path reverses into the downswing: the last
    /// time the velocity's component along the downswing direction crosses
    /// zero before the fastest frame.
    static func findTop(before burst: Int, signal: SwingSignal, tuning: Tuning) -> Int? {
        guard burst > 0, let down = signal.velocity[burst] else { return nil }
        let magnitude = (down.x * down.x + down.y * down.y).squareRoot()
        guard magnitude > 0 else { return nil }
        let ux = down.x / magnitude, uy = down.y / magnitude

        var candidate: Int?
        var i = burst
        while i > 0 {
            i -= 1
            guard let v = signal.velocity[i] else { continue }
            let along = v.x * ux + v.y * uy
            if along <= 0 { candidate = i; break }
        }
        guard var top = candidate else { return nil }

        // Snap to the nearby speed minimum: the reversal instant is the
        // slowest moment of the swing.
        let searchWindow = 0.15
        var bestIndex = top
        var bestSpeed = signal.speed[top] ?? .infinity
        var j = top
        while j > 0, signal.times[top] - signal.times[j] <= searchWindow {
            if let s = signal.speed[j], s < bestSpeed { bestSpeed = s; bestIndex = j }
            j -= 1
        }
        j = top
        while j < signal.count - 1, signal.times[j] - signal.times[top] <= searchWindow, j < burst {
            if let s = signal.speed[j], s < bestSpeed { bestSpeed = s; bestIndex = j }
            j += 1
        }
        top = bestIndex
        return top < burst ? top : max(0, burst - 1)
    }

    /// Searched backwards from the top. A waggle is motion, so the last quiet
    /// stretch ends after it — which is exactly where the real setup is.
    static func findAddress(before top: Int, signal: SwingSignal,
                            tuning: Tuning) -> (index: Int, confidence: Double) {
        let quietLevel = max(tuning.quietFraction * signal.peakSpeed, tuning.quietFloor)
        var quietEnd: Int?
        var i = top

        while i > 0 {
            i -= 1
            let speed = signal.speed[i]
            let isQuiet = (speed ?? .infinity) < quietLevel
                && signal.quality[i] > 0.5
                && (signal.lift[i] ?? -1) < -0.10   // hands low: a real setup

            if isQuiet {
                if quietEnd == nil { quietEnd = i }
                if let end = quietEnd,
                   signal.times[end] - signal.times[i] >= tuning.addressQuietDuration {
                    // Use the last frame of the quiet run — the instant before
                    // the takeaway starts.
                    return (end, 1.0)
                }
            } else {
                quietEnd = nil
            }
        }

        // Nothing quiet enough. Fall back to a plausible backswing before the
        // top and flag it as uncertain.
        let fallback = indexBefore(top, seconds: 0.8, signal: signal)
        return (fallback, 0.4)
    }

    /// Impact is positional: the hands come back to the height they started at.
    ///
    /// The search window is measured from the fastest frame rather than from
    /// the top, because a golfer who pauses at the top would otherwise push the
    /// real impact outside a top-relative window.
    static func findImpact(after top: Int, burst: Int, address: Int, signal: SwingSignal,
                           shotType: ShotType, tuning: Tuning) -> (Int, Double) {
        let fromTop = signal.times[top] + tuning.maximumDownswing(for: shotType)
        let fromBurst = signal.times[max(burst, top)] + tuning.postBurstAllowance
        let limitTime = max(fromTop, fromBurst)
        let addressHeight = signal.hands[address]?.y

        var searchEnd = top
        while searchEnd < signal.count - 1, signal.times[searchEnd + 1] <= limitTime {
            searchEnd += 1
        }
        guard searchEnd > top else { return (min(top + 1, signal.count - 1), 0.3) }

        // Picks the CLOSEST-to-address-height frame within tolerance, not
        // the fastest — the most literal reading of this function's own
        // documented model ("hands return to their address height").
        //
        // Confirmed against real footage (`IMG_5337.mov`, right-handed
        // full-swing iron): hand speed routinely *peaks before* true impact
        // — the wrists "release" through the last part of the downswing, so
        // the hands are already decelerating by the time the club actually
        // reaches the ball (a normal golf biomechanics effect, not a
        // tracking artifact). That real clip had three frames land within
        // the strict height tolerance on the way down (t=22.267, 22.300,
        // 22.333); picking by max speed grabbed the *first* (fastest, but
        // earliest, and not even the closest height match) one — 233ms
        // before the visually-confirmed impact frame (verified via
        // extracted stills against the source video). Picking the closest
        // height match instead lands on t=22.300 (only 7ms off the exact
        // address-height crossing) — closer to the true impact, though not
        // exact: this golfer's true impact hand height sits outside even
        // the relaxed tolerance, a separate, deeper limitation of "hands
        // return to address height" as an impact proxy that this doesn't
        // fully close (see CLAUDE.md "impact detection: hand-height proxy
        // limits").
        //
        // Deliberately NOT "latest within tolerance": a first attempt at
        // this fix tried that and broke `testImpactSearchReachesPastAWristTrackingGap`
        // (a prior, real-footage-confirmed fix of its own) — that synthetic
        // case has hand height pass a near-exact address-height match and
        // keep drifting further away afterward, same shape as this real
        // clip's own data, and "latest" would have walked right past the
        // genuine best match to grab a worse, later one. "Closest" is what
        // both real cases actually need.
        func bestCandidate(tolerance: Double) -> Int? {
            guard let addressHeight else { return nil }
            var best: Int?
            var bestDelta = Double.infinity
            for i in (top + 1)...searchEnd {
                guard let h = signal.hands[i]?.y, signal.speed[i] != nil else { continue }
                let delta = abs(h - addressHeight)
                if delta <= tolerance, delta < bestDelta {
                    bestDelta = delta
                    best = i
                }
            }
            return best
        }

        var confidence = 1.0
        var impact = bestCandidate(tolerance: tuning.impactHeightTolerance)
        if impact == nil {
            impact = bestCandidate(tolerance: tuning.impactHeightToleranceRelaxed)
            confidence = 0.6
        }
        if impact == nil, let addressHeight {
            // Nothing came close; take whichever frame got nearest.
            var best = top + 1
            var bestDelta = Double.infinity
            for i in (top + 1)...searchEnd {
                guard let h = signal.hands[i]?.y else { continue }
                let d = abs(h - addressHeight)
                if d < bestDelta { bestDelta = d; best = i }
            }
            impact = best
            confidence = 0.4
        }
        guard let result = impact else { return (min(top + 1, signal.count - 1), 0.3) }

        // Cross-check against speed: impact should be near the fastest part of
        // the downswing. If it isn't, we're less sure.
        let downswingPeak = ((top + 1)...searchEnd).compactMap { signal.speed[$0] }.max() ?? 0
        if let s = signal.speed[result], downswingPeak > 0 {
            let ratio = s / downswingPeak
            if ratio < 0.5 { confidence = min(confidence, 0.5) }
        }
        return (result, confidence)
    }

    static func findFinish(after impact: Int, signal: SwingSignal, tuning: Tuning) -> Int {
        let quietLevel = max(0.12 * signal.peakSpeed, tuning.quietFloor)
        var quietStart: Int?
        var i = impact

        while i < signal.count - 1 {
            i += 1
            guard signal.times[i] - signal.times[impact] >= tuning.finishMinimumDelay else { continue }
            let isQuiet = (signal.speed[i] ?? .infinity) < quietLevel
            if isQuiet {
                if quietStart == nil { quietStart = i }
                if let start = quietStart,
                   signal.times[i] - signal.times[start] >= tuning.finishQuietDuration {
                    return start
                }
            } else {
                quietStart = nil
            }
        }
        return signal.count - 1
    }

    // MARK: - Intermediate checkpoints

    /// First frame where the hands have risen a given fraction of the way from
    /// address height to top height.
    static func heightFraction(_ fraction: Double, from start: Int, to end: Int,
                               signal: SwingSignal) -> Int? {
        guard end > start,
              let low = signal.hands[start]?.y,
              let high = signal.hands[end]?.y else { return nil }
        let target = low + (high - low) * fraction
        let rising = high >= low
        for i in start...end {
            guard let h = signal.hands[i]?.y else { continue }
            if rising ? (h >= target) : (h <= target) { return i }
        }
        return nil
    }

    /// Where the hands cross the shoulder line — a checkpoint a coach would
    /// actually name, rather than a fraction of an arc length that a waggle
    /// can distort.
    static func shoulderLineCrossing(from start: Int, to end: Int,
                                     signal: SwingSignal, rising: Bool) -> Int? {
        guard end > start else { return nil }
        let range = rising ? Array(start...end) : Array((start...end).reversed())
        for i in range {
            guard let hands = signal.hands[i]?.y,
                  let shoulder = signal.shoulderHeight[i] else { continue }
            if hands >= shoulder - 0.05 {
                return i
            }
        }
        return nil
    }

    static func indexAfter(_ index: Int, seconds: Double, limit: Int, signal: SwingSignal) -> Int {
        var i = index
        while i < min(limit, signal.count - 1), signal.times[i] - signal.times[index] < seconds {
            i += 1
        }
        return max(index + 1 <= limit ? min(i, limit) : index, index)
    }

    static func indexBefore(_ index: Int, seconds: Double, signal: SwingSignal) -> Int {
        var i = index
        while i > 0, signal.times[index] - signal.times[i] < seconds { i -= 1 }
        return i
    }

    /// When the clip is too short or the pose too sparse, spread the positions
    /// evenly so the user can still place them by hand.
    static func fallbackPositions(frames: [PoseFrame], shotType: ShotType) -> [DetectedPosition] {
        guard !frames.isEmpty else { return [] }
        let positions = shotType.positions
        return positions.enumerated().map { i, position in
            let idx = min(frames.count - 1, i * max(1, frames.count / max(1, positions.count)))
            return DetectedPosition(position: position, frameIndex: idx,
                                    time: frames[idx].time, confidence: 0.2)
        }
    }
}
