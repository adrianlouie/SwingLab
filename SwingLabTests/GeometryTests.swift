import XCTest
@testable import SwingLab

final class GeometryTests: XCTestCase {

    private func point(_ x: Double, _ y: Double, _ c: Double = 1) -> JointPoint {
        JointPoint(x: x, y: y, confidence: c)
    }

    // MARK: - Angles

    func testAngleFromVerticalStraightUpIsZero() {
        let angle = SwingGeometry.angleFromVertical(from: point(0.5, 0.2), to: point(0.5, 0.8))
        XCTAssertEqual(angle, 0, accuracy: 0.001)
    }

    func testAngleFromVerticalHorizontalIsNinety() {
        let angle = SwingGeometry.angleFromVertical(from: point(0.2, 0.5), to: point(0.8, 0.5))
        XCTAssertEqual(angle, 90, accuracy: 0.001)
    }

    func testAngleFromVerticalFortyFive() {
        let angle = SwingGeometry.angleFromVertical(from: point(0, 0), to: point(0.5, 0.5))
        XCTAssertEqual(angle, 45, accuracy: 0.001)
    }

    func testAngleFromVerticalIsUnsigned() {
        let left = SwingGeometry.angleFromVertical(from: point(0.5, 0), to: point(0.2, 0.3))
        let right = SwingGeometry.angleFromVertical(from: point(0.5, 0), to: point(0.8, 0.3))
        XCTAssertEqual(left, right, accuracy: 0.001)
    }

    func testAngleFromHorizontalSignedAboveAndBelow() {
        let above = SwingGeometry.angleFromHorizontal(from: point(0, 0), to: point(1, 1))
        let below = SwingGeometry.angleFromHorizontal(from: point(0, 0), to: point(1, -1))
        XCTAssertEqual(above, 45, accuracy: 0.001)
        XCTAssertEqual(below, -45, accuracy: 0.001)
    }

    func testDegenerateAngleReturnsZero() {
        XCTAssertEqual(SwingGeometry.angleFromVertical(from: point(0.5, 0.5), to: point(0.5, 0.5)), 0)
    }

    // MARK: - Spine tilt

    func testSpineTiltUsesHipToNeckLine() {
        let frame = PoseFrame(time: 0, joints: [
            .root: point(0.5, 0.4),
            .neck: point(0.6, 0.8),
        ])
        // dx 0.1, dy 0.4 → atan(0.1/0.4) ≈ 14.04°
        XCTAssertEqual(SwingGeometry.spineTilt(frame: frame)!, 14.036, accuracy: 0.01)
    }

    func testSpineTiltNilWhenJointsMissing() {
        let frame = PoseFrame(time: 0, joints: [.neck: point(0.5, 0.8)])
        XCTAssertNil(SwingGeometry.spineTilt(frame: frame))
    }

    func testSpineTiltNilWhenConfidenceTooLow() {
        let frame = PoseFrame(time: 0, joints: [
            .root: point(0.5, 0.4, 0.05),
            .neck: point(0.6, 0.8, 0.9),
        ])
        XCTAssertNil(SwingGeometry.spineTilt(frame: frame))
    }

    // MARK: - Rotation estimate

    func testRotationEstimateNoTurnWhenWidthUnchanged() {
        // Width exactly unchanged still falls outside the model's valid
        // (strictly shrinking) regime -- nil, not a false "definitely zero."
        XCTAssertNil(SwingGeometry.rotationEstimate(addressWidth: 0.3, currentWidth: 0.3))
    }

    func testRotationEstimateSixtyDegreesAtHalfWidth() {
        XCTAssertEqual(SwingGeometry.rotationEstimate(addressWidth: 0.3, currentWidth: 0.15) ?? -1, 60, accuracy: 0.001)
    }

    func testRotationEstimateNilWhenWiderThanAddress() {
        // Perspective noise, camera angle, or a stance imperfection can
        // easily make the current width exceed address -- there's no
        // honest angle to recover from the foreshortening model in that
        // regime, so this must read as "no measurement," not a false
        // "confirmed zero rotation" (which used to get scored as a real,
        // severe fault -- confirmed against real footage, see CLAUDE.md
        // "rotationEstimate nil-not-zero").
        XCTAssertNil(SwingGeometry.rotationEstimate(addressWidth: 0.3, currentWidth: 0.4))
    }

    func testRotationEstimateHandlesZeroAddressWidth() {
        XCTAssertNil(SwingGeometry.rotationEstimate(addressWidth: 0, currentWidth: 0.2))
    }

