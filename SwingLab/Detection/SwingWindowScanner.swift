import Foundation

/// One plausible swing found inside a longer clip.
struct SwingCandidate: Codable, Identifiable, Equatable {
    /// Best guess at the top of the backswing — the most distinctive instant.
    var topTime: Double
    var start: Double
    var end: Double
    /// 0...1, higher is more clearly a full swing.
    var score: Double
    /// Whether `growForwards` found genuine sustained quiet after the
    /// downswing burst, as opposed to simply running out of signal to look
    /// at (`fallbackWindow` and a search that hit `maximumTrail` both leave
    /// this `false`). Meaningless for a complete, already-recorded clip —
    /// only `StreamingSwingDetector` reads it, to tell "this swing is
    /// genuinely over" apart from "the buffer just hasn't grown far enough
    /// yet to know," which otherwise look identical.
    var endConfirmedQuiet: Bool = true

    var id: String { String(format: "%.3f", topTime) }
    var range: ClosedRange<Double> { start...min(end, start + 30) }
    var duration: Double { end - start }
}

/// Locates swings inside a clip that may be minutes long.
///
/// Real test clips are 27 seconds of walking in, setting up, waggling, one
/// swing, and reacting. The old detector assumed the whole clip *was* the
/// swing and called the fastest frame in it "impact", which is why the reported
/// positions were scattered across twenty seconds of standing around.
///
/// The signal is deliberately body-relative — hand position measured against
/// the golfer's own torso, with their overall movement subtracted — so walking
/// across the frame, which moves the hands a long way in absolute terms, barely
/// registers. The decisive feature is the hands rising **above the neck**,
/// which essentially never happens except in a golf backswing.
enum SwingWindowScanner {

    struct Tuning {
        /// Hands must clear the neck by this much (in torso lengths).
        var liftThreshold = 0.05
        /// Candidates closer together than this are the same swing.
        var minimumSeparation = 1.5
        /// How far either side of the top to include. The lead is generous
        /// because some golfers hold a long pause at the top, and the setup we
        /// need is on the far side of it — and because a slow, deliberate
        /// backswing (rehearsal-paced, or a slow-motion recording) can take
        /// several times longer than the ~1-1.5s a real-time backswing does.
        /// Confirmed against real footage: a genuine address-to-top stretch
        /// of ~9s, well past a 5s lead.
        var maximumLead = 10.0
        var maximumTrail = 3.0
        /// The window must reach back to a moment where the hands are clearly
        /// below the shoulders — otherwise a pause at the top looks just as
        /// quiet as the address and the window starts mid-swing.
        var addressLiftCeiling = -0.20
        var padding = 0.25
        /// Keep candidates scoring at least this fraction of the best.
        var relativeKeepThreshold = 0.55
        /// A finish position also puts the hands above the neck, so a lift peak
        /// only counts as a top if a fast downswing follows it within this long.
        var downswingWindow = 0.7
        /// How far back to look when deciding whether the fast part of the
        /// motion came before or after this peak.
        var preSwingWindow = 0.6
        /// A genuine top has its burst *after* it (the downswing). A finish has
        /// its burst *before* it (the strike). Comparing the two windows is
        /// robust to the coarse scan's aliasing, because both are aliased
        /// equally — unlike comparing against the clip's global peak.
        var afterVersusBeforeRatio = 0.9
        /// Absolute floor so camera noise on a still golfer can't qualify.
        var minimumDownswingEnergy = 0.25
        static let `default` = Tuning()
    }

    struct Result {
        var candidates: [SwingCandidate]
        /// Highest-scoring candidate, or a fallback window if none stood out.
        var best: SwingCandidate?
        /// True when nothing looked clearly like a full swing.
        var isLowConfidence: Bool
    }

    // MARK: - Entry point

    static func scan(frames: [PoseFrame],
                     space: PoseSpace,
                     clipDuration: Double,
                     tuning: Tuning = .default) -> Result {
        let signal = buildSignal(frames: frames, space: space)
        let candidates = findCandidates(signal: signal, tuning: tuning)

        guard !candidates.isEmpty else {
            return Result(candidates: [],
                          best: fallbackWindow(signal: signal, clipDuration: clipDuration),
                          isLowConfidence: true)
        }

        // Ties go to the later swing: on a range session the keeper is usually
        // the last ball hit.
        let best = candidates.max { a, b in
            a.score == b.score ? a.topTime < b.topTime : a.score < b.score
        }
        return Result(candidates: candidates, best: best, isLowConfidence: false)
    }

    // MARK: - Signal

