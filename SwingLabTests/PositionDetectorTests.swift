import XCTest
@testable import SwingLab

/// Synthetic swings for detection tests.
///
/// Deliberately messy, because real footage is: the golfer walks into frame,
/// waggles, sets up, pauses at the top (some golfers do, for nearly a second), and
/// reacts afterwards. The old fixture was a clean swing and nothing else, which
/// is why it passed while the detector failed on real clips.
enum SwingFixture {

    struct Options {
        var fps: Double = 30
        var includeWalkIn = true
        var includeWaggle = true
        var addressHold = 0.8
        var backswing = 0.8
        var topPause = 0.0
        var downswing = 0.30
        var followThrough = 0.6
        var finishHold = 0.8
        /// Hands travel from x=0.5 to this, and up to this height.
        var topHandsX = 0.30
        var topHandsY = 0.92
        var addressHandsY = 0.46
    }

    /// Hand path over one full swing, plus the noise around it.
    static func frames(_ options: Options = Options()) -> [PoseFrame] {
        var out: [PoseFrame] = []
        let dt = 1.0 / options.fps
        var t = 0.0

        func emit(handsX: Double, handsY: Double, bodyX: Double = 0.5) {
            out.append(makeFrame(time: t, handsX: handsX, handsY: handsY, bodyX: bodyX))
            t += dt
        }

        // Walking in from the left: the hands move a long way in absolute
        // terms, which is exactly what fooled the old absolute-speed signal.
        if options.includeWalkIn {
            let steps = Int(1.2 / dt)
            for i in 0..<steps {
                let p = Double(i) / Double(steps)
                emit(handsX: 0.15 + 0.35 * p, handsY: options.addressHandsY, bodyX: 0.15 + 0.35 * p)
            }
        }

        // A waggle: small, quick, and before the real setup.
        if options.includeWaggle {
            let steps = Int(0.6 / dt)
            for i in 0..<steps {
                let p = Double(i) / Double(steps)
                emit(handsX: 0.5 + 0.03 * sin(p * .pi * 4), handsY: options.addressHandsY)
            }
        }

        // Settled address.
        for _ in 0..<Int(options.addressHold / dt) {
            emit(handsX: 0.5, handsY: options.addressHandsY)
        }

        // Backswing.
        let backSteps = max(Int(options.backswing / dt), 2)
        for i in 1...backSteps {
            let p = Double(i) / Double(backSteps)
            let eased = sin(p * .pi / 2)
            emit(handsX: 0.5 + (options.topHandsX - 0.5) * eased,
                 handsY: options.addressHandsY + (options.topHandsY - options.addressHandsY) * eased)
        }

        // Pause at the top.
        for _ in 0..<Int(options.topPause / dt) {
            emit(handsX: options.topHandsX, handsY: options.topHandsY)
        }

        // Downswing back through the ball.
        let downSteps = max(Int(options.downswing / dt), 2)
        for i in 1...downSteps {
            let p = Double(i) / Double(downSteps)
            emit(handsX: options.topHandsX + (0.52 - options.topHandsX) * p,
                 handsY: options.topHandsY + (options.addressHandsY - options.topHandsY) * p)
        }

        // Follow-through to a high finish.
        let throughSteps = max(Int(options.followThrough / dt), 2)
        for i in 1...throughSteps {
            let p = Double(i) / Double(throughSteps)
            emit(handsX: 0.52 + 0.16 * p, handsY: options.addressHandsY + 0.44 * p)
        }

        // Standing there afterwards.
        for _ in 0..<Int(options.finishHold / dt) {
            emit(handsX: 0.68, handsY: options.addressHandsY + 0.44)
        }

        return out
    }

    /// A full skeleton, so confidence and torso-length checks behave as they
    /// do on real footage.
    static func makeFrame(time: Double, handsX: Double, handsY: Double, bodyX: Double) -> PoseFrame {
        func p(_ x: Double, _ y: Double, _ c: Double = 0.9) -> JointPoint {
            JointPoint(x: x, y: y, confidence: c)
        }
        return PoseFrame(time: time, joints: [
            .nose: p(bodyX + 0.02, 0.88),
            .leftEar: p(bodyX - 0.01, 0.885),
            .rightEar: p(bodyX + 0.05, 0.885),
            .neck: p(bodyX, 0.80),
            .leftShoulder: p(bodyX - 0.07, 0.78),
            .rightShoulder: p(bodyX + 0.07, 0.78),
            .leftElbow: p(bodyX - 0.06, 0.62),
            .rightElbow: p(bodyX + 0.06, 0.62),
            .leftWrist: p(handsX - 0.015, handsY),
            .rightWrist: p(handsX + 0.015, handsY),
            .root: p(bodyX, 0.50),
            .leftHip: p(bodyX - 0.05, 0.50),
            .rightHip: p(bodyX + 0.05, 0.50),
            .leftKnee: p(bodyX - 0.05, 0.27),
            .rightKnee: p(bodyX + 0.05, 0.27),
            .leftAnkle: p(bodyX - 0.05, 0.04),
            .rightAnkle: p(bodyX + 0.05, 0.04),
        ])
    }
}