    // MARK: - Drift

    func testHorizontalDriftScalesByShoulderWidth() {
        let address = PoseFrame(time: 0, joints: [
            .nose: point(0.5, 0.9),
            .leftShoulder: point(0.4, 0.8),
            .rightShoulder: point(0.6, 0.8), // width 0.2 ≈ 16 inches
        ])
        let current = PoseFrame(time: 1, joints: [
            .nose: point(0.55, 0.9), // 0.05 normalized = 1/4 shoulder width = 4"
            .leftShoulder: point(0.4, 0.8),
            .rightShoulder: point(0.6, 0.8),
        ])
        let drift = SwingGeometry.horizontalDriftInches(joint: .nose, address: address, current: current)
        XCTAssertEqual(drift!, 4.0, accuracy: 0.001)
    }

    func testHeadJointPrefersNoseThenNeck() {
        let withNose = PoseFrame(time: 0, joints: [.nose: point(0.5, 0.9), .neck: point(0.5, 0.8)])
        XCTAssertEqual(SwingGeometry.headJoint(in: withNose), .nose)

        let neckOnly = PoseFrame(time: 0, joints: [.neck: point(0.5, 0.8)])
        XCTAssertEqual(SwingGeometry.headJoint(in: neckOnly), .neck)

        XCTAssertNil(SwingGeometry.headJoint(in: PoseFrame(time: 0, joints: [:])))
    }

    // MARK: - Swing plane

    func testPlaneDeviationZeroOnTheLine() {
        let deviation = SwingGeometry.planeDeviationPercent(point: point(0.5, 0.5),
                                                            ball: point(0.4, 0.3),
                                                            shoulder: point(0.6, 0.7))
        XCTAssertEqual(deviation, 0, accuracy: 0.001)
    }

    func testPlaneDeviationPositiveOffTheLine() {
        let deviation = SwingGeometry.planeDeviationPercent(point: point(0.7, 0.3),
                                                            ball: point(0.4, 0.3),
                                                            shoulder: point(0.4, 0.8))
        XCTAssertGreaterThan(deviation, 0)
    }

    /// Address pose with the hands outside the ankle midline, as a golfer's
    /// hands actually are.
    private var planeTestAddress: PoseFrame {
        PoseFrame(time: 0, joints: [
            .neck: point(0.5, 0.8),
            .root: point(0.5, 0.5),
            .leftShoulder: point(0.4, 0.8),
            .rightShoulder: point(0.6, 0.8),
            .leftWrist: point(0.63, 0.5),
            .rightWrist: point(0.67, 0.5),
            .leftAnkle: point(0.4, 0.05),
            .rightAnkle: point(0.6, 0.06),
        ])
    }

    func testPlaneLineUsesTrailShoulderPerHandedness() {
        let address = planeTestAddress
        let rh = SwingGeometry.planeLine(address: address, handedness: .right)
        XCTAssertEqual(rh!.shoulder.x, 0.6, accuracy: 0.001)

        let lh = SwingGeometry.planeLine(address: address, handedness: .left)
        XCTAssertEqual(lh!.shoulder.x, 0.4, accuracy: 0.001)
    }

    /// The ankle *joint* is several inches above the sole, so anchoring the
    /// plane line there floats the ball above the turf and tilts the line.
    func testPlaneLineBallSitsBelowTheAnkleJoint() {
        let plane = SwingGeometry.planeLine(address: planeTestAddress, handedness: .right)!
        XCTAssertLessThan(plane.ball.y, 0.05,
                          "Ball should drop below the lower ankle joint to reach the ground")
    }

    /// In a down-the-line view the shaft leans out and down, so the ball sits
    /// farther from the body than the hands do.
    func testPlaneLineBallSitsOutsideTheHands() {
        let address = planeTestAddress
        let plane = SwingGeometry.planeLine(address: address, handedness: .right)!
        let hands = address.handsCenter!
        let ankleMid = 0.5
        XCTAssertGreaterThan(abs(plane.ball.x - ankleMid), abs(hands.x - ankleMid),
                             "Ball should be farther from the body than the hands")
    }

    /// A user-set ball marker must win over the estimate, since the ball's
    /// horizontal position isn't recoverable from body joints.
    func testPlaneLineHonoursBallOverride() {
        let override = point(0.9, 0.02)
        let plane = SwingGeometry.planeLine(address: planeTestAddress, handedness: .right,
                                            ballOverride: override)!
        XCTAssertEqual(plane.ball.x, 0.9, accuracy: 0.0001)
        XCTAssertEqual(plane.ball.y, 0.02, accuracy: 0.0001)
    }