    struct Signal {
        var times: [Double]
        /// Hand position relative to the hips, scaled by torso length.
        var handsBody: [(x: Double, y: Double)?]
        /// Hand height above the neck, in torso lengths. Positive means the
        /// hands are higher than the shoulders — a backswing.
        var lift: [Double?]
        /// Speed of the body-relative hand position, in torso lengths/second.
        var energy: [Double?]
        var quality: [Double]
        /// Median torso length across the clip; per-frame is too noisy.
        var scale: Double
    }

    static func buildSignal(frames: [PoseFrame], space: PoseSpace) -> Signal {
        let scale = PoseKinematics.medianTorsoScale(frames: frames, space: space)

        var handsBody: [(x: Double, y: Double)?] = []
        var lift: [Double?] = []
        var quality: [Double] = []

        for frame in frames {
            let k = PoseKinematics.frameKinematics(frame: frame, space: space, scale: scale)
            handsBody.append(k.handsBody)
            lift.append(k.lift)
            quality.append(k.quality)
        }

        var energy: [Double?] = Array(repeating: nil, count: frames.count)
        for i in 1..<max(frames.count, 1) {
            guard let a = handsBody[i - 1], let b = handsBody[i] else { continue }
            let dt = frames[i].time - frames[i - 1].time
            guard dt > 0 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            energy[i] = (dx * dx + dy * dy).squareRoot() / dt
        }

        return Signal(times: frames.map(\.time),
                      handsBody: handsBody,
                      lift: lift,
                      energy: energy,
                      quality: quality,
                      scale: scale)
    }

    // MARK: - Candidates

    static func findCandidates(signal: Signal, tuning: Tuning) -> [SwingCandidate] {
        guard !signal.times.isEmpty else { return [] }

        let peakEnergy = signal.energy.compactMap { $0 }.max() ?? 0
        guard peakEnergy > 0 else { return [] }

        // Local maxima of hand lift, which is where a top-of-backswing lives.
        var peaks: [Int] = []
        for i in signal.lift.indices {
            guard let value = signal.lift[i], value > tuning.liftThreshold else { continue }
            let prev = i > 0 ? (signal.lift[i - 1] ?? -.infinity) : -.infinity
            let next = i < signal.lift.count - 1 ? (signal.lift[i + 1] ?? -.infinity) : -.infinity
            if value >= prev && value >= next { peaks.append(i) }
        }
        guard !peaks.isEmpty else { return [] }

        // Tell a top from a finish for every raw local max BEFORE collapsing
        // duplicates. Both raise the hands above the neck, so the giveaway is
        // which side the fast motion is on: the downswing follows a top,
        // whereas the strike precedes a finish. This must run before
        // grouping: on a slow backswing (a deliberate slow-tempo rehearsal,
        // or a slow-motion recording) the hands often finish *higher* than
        // they were at the actual top, so "keep whichever peak has the
        // higher raw lift" — if done first — throws away the real top in
        // favor of the finish, which then fails this exact test and drops
        // the whole swing. Confirmed against real footage: the true top
        // (immediately followed by a >9-energy downswing burst) had lift
        // 0.53; the finish 1.5s later had lift 0.62 and no burst after it,
        // so grouping-first found zero valid swings in a clip that plainly
        // has one.
        let tops = peaks.filter { peak in
            var maxAfter = 0.0
            var i = peak
            while i < signal.times.count - 1,
                  signal.times[i] - signal.times[peak] <= tuning.downswingWindow {
                i += 1
                if let e = signal.energy[i] { maxAfter = max(maxAfter, e) }
            }
            var maxBefore = 0.0
            var j = peak
            while j > 0, signal.times[peak] - signal.times[j] <= tuning.preSwingWindow {
                j -= 1
                if let e = signal.energy[j] { maxBefore = max(maxBefore, e) }
            }
            return maxAfter >= peakEnergy * tuning.minimumDownswingEnergy
                && maxAfter >= maxBefore * tuning.afterVersusBeforeRatio
        }
        guard !tops.isEmpty else { return [] }

        // Now collapse tops belonging to the same swing, keeping the highest.
        var grouped: [Int] = []
        for peak in tops {
            if let last = grouped.last,
               signal.times[peak] - signal.times[last] < tuning.minimumSeparation {
                if (signal.lift[peak] ?? 0) > (signal.lift[last] ?? 0) {
                    grouped[grouped.count - 1] = peak
                }
            } else {
                grouped.append(peak)
            }
        }

        var candidates: [SwingCandidate] = []
        for peak in grouped {
            let quietLevel = max(0.15 * peakEnergy, 0.4)
            let start = growBackwards(from: peak, signal: signal,
                                      quietLevel: quietLevel, limit: tuning.maximumLead,
                                      liftCeiling: tuning.addressLiftCeiling)
            let end = growForwards(from: peak, signal: signal,
                                   quietLevel: quietLevel, limit: tuning.maximumTrail)

            let windowIndices = start...end
            let localPeak = windowIndices.compactMap { signal.energy[$0] }.max() ?? 0
            let meanQuality = windowIndices.map { signal.quality[$0] }.reduce(0, +) / Double(windowIndices.count)
            let liftValue = signal.lift[peak] ?? 0

            // A window running off either end of the clip is probably a swing
            // we only partly captured.
            let hitTrailBoundary = end == signal.times.count - 1
            let clipped = (start == 0 || hitTrailBoundary)
            let edgePenalty = clipped ? 0.7 : 1.0

            let score = min(1.0, localPeak / max(peakEnergy, 0.0001))
                * min(1.0, liftValue / 0.35)
                * meanQuality
                * edgePenalty

            candidates.append(SwingCandidate(
                topTime: signal.times[peak],
                start: max(0, signal.times[start] - tuning.padding),
                end: signal.times[end] + tuning.padding,
                score: score,
                // Did `growForwards` actually confirm sustained quiet after
                // the burst, or just run out of buffered signal to look at?
                // Offline this is only ever cosmetic (folded into
                // `edgePenalty` above) because the whole clip already
                // exists — live, `StreamingSwingDetector` depends on this
                // to tell "the swing is genuinely over" apart from "not
                // enough frames have arrived yet to know," which look
                // identical from timing alone once padding is added.
                endConfirmedQuiet: !hitTrailBoundary))
        }

        guard let bestScore = candidates.map(\.score).max(), bestScore > 0 else { return [] }
        return candidates
            .filter { $0.score >= bestScore * tuning.relativeKeepThreshold }
            .sorted { $0.topTime < $1.topTime }
    }

