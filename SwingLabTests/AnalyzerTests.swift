import XCTest
@testable import SwingLab

final class AnalyzerTests: XCTestCase {

    private func pose(shoulderHalfWidth: Double, hipHalfWidth: Double,
                      headX: Double = 0.5, rootX: Double = 0.5,
                      neckX: Double = 0.5, time: Double = 0) -> PoseFrame {
        PoseFrame(time: time, joints: [
            .nose: JointPoint(x: headX, y: 0.9, confidence: 0.9),
            .neck: JointPoint(x: neckX, y: 0.82, confidence: 0.9),
            .leftShoulder: JointPoint(x: 0.5 - shoulderHalfWidth, y: 0.8, confidence: 0.9),
            .rightShoulder: JointPoint(x: 0.5 + shoulderHalfWidth, y: 0.8, confidence: 0.9),
            .leftWrist: JointPoint(x: 0.49, y: 0.5, confidence: 0.9),
            .rightWrist: JointPoint(x: 0.51, y: 0.5, confidence: 0.9),
            .root: JointPoint(x: rootX, y: 0.52, confidence: 0.9),
            .leftHip: JointPoint(x: rootX - hipHalfWidth, y: 0.52, confidence: 0.9),
            .rightHip: JointPoint(x: rootX + hipHalfWidth, y: 0.52, confidence: 0.9),
            .leftAnkle: JointPoint(x: 0.42, y: 0.04, confidence: 0.9),
            .rightAnkle: JointPoint(x: 0.58, y: 0.04, confidence: 0.9),
        ])
    }

    /// `.swingPath`/`.planeDeviation` are retired (see `ModelProProfile.
    /// retiredKinds`) but need delivery+impact/hands positioned independently
    /// of the shared `pose` helper above (which fixes the wrists) to prove
    /// they stay retired even in a full, otherwise-valid down-the-line setup
    /// — the exact conditions that used to produce them.
    private func planePose(handsX: Double, handsY: Double, time: Double = 0) -> PoseFrame {
        PoseFrame(time: time, joints: [
            .neck: JointPoint(x: 0.5, y: 0.80, confidence: 0.9),
            .root: JointPoint(x: 0.5, y: 0.50, confidence: 0.9),
            .leftShoulder: JointPoint(x: 0.43, y: 0.78, confidence: 0.9),
            .rightShoulder: JointPoint(x: 0.57, y: 0.78, confidence: 0.9),
            .leftWrist: JointPoint(x: handsX - 0.015, y: handsY, confidence: 0.9),
            .rightWrist: JointPoint(x: handsX + 0.015, y: handsY, confidence: 0.9),
            .leftAnkle: JointPoint(x: 0.45, y: 0.04, confidence: 0.9),
            .rightAnkle: JointPoint(x: 0.55, y: 0.04, confidence: 0.9),
        ])
    }

    func testSwingPathAndPlaneDeviationAreNeverProducedEvenDownTheLine() {
        let address = planePose(handsX: 0.5, handsY: 0.5)
        let delivery = planePose(handsX: 0.5, handsY: 0.46, time: 1.0)
        let impact = planePose(handsX: 0.65, handsY: 0.50, time: 1.2)

        let (metrics, _) = SwingAnalyzer.analyze(
            frames: [address, delivery, impact],
            positions: [DetectedPosition(position: .address, frameIndex: 0, time: 0),
                        DetectedPosition(position: .delivery, frameIndex: 1, time: 1.0),
                        DetectedPosition(position: .impact, frameIndex: 2, time: 1.2)],
            profile: .default, shotType: .fullSwing, view: .downTheLine, handedness: .right)

        XCTAssertFalse(metrics.contains { $0.kind == .swingPath },
                       "swingPath is retired — must never be produced, even with a full delivery+impact setup")
        XCTAssertFalse(metrics.contains { $0.kind == .planeDeviation },
                       "planeDeviation is retired — must never be produced, even down-the-line at delivery")
    }

    func testAnalyzeProducesMetricsForFaceOnFullSwing() {
        // Address square to the camera; at the top the shoulders have
        // foreshortened much more than the hips → real coil.
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        let top = pose(shoulderHalfWidth: 0.02, hipHalfWidth: 0.045, time: 0.8)
        let impact = pose(shoulderHalfWidth: 0.09, hipHalfWidth: 0.05, time: 1.1)

        let frames = [address, top, impact]
        let positions = [
            DetectedPosition(position: .address, frameIndex: 0, time: 0),
            DetectedPosition(position: .top, frameIndex: 1, time: 0.8),
            DetectedPosition(position: .impact, frameIndex: 2, time: 1.1),
        ]

        let (metrics, overall) = SwingAnalyzer.analyze(frames: frames,
                                                       positions: positions,
                                                       profile: .default,
                                                       shotType: .fullSwing,
                                                       view: .faceOn,
                                                       handedness: .right)

        XCTAssertFalse(metrics.isEmpty)
        XCTAssertTrue(metrics.contains { $0.kind == .shoulderTurn })
        XCTAssertTrue(metrics.contains { $0.kind == .xFactor })
        XCTAssertTrue((0...100).contains(overall))

        let xFactor = metrics.first { $0.kind == .xFactor }!
        XCTAssertGreaterThan(xFactor.measured, 0, "Shoulders turning more than hips is positive separation")
    }