    // MARK: - Coordinate space

    /// The bug that made every angle wrong: on a 9:16 clip an x-unit is a much
    /// shorter real distance than a y-unit, so a genuine 30° tilt read as ~46°.
    func testSpineTiltCorrectsForNonSquareAspect() {
        // dx 0.1 in normalized coords, dy 0.4. On a 9:16 image the true
        // horizontal distance is 0.1 * (9/16) = 0.05625.
        let frame = PoseFrame(time: 0, joints: [
            .root: point(0.5, 0.4),
            .neck: point(0.6, 0.8),
        ])
        let portrait = PoseSpace(aspect: 9.0 / 16.0)
        let corrected = SwingGeometry.spineTilt(frame: frame, space: portrait)!
        let square = SwingGeometry.spineTilt(frame: frame, space: .square)!

        XCTAssertEqual(corrected, atan(0.05625 / 0.4) * 180 / .pi, accuracy: 0.01)
        XCTAssertLessThan(corrected, square, "Correcting for aspect must reduce the angle")
        XCTAssertEqual(square / corrected, 1.77, accuracy: 0.05,
                       "A 9:16 clip inflates horizontal measurements by ~16/9")
    }

    func testSquareSpaceIsTheDefaultAndUnchanged() {
        let a = point(0, 0), b = point(0.5, 0.5)
        XCTAssertEqual(SwingGeometry.angleFromVertical(from: a, to: b), 45, accuracy: 0.001)
        XCTAssertEqual(SwingGeometry.distance(a, b), (0.5 * 0.5 * 2).squareRoot(), accuracy: 0.0001)
    }

    func testPoseSpaceRoundTripsX() {
        let space = PoseSpace(aspect: 9.0 / 16.0)
        XCTAssertEqual(space.denormX(space.isoX(0.42)), 0.42, accuracy: 1e-9)
    }

    func testPoseSpaceRejectsNonPositiveAspect() {
        XCTAssertEqual(PoseSpace(aspect: 0).aspect, 1.0)
        XCTAssertEqual(PoseSpace(aspect: -2).aspect, 1.0)
    }

    // MARK: - Signed variants for fault detection

    func testSignedPlaneDeviationDistinguishesSides() {
        let ball = point(0.4, 0.1)
        let shoulder = point(0.5, 0.8)
        let above = SwingGeometry.planeDeviationSigned(point: point(0.2, 0.5), ball: ball, shoulder: shoulder)
        let below = SwingGeometry.planeDeviationSigned(point: point(0.7, 0.5), ball: ball, shoulder: shoulder)
        XCTAssertGreaterThan(above * below, -1e9)
        XCTAssertNotEqual(above.sign, below.sign,
                          "Opposite sides of the plane must have opposite signs")
        // The unsigned version cannot tell them apart at all, which is why
        // over-the-top was undetectable.
        XCTAssertEqual(abs(above), SwingGeometry.planeDeviationPercent(point: point(0.2, 0.5), ball: ball, shoulder: shoulder), accuracy: 1e-9)
    }

    func testSignedDriftDistinguishesDirection() {
        let address = PoseFrame(time: 0, joints: [
            .nose: point(0.5, 0.9),
            .leftShoulder: point(0.4, 0.8),
            .rightShoulder: point(0.6, 0.8),
        ])
        func moved(_ x: Double) -> PoseFrame {
            PoseFrame(time: 1, joints: [
                .nose: point(x, 0.9),
                .leftShoulder: point(0.4, 0.8),
                .rightShoulder: point(0.6, 0.8),
            ])
        }
        let toward = SwingGeometry.horizontalDriftSignedInches(joint: .nose, address: address, current: moved(0.55))!
        let away = SwingGeometry.horizontalDriftSignedInches(joint: .nose, address: address, current: moved(0.45))!
        XCTAssertGreaterThan(toward, 0)
        XCTAssertLessThan(away, 0)
        XCTAssertEqual(abs(toward), abs(away), accuracy: 0.001)
    }

    func testJointAngleMeasuresInteriorAngle() {
        // A right angle at b.
        let straight = SwingGeometry.jointAngle(point(0, 1), point(0, 0), point(1, 0))
        XCTAssertEqual(straight, 90, accuracy: 0.001)
        // A fully extended arm.
        let extended = SwingGeometry.jointAngle(point(0, 1), point(0, 0.5), point(0, 0))
        XCTAssertEqual(extended, 180, accuracy: 0.001)
    }

