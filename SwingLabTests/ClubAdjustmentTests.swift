import XCTest
@testable import SwingLab

/// `ClubAdjustment` is what lets one club selection shift every posture and
/// turn target without hand-seeding 500 more `MetricTarget` rows. These
/// tests pin the invariants the plan called out explicitly: the 7-iron is a
/// true no-op (old records must re-score byte-identically), the window
/// shifts rather than scales for most metrics (a widened tolerance stays
/// widened), floored metrics never go negative, and — the one deliberate
/// exception — spine tilt's window actually WIDENS the further a club sits
/// from the 7-iron reference, on top of the shift, because body proportions
/// make a single fixed-width window less trustworthy out at the edges of
/// the bag.
final class ClubAdjustmentTests: XCTestCase {

    func testSevenIronIsIdenticalToUnspecified() {
        let unspecified = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: nil)
        let sevenIron = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .sevenIron)
        XCTAssertEqual(unspecified.low, sevenIron.low)
        XCTAssertEqual(unspecified.high, sevenIron.high)
        XCTAssertEqual(sevenIron.low, 28)
        XCTAssertEqual(sevenIron.high, 42)
    }

    func testLongerClubReducesSpineTilt() {
        // Standing taller for a longer club — less forward bend.
        let iron = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .sevenIron)
        let driver = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .driver)
        XCTAssertLessThan(driver.low, iron.low)
        XCTAssertLessThan(driver.high, iron.high)
    }

    func testShorterClubIncreasesSpineTilt() {
        let iron = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .sevenIron)
        let wedge = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .lobWedge)
        XCTAssertGreaterThan(wedge.low, iron.low)
        XCTAssertGreaterThan(wedge.high, iron.high)
    }

    func testMonotonicAcrossTheWholeBag() {
        // Longer club → less spine tilt, strictly, all the way down the bag.
        let ordered: [GolfClub] = [.driver, .threeWood, .fiveIron, .sevenIron, .nineIron, .lobWedge]
        let lows = ordered.map { ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: $0).low }
        XCTAssertEqual(lows, lows.sorted(), "spine tilt must increase monotonically as club length decreases")
    }

    func testWindowIsShiftedNeverScaled() {
        // A widened (hand-calibrated) tolerance must stay exactly as wide at
        // every club — this is a shift, not a rescale. True for every metric
        // except spine tilt (see below), which widens on purpose.
        let narrow = ClubAdjustment.adjusted(low: 85, high: 100, kind: .shoulderTurn, club: .driver)
        let wide = ClubAdjustment.adjusted(low: 80, high: 105, kind: .shoulderTurn, club: .driver)
        XCTAssertEqual(narrow.high - narrow.low, 15, accuracy: 1e-9)
        XCTAssertEqual(wide.high - wide.low, 25, accuracy: 1e-9)
    }

    func testSpineTiltWidensTheFartherTheClubIsFromTheReference() {
        let iron = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .sevenIron)
        let driver = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .driver)
        let wedge = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .lobWedge)

        let ironWidth = iron.high - iron.low
        let driverWidth = driver.high - driver.low
        let wedgeWidth = wedge.high - wedge.low

        XCTAssertEqual(ironWidth, 14, accuracy: 1e-9, "No widening at the reference club itself")
        XCTAssertGreaterThan(driverWidth, ironWidth, "Widens for a club longer than the reference")
        XCTAssertGreaterThan(wedgeWidth, ironWidth, "Widens for a club shorter than the reference too")
    }

    func testSpineTiltWideningIsSymmetricAroundTheShiftedCenter() {
        // Widening must not just push the ceiling up (that would silently
        // re-bias the window instead of genuinely being more forgiving on
        // both sides) — it grows both bounds outward from wherever the
        // shift alone would have put them.
        let shiftedOnly = -1.0 * (GolfClub.driver.length - ClubAdjustment.referenceLength)
        let driver = ClubAdjustment.adjusted(low: 28, high: 42, kind: .spineTilt, club: .driver)
        let shiftedCenter = (28 + 42) / 2 + shiftedOnly
        let actualCenter = (driver.low + driver.high) / 2
        XCTAssertEqual(actualCenter, shiftedCenter, accuracy: 1e-9,
                       "Growth should be symmetric, leaving the shifted center exactly where the shift alone put it")
    }

    func testFlooredMetricsNeverGoNegative() {
        // headDrift/hipSway read as "amount of drift" — can't be negative,
        // so even an extreme shift must leave the low bound at (or above) 0.
        let result = ClubAdjustment.adjusted(low: 0, high: 1, kind: .headDrift, club: .lobWedge)
        XCTAssertGreaterThanOrEqual(result.low, 0)
        XCTAssertGreaterThanOrEqual(result.high, result.low)
    }

    func testFlooredMetricsOnlyMoveTheUpperBound() {
        let result = ClubAdjustment.adjusted(low: 0, high: 3, kind: .hipSway, club: .driver)
        XCTAssertEqual(result.low, 0, "the floor never moves")
        XCTAssertNotEqual(result.high, 3, "the ceiling should shift for a club this different from the reference")
    }

    func testPostureChangeAndPlaneDeviationAreLengthIndependent() {
        for club in GolfClub.allCases {
            let posture = ClubAdjustment.adjusted(low: 0, high: 5, kind: .postureChange, club: club)
            let plane = ClubAdjustment.adjusted(low: 0, high: 12, kind: .planeDeviation, club: club)
            let path = ClubAdjustment.adjusted(low: -4, high: 4, kind: .swingPath, club: club)
            XCTAssertEqual(posture.low, 0)
            XCTAssertEqual(posture.high, 5)
            XCTAssertEqual(plane.low, 0)
            XCTAssertEqual(plane.high, 12)
            XCTAssertEqual(path.low, -4, "swing path is a direction relative to the plane, not an absolute angle that shifts with stance")
            XCTAssertEqual(path.high, 4)
        }
    }
}