    /// Walks back to the setup. "Quiet" alone isn't enough to identify it —
    /// a golfer who pauses at the top is just as still there as at address —
    /// so the hands must also be down below the shoulders.
    private static func growBackwards(from index: Int, signal: Signal,
                                      quietLevel: Double, limit: Double,
                                      liftCeiling: Double) -> Int {
        let topTime = signal.times[index]
        var i = index
        var quietSince: Int?
        var lastLowHands = index
        while i > 0 {
            i -= 1
            if topTime - signal.times[i] > limit { break }
            let handsAreDown = (signal.lift[i] ?? 0) < liftCeiling
            if handsAreDown { lastLowHands = i }
            let e = signal.energy[i] ?? 0
            if e < quietLevel && handsAreDown {
                if quietSince == nil { quietSince = i }
                if let q = quietSince, signal.times[q] - signal.times[i] >= 0.3 { return i }
            } else {
                quietSince = nil
            }
        }
        // No settled setup found; at least reach back to where the hands were
        // last down, rather than starting the window mid-swing.
        return min(i, lastLowHands)
    }

    /// A real downswing burst always follows the top; quiet-based
    /// termination is only trusted once we're clearly past it, with some
    /// room held open for the follow-through. Without that floor, a brief
    /// lull the coarse 12Hz scan happens to catch right after impact reads
    /// as "done" and truncates the window there — which leaves
    /// `PositionDetector.findFinish` nothing after impact to search,
    /// collapsing "finish" onto "impact" on real footage (confirmed against
    /// a swing where growForwards stopped one frame past the strike).
    private static func growForwards(from index: Int, signal: Signal,
                                     quietLevel: Double, limit: Double) -> Int {
        let topTime = signal.times[index]
        let burstLevel = quietLevel * 2
        let minimumTrailAfterBurst = 0.6
        var i = index
        var quietSince: Int?
        var burstTime: Double?
        while i < signal.times.count - 1 {
            i += 1
            if signal.times[i] - topTime > limit { break }
            let e = signal.energy[i] ?? 0

            guard let seenBurst = burstTime else {
                if e >= burstLevel { burstTime = signal.times[i] }
                continue
            }

            let pastMinimumTrail = signal.times[i] - seenBurst >= minimumTrailAfterBurst
            if e < quietLevel && pastMinimumTrail {
                if quietSince == nil { quietSince = i }
                if let q = quietSince, signal.times[i] - signal.times[q] >= 0.4 { return i }
            } else if e >= quietLevel {
                quietSince = nil
            }
        }
        return i
    }

    /// Nothing looked like a full swing — centre a window on the busiest moment
    /// so the user still gets something to correct.
    private static func fallbackWindow(signal: Signal, clipDuration: Double) -> SwingCandidate? {
        guard !signal.times.isEmpty else { return nil }
        var bestIndex = 0
        var bestEnergy = -Double.infinity
        for (i, e) in signal.energy.enumerated() {
            if let e, e > bestEnergy { bestEnergy = e; bestIndex = i }
        }
        let center = signal.times[bestIndex]
        return SwingCandidate(topTime: center,
                              start: max(0, center - 2.0),
                              end: min(clipDuration, center + 2.0),
                              score: 0,
                              endConfirmedQuiet: false)
    }
}