    func testJointAngleHandlesCoincidentPoints() {
        XCTAssertEqual(SwingGeometry.jointAngle(point(0.5, 0.5), point(0.5, 0.5), point(0.5, 0.5)), 0)
    }

    // MARK: - Head circle

    func testHeadCircleFitsEarSpan() {
        let frame = PoseFrame(time: 0, joints: [
            .neck: point(0.5, 0.7),
            .nose: point(0.5, 0.85),
            .leftEar: point(0.46, 0.86),
            .rightEar: point(0.54, 0.86),
        ])
        let head = frame.headCircle()!
        XCTAssertEqual(head.radius, 0.08 * 0.75, accuracy: 0.001)
        XCTAssertGreaterThan(head.center.y, 0.85, "Centre should sit above the face, toward the skull")
    }

    func testHeadCircleFallsBackInProfile() {
        // Only one ear visible, as when filmed from the side.
        let frame = PoseFrame(time: 0, joints: [
            .neck: point(0.5, 0.7),
            .nose: point(0.56, 0.85),
            .leftEar: point(0.48, 0.86),
        ])
        XCTAssertNotNil(frame.headCircle())
    }

    func testHeadCircleNilWithoutFaceJoints() {
        let frame = PoseFrame(time: 0, joints: [.neck: point(0.5, 0.7)])
        XCTAssertNil(frame.headCircle())
    }

    // MARK: - Strict hands centre

    func testStrictHandsCenterRequiresBothWrists() {
        let oneWrist = PoseFrame(time: 0, joints: [.leftWrist: point(0.4, 0.5, 0.9)])
        XCTAssertNil(oneWrist.handsCenter(minConfidence: 0.3),
                     "A single wrist must not stand in for the hands during detection")
        XCTAssertNotNil(oneWrist.handsCenter, "The lenient property still falls back, for drawing")

        let bothWrists = PoseFrame(time: 0, joints: [
            .leftWrist: point(0.4, 0.5, 0.9),
            .rightWrist: point(0.6, 0.5, 0.9),
        ])
        XCTAssertEqual(bothWrists.handsCenter(minConfidence: 0.3)?.x, 0.5)
    }

    func testStrictHandsCenterRejectsLowConfidence() {
        let frame = PoseFrame(time: 0, joints: [
            .leftWrist: point(0.4, 0.5, 0.9),
            .rightWrist: point(0.6, 0.5, 0.1),
        ])
        XCTAssertNil(frame.handsCenter(minConfidence: 0.3))
    }

    // MARK: - Metric scoring

    func testMetricInsideRangeScoresFull() {
        let m = MetricResult(kind: .shoulderTurn, position: .top, measured: 90,
                             idealLow: 85, idealHigh: 100, weight: 1)
        XCTAssertEqual(m.status, .good)
        XCTAssertEqual(m.score, 100)
        XCTAssertEqual(m.delta, 0)
    }

    func testMetricOutsideRangeFallsOffLinearly() {
        // Range width 15; measured 7.5 below the low bound = half a width = 50.
        let m = MetricResult(kind: .shoulderTurn, position: .top, measured: 77.5,
                             idealLow: 85, idealHigh: 100, weight: 1)
        XCTAssertEqual(m.status, .needsWork)
        XCTAssertEqual(m.score, 50, accuracy: 0.001)
        XCTAssertEqual(m.delta, -7.5, accuracy: 0.001)
    }

    func testMetricScoreFloorsAtZero() {
        let m = MetricResult(kind: .headDrift, position: .top, measured: 100,
                             idealLow: 0, idealHigh: 3, weight: 1)
        XCTAssertEqual(m.score, 0)
    }

    func testOverallScoreIsWeighted() {
        let perfect = MetricResult(kind: .spineTilt, position: .address, measured: 35,
                                   idealLow: 30, idealHigh: 40, weight: 3)
        let zero = MetricResult(kind: .headDrift, position: .top, measured: 100,
                                idealLow: 0, idealHigh: 3, weight: 1)
        // (100*3 + 0*1) / 4 = 75
        XCTAssertEqual(SwingAnalyzer.overallScore(metrics: [perfect, zero]), 75)
    }

    func testOverallScoreEmptyIsZero() {
        XCTAssertEqual(SwingAnalyzer.overallScore(metrics: []), 0)
    }
}