    /// Confirmed against real footage: Apple's 3D body pose can return a hip
    /// axis frozen at the same value across an entire swing — address
    /// through finish, to 4 decimal places — while `shoulderTurn` measures
    /// normally. `VNHumanBodyRecognizedPoint3D` exposes no per-joint
    /// confidence to gate on, so `BodyTurn3D.reliableHipTurn` treats a
    /// too-good-to-be-true flat zero as untrustworthy and both `.hipTurn`
    /// and `.xFactor` must fall back to the 2D estimate rather than score a
    /// real, severe fault off a measurement that was never real rotation.
    /// See `CLAUDE.md` "reliableHipTurn".
    func testHipTurnFallsBackToTwoDWhenThreeDReadsFrozenZero() {
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        var top = pose(shoulderHalfWidth: 0.02, hipHalfWidth: 0.045, time: 0.8)
        top.turn3D = BodyTurn3D(shoulderTurn: 75, hipTurn: 0, spineTilt: 20)

        let (metrics, _) = SwingAnalyzer.analyze(
            frames: [address, top],
            positions: [DetectedPosition(position: .address, frameIndex: 0, time: 0),
                        DetectedPosition(position: .top, frameIndex: 1, time: 0.8)],
            profile: .default, shotType: .fullSwing, view: .faceOn, handedness: .right)

        let hipTurn = metrics.first { $0.kind == .hipTurn }
        XCTAssertNotNil(hipTurn, "should fall back to the 2D estimate rather than trust a suspicious flat zero")
        XCTAssertGreaterThan(hipTurn!.measured, 1,
                             "the 2D fallback should recover a real, nonzero turn from the shrinking hip width")

        // Falling back must be all-or-nothing, same as when turn3D is
        // absent entirely — shoulderTurn=75 must never leak into a mixed
        // "3D shoulder minus 2D hip" xFactor.
        let xFactor = metrics.first { $0.kind == .xFactor }
        XCTAssertNotNil(xFactor)
        XCTAssertNotEqual(xFactor!.measured, 75, accuracy: 0.01)
    }

    func testAnalyzeReturnsEmptyWithoutAddressFrame() {
        let frames = [pose(shoulderHalfWidth: 0.1, hipHalfWidth: 0.06)]
        let positions = [DetectedPosition(position: .top, frameIndex: 0, time: 0)]
        let (metrics, overall) = SwingAnalyzer.analyze(frames: frames,
                                                       positions: positions,
                                                       profile: .default,
                                                       shotType: .fullSwing,
                                                       view: .faceOn,
                                                       handedness: .right)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertEqual(overall, 0)
    }

    func testPostureChangeFlagsEarlyExtension() {
        // DTL: spine stands up ~20° between address and impact.
        let address = pose(shoulderHalfWidth: 0.05, hipHalfWidth: 0.04, neckX: 0.30)
        let impact = pose(shoulderHalfWidth: 0.05, hipHalfWidth: 0.04, neckX: 0.48, time: 1.0)
        let frames = [address, impact]
        let positions = [
            DetectedPosition(position: .address, frameIndex: 0, time: 0),
            DetectedPosition(position: .impact, frameIndex: 1, time: 1.0),
        ]

        let (metrics, _) = SwingAnalyzer.analyze(frames: frames,
                                                 positions: positions,
                                                 profile: .default,
                                                 shotType: .fullSwing,
                                                 view: .downTheLine,
                                                 handedness: .right)

        let posture = metrics.first { $0.kind == .postureChange && $0.position == .impact }
        XCTAssertNotNil(posture)
        XCTAssertEqual(posture!.status, .needsWork, "A large spine-angle change should fail the check")
    }

    func testHeadDriftMeasuredInInches() {
        let address = pose(shoulderHalfWidth: 0.1, hipHalfWidth: 0.06, headX: 0.5) // width 0.2 ≈ 16"
        let top = pose(shoulderHalfWidth: 0.1, hipHalfWidth: 0.06, headX: 0.55, time: 0.8) // 4"
        let frames = [address, top]
        let positions = [
            DetectedPosition(position: .address, frameIndex: 0, time: 0),
            DetectedPosition(position: .top, frameIndex: 1, time: 0.8),
        ]

        let (metrics, _) = SwingAnalyzer.analyze(frames: frames,
                                                 positions: positions,
                                                 profile: .default,
                                                 shotType: .fullSwing,
                                                 view: .faceOn,
                                                 handedness: .right)

        let drift = metrics.first { $0.kind == .headDrift && $0.position == .top }!
        XCTAssertEqual(drift.measured, 4.0, accuracy: 0.11)
        XCTAssertEqual(drift.status, .needsWork, "4 inches exceeds the 3-inch default ceiling")
    }