final class PositionDetectorTests: XCTestCase {

    private func detect(_ options: SwingFixture.Options = .init(),
                        shot: ShotType = .fullSwing) -> [DetectedPosition] {
        PositionDetector.detectPositions(frames: SwingFixture.frames(options), shotType: shot)
    }

    private func position(_ p: SwingPosition, in list: [DetectedPosition]) -> DetectedPosition? {
        list.first { $0.position == p }
    }

    // MARK: - Basics

    func testDetectsEveryFullSwingPosition() {
        let found = detect()
        XCTAssertEqual(Set(found.map(\.position)), Set(ShotType.fullSwing.positions))
    }

    func testPositionsAreStrictlyChronological() {
        let found = detect()
        let order = ShotType.fullSwing.positions
        let sorted = found.sorted { (order.firstIndex(of: $0.position) ?? 0) < (order.firstIndex(of: $1.position) ?? 0) }
        let indices = sorted.map(\.frameIndex)
        XCTAssertEqual(indices, indices.sorted(), "Detected frames must advance through the swing")
        XCTAssertEqual(Set(indices).count, indices.count, "No two positions may share a frame")
    }

    // MARK: - The failures real footage exposed

    /// A waggle is motion, so searching backwards from the top lands on the
    /// settled setup rather than on the fidgeting before it.
    func testAddressIsAfterTheWaggleNotBeforeIt() {
        let options = SwingFixture.Options()
        let frames = SwingFixture.frames(options)
        let found = PositionDetector.detectPositions(frames: frames, shotType: .fullSwing)
        guard let address = position(.address, in: found) else { return XCTFail("no address") }

        // Walk-in ends at 1.2s, waggle at 1.8s, backswing starts at 2.6s.
        XCTAssertGreaterThan(address.time, 1.8, "Address must be after the waggle")
        XCTAssertLessThan(address.time, 2.7, "Address must be before the takeaway")
        XCTAssertGreaterThan(address.confidence, 0.6)
    }

    /// This golfer pauses at the top for nearly a second. That pause is as quiet as
    /// an address, which originally dragged the detected address into it.
    func testHandlesALongPauseAtTheTop() {
        var options = SwingFixture.Options()
        options.topPause = 0.9
        let found = detect(options)
        guard let address = position(.address, in: found),
              let top = position(.top, in: found),
              let impact = position(.impact, in: found) else { return XCTFail("missing positions") }

        XCTAssertLessThan(address.time, 2.7, "A pause at the top must not be mistaken for the setup")
        XCTAssertGreaterThan(impact.time, top.time)

        // Fixture timeline: address holds to 2.6s, backswing to 3.4s, the hold
        // runs to 4.3s, then the downswing. The top belongs at the *end* of the
        // hold — where the club actually changes direction — not at its start.
        XCTAssertGreaterThan(top.time, 4.0,
                             "The top is the reversal, so it comes at the end of a pause")
        XCTAssertLessThan(impact.time - top.time, 0.7,
                          "Impact should follow the top by about one downswing")
        XCTAssertGreaterThanOrEqual(impact.confidence, 0.5,
                                    "Impact should still be found when the downswing starts late")
    }

    /// Walking into frame moves the hands a long way in absolute terms; the
    /// body-relative signal should ignore it.
    func testWalkingInIsNotMistakenForASwing() {
        var options = SwingFixture.Options()
        options.includeWalkIn = true
        let found = detect(options)
        guard let top = position(.top, in: found) else { return XCTFail("no top") }
        XCTAssertGreaterThan(top.time, 2.0, "The top must be in the real swing, not the walk-in")
    }