/// `SwingAnalyzer` is where the adjusted window actually gets baked into a
/// saved `MetricResult` — confirms the plumbing, not just the pure function.
final class SwingAnalyzerClubTests: XCTestCase {

    private func pose(shoulderHalfWidth: Double, hipHalfWidth: Double, time: Double = 0) -> PoseFrame {
        PoseFrame(time: time, joints: [
            .nose: JointPoint(x: 0.5, y: 0.9, confidence: 0.9),
            .neck: JointPoint(x: 0.5, y: 0.82, confidence: 0.9),
            .leftShoulder: JointPoint(x: 0.5 - shoulderHalfWidth, y: 0.8, confidence: 0.9),
            .rightShoulder: JointPoint(x: 0.5 + shoulderHalfWidth, y: 0.8, confidence: 0.9),
            .leftWrist: JointPoint(x: 0.49, y: 0.5, confidence: 0.9),
            .rightWrist: JointPoint(x: 0.51, y: 0.5, confidence: 0.9),
            .root: JointPoint(x: 0.5, y: 0.52, confidence: 0.9),
            .leftHip: JointPoint(x: 0.5 - hipHalfWidth, y: 0.52, confidence: 0.9),
            .rightHip: JointPoint(x: 0.5 + hipHalfWidth, y: 0.52, confidence: 0.9),
            .leftAnkle: JointPoint(x: 0.42, y: 0.04, confidence: 0.9),
            .rightAnkle: JointPoint(x: 0.58, y: 0.04, confidence: 0.9),
        ])
    }

    func testNoClubReScoresByteIdenticalToSevenIron() {
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        let top = pose(shoulderHalfWidth: 0.02, hipHalfWidth: 0.045, time: 0.8)
        let positions = [
            DetectedPosition(position: .address, frameIndex: 0, time: 0),
            DetectedPosition(position: .top, frameIndex: 1, time: 0.8),
        ]

        let unspecified = SwingAnalyzer.analyze(frames: [address, top], positions: positions,
                                                profile: .default, shotType: .fullSwing,
                                                view: .faceOn, handedness: .right, club: nil)
        let sevenIron = SwingAnalyzer.analyze(frames: [address, top], positions: positions,
                                              profile: .default, shotType: .fullSwing,
                                              view: .faceOn, handedness: .right, club: .sevenIron)

        XCTAssertEqual(unspecified.metrics.map(\.idealLow), sevenIron.metrics.map(\.idealLow))
        XCTAssertEqual(unspecified.metrics.map(\.idealHigh), sevenIron.metrics.map(\.idealHigh))
        XCTAssertEqual(unspecified.overall, sevenIron.overall)
    }

    func testDriverProducesADifferentIdealWindowThanSevenIron() {
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        let top = pose(shoulderHalfWidth: 0.02, hipHalfWidth: 0.045, time: 0.8)
        let positions = [
            DetectedPosition(position: .address, frameIndex: 0, time: 0),
            DetectedPosition(position: .top, frameIndex: 1, time: 0.8),
        ]

        let iron = SwingAnalyzer.analyze(frames: [address, top], positions: positions,
                                         profile: .default, shotType: .fullSwing,
                                         view: .faceOn, handedness: .right, club: .sevenIron)
        let driver = SwingAnalyzer.analyze(frames: [address, top], positions: positions,
                                           profile: .default, shotType: .fullSwing,
                                           view: .faceOn, handedness: .right, club: .driver)

        let ironTurn = iron.metrics.first { $0.kind == .shoulderTurn }
        let driverTurn = driver.metrics.first { $0.kind == .shoulderTurn }
        XCTAssertNotNil(ironTurn)
        XCTAssertNotNil(driverTurn)
        XCTAssertNotEqual(ironTurn?.idealLow, driverTurn?.idealLow)
    }
}