    func testProfileLookupIsScopedToShotTypeAndView() {
        let profile = ModelProProfile.default
        XCTAssertNotNil(profile.target(shotType: .fullSwing, view: .faceOn, position: .top, kind: .xFactor))
        XCTAssertNil(profile.target(shotType: .putt, view: .faceOn, position: .top, kind: .xFactor))
        XCTAssertFalse(profile.targets(shotType: .chip, view: .faceOn).isEmpty)
    }

    func testEveryShotTypeAndViewHasTargets() {
        let profile = ModelProProfile.default
        for shot in ShotType.allCases {
            for view in CameraViewType.allCases {
                XCTAssertFalse(profile.targets(shotType: shot, view: view).isEmpty,
                               "\(shot.rawValue) / \(view.rawValue) has no ideal ranges")
            }
        }
    }

    func testTargetRangesAreWellFormed() {
        for target in ModelProProfile.default.targets {
            XCTAssertLessThan(target.low, target.high, "\(target.id) has an inverted range")
            XCTAssertGreaterThan(target.weight, 0, "\(target.id) has a non-positive weight")
        }
    }

    /// Direct regression test for "don't reduce the score so much for spine
    /// angle": every seeded spine-tilt target should be both wider than a
    /// tight technique window and weighted below a full-weight metric, so a
    /// spine-angle deviation can't swing the overall score the way an
    /// actual technique fault should. Different body proportions make a
    /// single narrow angle less trustworthy than it is for e.g. shoulder
    /// turn, which this profile treats as a hard technique number.
    func testSpineTiltIsWideAndLightlyWeightedEverywhereItsSeeded() {
        let spineTiltTargets = ModelProProfile.default.targets.filter { $0.kind == .spineTilt }
        XCTAssertFalse(spineTiltTargets.isEmpty)
        for target in spineTiltTargets {
            XCTAssertGreaterThanOrEqual(target.high - target.low, 16,
                                        "\(target.id) should have a forgiving, wide window")
            XCTAssertLessThanOrEqual(target.weight, 0.7,
                                     "\(target.id) should count for less than a full-weight metric")
        }
    }

    // MARK: - View visibility

    /// The whole seeded profile has to agree with `isVisible`, or the
    /// analyzer would silently drop a target someone put there on purpose.
    func testEverySeededTargetIsVisibleFromItsOwnView() {
        for target in ModelProProfile.default.targets {
            XCTAssertTrue(target.kind.isVisible(from: target.view),
                          "\(target.id) is seeded for \(target.view.rawValue) but marked invisible there")
        }
    }

    /// This is the direct regression test for the bug that started this: a
    /// down-the-line clip analysed as if it were face-on produced a
    /// meaningless, heavily-weighted shoulder-turn reading. Rotation must be
    /// impossible to score down-the-line even if a target for it exists.
    func testRotationMetricsAreNeverProducedDownTheLine() {
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        let top = pose(shoulderHalfWidth: 0.02, hipHalfWidth: 0.045, time: 0.8)

        var profile = ModelProProfile.default
        // Simulate a stale/hand-edited profile that (wrongly) has a rotation
        // target for the down-the-line view, to prove the analyzer itself
        // refuses it rather than relying only on the seeded set being clean.
        profile.targets.append(MetricTarget(shotType: .fullSwing, view: .downTheLine,
                                            position: .top, kind: .shoulderTurn, low: 85, high: 100))

        let (metrics, _) = SwingAnalyzer.analyze(
            frames: [address, top],
            positions: [DetectedPosition(position: .address, frameIndex: 0, time: 0),
                        DetectedPosition(position: .top, frameIndex: 1, time: 0.8)],
            profile: profile, shotType: .fullSwing, view: .downTheLine, handedness: .right)

        XCTAssertFalse(metrics.contains { $0.kind == .shoulderTurn },
                       "Shoulder turn must never be scored on a down-the-line view, injected target or not")
        XCTAssertFalse(metrics.contains { $0.kind == .hipTurn })
        XCTAssertFalse(metrics.contains { $0.kind == .xFactor })
    }