    func testImpactSitsNearAddressHeightAndAfterTheTop() {
        let frames = SwingFixture.frames()
        let found = PositionDetector.detectPositions(frames: frames, shotType: .fullSwing)
        guard let address = position(.address, in: found),
              let top = position(.top, in: found),
              let impact = position(.impact, in: found) else { return XCTFail("missing positions") }

        XCTAssertGreaterThan(impact.frameIndex, top.frameIndex)
        let addressHands = frames[address.frameIndex].handsCenter!.y
        let impactHands = frames[impact.frameIndex].handsCenter!.y
        XCTAssertEqual(impactHands, addressHands, accuracy: 0.08,
                       "Impact should return the hands to roughly address height")
    }

    /// Direct regression test for a real-footage bug: Vision routinely loses
    /// wrist tracking for a few tenths of a second right through the fastest,
    /// most motion-blurred part of the downswing. That hides the true speed
    /// peak from burst-detection, which anchors "burst" on the last VISIBLE
    /// fast frame — here, well before the tracking gap — so the search
    /// window has to reach comfortably past the gap to find the genuine
    /// impact frame once tracking resumes, not just barely past the
    /// (necessarily underestimated) burst.
    ///
    /// Confirmed against real footage: a 60fps clip where wrists dropped out
    /// for ~7 frames through impact had `findImpact` land 0.5s after the
    /// detected burst at confidence 1.0 (an excellent height match) once
    /// `postBurstAllowance` covered it — versus falling back to a frame
    /// still mid-downswing at confidence 0.4 when it didn't.
    func testImpactSearchReachesPastAWristTrackingGap() {
        // index: 0=address  1=top  2...7=visible accelerating downswing
        // (7 is the visible speed burst)  8...17=blur gap (untracked)
        // 18...21=tracking resumes, hands pass back through address height
        // at index 19, 0.4s after the burst.
        let heights: [Double?] = [
            0.0, 1.0, 0.85, 0.7, 0.55, 0.4, 0.35, 0.3,
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
            0.05, 0.0, -0.05, -0.1,
        ]
        let speeds: [Double?] = [
            0.05, 0.1, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0,
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
            1.5, 1.8, 1.2, 0.8,
        ]
        let n = heights.count
        let times = (0..<n).map { Double($0) / 30.0 }
        let hands: [(x: Double, y: Double)?] = heights.map { h in h.map { (0.0, $0) } }
        let signal = SwingSignal(times: times, hands: hands, speed: speeds,
                                 velocity: Array(repeating: nil, count: n),
                                 lift: Array(repeating: nil, count: n),
                                 shoulderHeight: Array(repeating: nil, count: n),
                                 quality: Array(repeating: 1.0, count: n),
                                 scale: 1.0)

        let (index, confidence) = PositionDetector.findImpact(after: 1, burst: 7, address: 0,
                                                               signal: signal, shotType: .fullSwing,
                                                               tuning: .default)
        XCTAssertEqual(index, 19,
                       "Should find the genuine impact frame once tracking resumes, not fall back to the last visible frame before the blur gap")
        XCTAssertEqual(confidence, 1.0, accuracy: 0.01,
                       "A close height match within tolerance should score full confidence, not the degraded fallback")

        // Confirms this genuinely regresses with the old, narrower allowance
        // — otherwise this test would pass by coincidence rather than
        // actually pinning the fix.
        var oldTuning = PositionDetector.Tuning.default
        oldTuning.postBurstAllowance = 0.30
        let (oldIndex, oldConfidence) = PositionDetector.findImpact(after: 1, burst: 7, address: 0,
                                                                     signal: signal, shotType: .fullSwing,
                                                                     tuning: oldTuning)
        XCTAssertNotEqual(oldIndex, 19, "Sanity check: the old allowance genuinely couldn't reach the true impact frame")
        XCTAssertLessThan(oldConfidence, 0.5, "Sanity check: the old allowance's fallback was low-confidence")
    }

    /// Confirmed against real footage (`IMG_5337.mov`): hand speed can peak
    /// *before* the closest address-height match, not at it — the wrists
    /// "release" through the last part of a real downswing, so speed is
    /// already falling by the time the hands are nearest their address
    /// height. Picking the fastest in-tolerance frame (the old rule) grabbed
    /// an earlier, farther-from-address-height frame purely because it was
    /// still accelerating; picking the closest match lands nearer true
    /// impact. This is a deliberately synthetic reproduction of that real
    /// shape (speed peaks then falls across several in-tolerance frames as
    /// height keeps closing in), not the exact real numbers.
    func testImpactPrefersClosestHeightMatchOverFastestFrame() {
        let heights: [Double?] = [0.0, 0.6, 0.5, 0.30, 0.15, 0.08, 0.02, -0.05]
        let speeds: [Double?] = [0.05, 0.3, 2.0, 3.0, 2.8, 2.5, 2.0, 1.5]
        let n = heights.count
        let times = (0..<n).map { Double($0) / 30.0 }
        let hands: [(x: Double, y: Double)?] = heights.map { h in h.map { (0.0, $0) } }
        let signal = SwingSignal(times: times, hands: hands, speed: speeds,
                                 velocity: Array(repeating: nil, count: n),
                                 lift: Array(repeating: nil, count: n),
                                 shoulderHeight: Array(repeating: nil, count: n),
                                 quality: Array(repeating: 1.0, count: n),
                                 scale: 1.0)

        let (index, _) = PositionDetector.findImpact(after: 1, burst: 3, address: 0,
                                                      signal: signal, shotType: .fullSwing,
                                                      tuning: .default)
        // Within the default 0.12 tolerance: indices 5 (Δ=0.08), 6 (Δ=0.02).
        // Index 5 is faster (2.5 vs 2.0); index 6 is the closer height match
        // and the one nearer real impact.
        XCTAssertEqual(index, 6, "Should pick the closest address-height match, not the fastest in-tolerance frame")
    }

    /// A high finish also puts the hands above the neck; only a genuine top is
    /// followed by a fast downswing.
    func testFinishIsAfterImpactAndDistinctFromTheTop() {
        let found = detect()
        guard let impact = position(.impact, in: found),
              let finish = position(.finish, in: found),
              let top = position(.top, in: found) else { return XCTFail("missing positions") }
        XCTAssertGreaterThan(finish.frameIndex, impact.frameIndex)
        XCTAssertGreaterThan(finish.time - top.time, 0.3)
    }

    // MARK: - Frame-rate independence

    /// Thresholds are in seconds, not frame counts, so the same swing filmed at
    /// 30 and 240 fps must land on the same moments.
    func testDetectionIsConsistentAcrossFrameRates() {
        var slow = SwingFixture.Options(); slow.fps = 30
        var fast = SwingFixture.Options(); fast.fps = 240

        let a = detect(slow)
        let b = detect(fast)

        for p in [SwingPosition.address, .top, .impact] {
            guard let ta = position(p, in: a)?.time, let tb = position(p, in: b)?.time else {
                return XCTFail("\(p.rawValue) missing at one frame rate")
            }
            XCTAssertEqual(ta, tb, accuracy: 0.12,
                           "\(p.rawValue) drifted between 30fps and 240fps")
        }
    }

    func testWorksAtSixtyFramesPerSecond() {
        var options = SwingFixture.Options(); options.fps = 60
        let found = detect(options)
        XCTAssertEqual(Set(found.map(\.position)), Set(ShotType.fullSwing.positions))
    }

    // MARK: - Degenerate input

    func testEmptyFramesProduceNoPositions() {
        XCTAssertTrue(PositionDetector.detectPositions(frames: [], shotType: .fullSwing).isEmpty)
    }

    func testTooFewFramesFallsBackWithoutCrashing() {
        let frames = Array(SwingFixture.frames().prefix(4))
        let found = PositionDetector.detectPositions(frames: frames, shotType: .fullSwing)
        XCTAssertFalse(found.isEmpty)
        for p in found { XCTAssertTrue(frames.indices.contains(p.frameIndex)) }
    }

    func testAStillClipFallsBackAndSaysSo() {
        let frames = (0..<90).map { i in
            SwingFixture.makeFrame(time: Double(i) / 30.0, handsX: 0.5, handsY: 0.46, bodyX: 0.5)
        }
        let found = PositionDetector.detectPositions(frames: frames, shotType: .fullSwing)
        XCTAssertFalse(found.isEmpty, "Should still offer positions the user can correct")
        XCTAssertTrue(found.allSatisfy { $0.confidence < 0.6 },
                      "Guessed positions must be flagged as uncertain")
    }

    func testShortGameUsesFewerPositions() {
        let found = detect(.init(), shot: .chip)
        XCTAssertEqual(Set(found.map(\.position)), Set(ShotType.chip.positions))
        XCTAssertLessThan(found.count, ShotType.fullSwing.positions.count)
    }

    // MARK: - Signal building