    func testPostureAndPlaneMetricsAreNeverProducedFaceOn() {
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        let impact = pose(shoulderHalfWidth: 0.09, hipHalfWidth: 0.05, time: 1.1)

        var profile = ModelProProfile.default
        profile.targets.append(MetricTarget(shotType: .fullSwing, view: .faceOn,
                                            position: .impact, kind: .postureChange, low: 0, high: 5))
        profile.targets.append(MetricTarget(shotType: .fullSwing, view: .faceOn,
                                            position: .impact, kind: .planeDeviation, low: 0, high: 12))
        profile.targets.append(MetricTarget(shotType: .fullSwing, view: .faceOn,
                                            position: .impact, kind: .swingPath, low: -4, high: 4))

        let (metrics, _) = SwingAnalyzer.analyze(
            frames: [address, impact],
            positions: [DetectedPosition(position: .address, frameIndex: 0, time: 0),
                        DetectedPosition(position: .impact, frameIndex: 1, time: 1.1)],
            profile: profile, shotType: .fullSwing, view: .faceOn, handedness: .right)

        XCTAssertFalse(metrics.contains { $0.kind == .postureChange })
        XCTAssertFalse(metrics.contains { $0.kind == .planeDeviation })
        XCTAssertFalse(metrics.contains { $0.kind == .swingPath })
    }

    /// Spine tilt and head drift are genuinely visible from both angles (spine
    /// tilt reads as forward bend down-the-line and side lean face-on — two
    /// different real quantities, which is why the seeded ranges differ) and
    /// must not be caught by the same net that blocks rotation/plane metrics.
    func testSpineTiltAndHeadDriftAreVisibleFromBothViews() {
        XCTAssertTrue(MetricKind.spineTilt.isVisible(from: .faceOn))
        XCTAssertTrue(MetricKind.spineTilt.isVisible(from: .downTheLine))
        XCTAssertTrue(MetricKind.headDrift.isVisible(from: .faceOn))
        XCTAssertTrue(MetricKind.headDrift.isVisible(from: .downTheLine))
    }

    func testProfileRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(ModelProProfile.default)
        let decoded = try JSONDecoder().decode(ModelProProfile.self, from: data)
        XCTAssertEqual(decoded, ModelProProfile.default)
    }

    // MARK: - Coaching

    func testRulesCoachAlwaysProducesText() {
        let metrics = [
            MetricResult(kind: .xFactor, position: .top, measured: 20,
                         idealLow: 35, idealHigh: 55, weight: 1.5),
            MetricResult(kind: .headDrift, position: .top, measured: 6,
                         idealLow: 0, idealHigh: 3, weight: 1.2),
        ]
        let text = RulesCoach.coaching(for: metrics, shotType: .fullSwing, overallScore: 55)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("x-factor") || text.lowercased().contains("separation"))
    }

    func testRulesCoachHandlesPerfectSwing() {
        let metrics = [
            MetricResult(kind: .xFactor, position: .top, measured: 45,
                         idealLow: 35, idealHigh: 55, weight: 1.5),
        ]
        let text = RulesCoach.coaching(for: metrics, shotType: .fullSwing, overallScore: 100)
        XCTAssertFalse(text.isEmpty)
    }

    func testRulesCoachHandlesNoMetrics() {
        let text = RulesCoach.coaching(for: [], shotType: .fullSwing, overallScore: 0)
        XCTAssertFalse(text.isEmpty, "Should explain the problem rather than return nothing")
    }

    // MARK: - Analysis payload

    func testSwingAnalysisRoundTripsAndLooksUpFrames() throws {
        let frames = [
            pose(shoulderHalfWidth: 0.1, hipHalfWidth: 0.06, time: 0),
            pose(shoulderHalfWidth: 0.03, hipHalfWidth: 0.05, time: 0.5),
        ]
        let analysis = SwingAnalysis(
            frames: frames,
            positions: [
                DetectedPosition(position: .address, frameIndex: 0, time: 0),
                DetectedPosition(position: .top, frameIndex: 1, time: 0.5),
            ],
            metrics: [],
            overallScore: 82,
            frameRate: 120,
            duration: 2.0)

        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(SwingAnalysis.self, from: data)

        XCTAssertEqual(decoded.overallScore, 82)
        XCTAssertNotNil(decoded.frame(for: .top))
        XCTAssertEqual(decoded.frame(for: .top)?.time, 0.5)
        XCTAssertNil(decoded.frame(for: .finish), "Undetected positions should return nil, not crash")
    }

    func testFrameLookupSurvivesOutOfRangeIndex() {
        let analysis = SwingAnalysis(
            frames: [pose(shoulderHalfWidth: 0.1, hipHalfWidth: 0.06)],
            positions: [DetectedPosition(position: .top, frameIndex: 99, time: 5)],
            metrics: [], overallScore: 0, frameRate: 30, duration: 1)
        XCTAssertNil(analysis.frame(for: .top))
    }
}