    func testStrictHandsIgnoresASingleTrackedWrist() {
        var frame = SwingFixture.makeFrame(time: 0, handsX: 0.5, handsY: 0.5, bodyX: 0.5)
        frame.joints[.rightWrist] = JointPoint(x: 0.5, y: 0.5, confidence: 0.05)
        XCTAssertNil(frame.handsCenter(minConfidence: 0.3),
                     "One wrist must not stand in for the hands — that fabricates a speed spike")
    }

    func testShortGapsAreInterpolatedAndLongOnesAreNot() {
        let times = (0..<10).map { Double($0) * 0.033 }
        var values: [(x: Double, y: Double)?] = times.map { _ in (0.5, 0.5) }
        values[4] = nil                                  // ~33ms gap
        let filled = SwingSignal.fillShortGaps(values, times: times, maximumGap: 0.15)
        XCTAssertNotNil(filled[4], "A one-frame dropout should be bridged")

        var wide: [(x: Double, y: Double)?] = times.map { _ in (0.5, 0.5) }
        for i in 2..<9 { wide[i] = nil }                 // ~230ms gap
        let notFilled = SwingSignal.fillShortGaps(wide, times: times, maximumGap: 0.15)
        XCTAssertNil(notFilled[5], "A long dropout must stay unknown, not read as stillness")
    }

    func testSmoothingSpansTheSameDurationAtAnyFrameRate() {
        func spike(fps: Double) -> Double {
            let n = Int(fps)
            let times = (0..<n).map { Double($0) / fps }
            var values: [(x: Double, y: Double)?] = times.map { _ in (0.0, 0.0) }
            values[n / 2] = (1.0, 0.0)
            let smoothed = SwingSignal.gaussianSmooth(values, times: times, sigma: 0.030)
            return smoothed[n / 2]!.x
        }
        // A 30ms-wide kernel should attenuate a single-frame spike far more at
        // 240fps than at 30fps, because more samples fall inside the window.
        XCTAssertLessThan(spike(fps: 240), spike(fps: 30))
    }

    func testVelocityIsZeroForAStationaryHand() {
        let times = (0..<20).map { Double($0) * 0.033 }
        let values: [(x: Double, y: Double)?] = times.map { _ in (0.5, 0.5) }
        let velocity = SwingSignal.centralDifference(values, times: times, halfWidth: 0.04)
        for v in velocity.compactMap({ $0 }) {
            XCTAssertEqual(v.x, 0, accuracy: 1e-9)
            XCTAssertEqual(v.y, 0, accuracy: 1e-9)
        }
    }

    // MARK: - Window scanning

    func testScannerFindsOneSwingInAClipWithLotsOfIdleTime() {
        let frames = SwingFixture.frames()
        let result = SwingWindowScanner.scan(frames: frames, space: .square,
                                             clipDuration: frames.last!.time)
        XCTAssertEqual(result.candidates.count, 1, "One swing should yield one candidate")
        XCTAssertFalse(result.isLowConfidence)
    }

    /// The follow-through also raises the hands above the neck; without a
    /// downswing after it, it is not a top.
    func testScannerDoesNotCountTheFinishAsASecondSwing() {
        var options = SwingFixture.Options()
        options.finishHold = 2.0
        let frames = SwingFixture.frames(options)
        let result = SwingWindowScanner.scan(frames: frames, space: .square,
                                             clipDuration: frames.last!.time)
        XCTAssertEqual(result.candidates.count, 1,
                       "A high finish must not be reported as another swing")
    }

    func testScannerWindowContainsTheWholeSwing() {
        let frames = SwingFixture.frames()
        let result = SwingWindowScanner.scan(frames: frames, space: .square,
                                             clipDuration: frames.last!.time)
        guard let best = result.best else { return XCTFail("no window") }
        // Address is around 2.0s and impact around 3.7s in the fixture.
        XCTAssertLessThan(best.start, 2.6, "Window must reach back to the setup")
        XCTAssertGreaterThan(best.end, 3.6, "Window must extend past impact")
    }

    func testScannerReportsLowConfidenceOnAStillClip() {
        let frames = (0..<120).map { i in
            SwingFixture.makeFrame(time: Double(i) / 30.0, handsX: 0.5, handsY: 0.46, bodyX: 0.5)
        }
        let result = SwingWindowScanner.scan(frames: frames, space: .square, clipDuration: 4.0)
        XCTAssertTrue(result.isLowConfidence)
    }
}
