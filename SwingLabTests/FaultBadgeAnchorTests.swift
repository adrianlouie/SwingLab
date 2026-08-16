import XCTest
@testable import SwingLab

/// Regression tests for `SwingFaultKind.anchor` and `FaultBadgeLayout` —
/// where an on-video fault badge points, and that at most one ever shows
/// per position (see the doc comment on `FaultBadgeLayout` for why more
/// than one would look scattered rather than clean).
final class FaultBadgeAnchorTests: XCTestCase {

    private func frame(handsX: Double = 0.5, handsY: Double = 0.5, bodyX: Double = 0.5) -> PoseFrame {
        SwingFixture.makeFrame(time: 0, handsX: handsX, handsY: handsY, bodyX: bodyX)
    }

    private func fault(_ kind: SwingFaultKind, severity: FaultSeverity = .clear,
                       confidence: Double = 0.9, position: SwingPosition? = .impact) -> SwingFault {
        SwingFault(kind: kind, severity: severity, confidence: confidence, evidence: [], position: position)
    }

    private let geometry = FrameGeometry(container: CGSize(width: 300, height: 500), aspect: 9.0 / 16.0)

    func testHandsBasedFaultsAnchorAtHandsCenter() {
        for kind: SwingFaultKind in [.overTheTop, .casting] {
            XCTAssertEqual(kind.anchor(handedness: .right), .handsCenter, "\(kind) should anchor at the hands")
        }
    }

    func testHipBasedFaultsAnchorAtRoot() {
        for kind: SwingFaultKind in [.sway, .slide, .hangBack, .reversePivot, .fatTendency, .thinTendency] {
            XCTAssertEqual(kind.anchor(handedness: .right), .joint(.root), "\(kind) should anchor at the hips")
        }
    }

    func testBodyHeightFaultsAnchorAtNeck() {
        for kind: SwingFaultKind in [.earlyExtension, .bodyDrop, .bodyRise] {
            XCTAssertEqual(kind.anchor(handedness: .right), .joint(.neck), "\(kind) should anchor at the neck")
        }
    }

    func testRetiredFaultHasNoAnchor() {
        XCTAssertNil(SwingFaultKind.insideOut.anchor(handedness: .right),
                    "A retired, never-visible fault should never resolve to a screen point")
    }

    func testOnlyOneBadgeShownEvenWithSeveralFaultsAtThePosition() {
        let faults = [
            fault(.earlyExtension, severity: .slight, confidence: 0.5),
            fault(.bodyDrop, severity: .severe, confidence: 0.95),
            fault(.bodyRise, severity: .clear, confidence: 0.8),
        ]
        let badges = FaultBadgeLayout.badges(for: .impact, faults: faults, frameRate: 60,
                                             includeLowerConfidence: true, handedness: .right,
                                             frame: frame(), geometry: geometry)
        XCTAssertEqual(badges.count, 1, "At most one badge should ever render per position")
        XCTAssertEqual(badges.first?.fault.kind, .bodyDrop, "The firmest (most severe) fault should win")
    }

    func testNoBadgeForAPositionWithNoFaults() {
        let faults = [fault(.overTheTop, position: .delivery)]
        let badges = FaultBadgeLayout.badges(for: .impact, faults: faults, frameRate: 60,
                                             includeLowerConfidence: true, handedness: .right,
                                             frame: frame(), geometry: geometry)
        XCTAssertTrue(badges.isEmpty, "A fault tagged to a different position shouldn't badge here")
    }

    func testLowConfidenceFaultNeverBadgedWhenExcluded() {
        // Below FaultDisplay.threshold(frameRate: 60) == 0.40.
        let faults = [fault(.overTheTop, confidence: 0.2)]
        let badges = FaultBadgeLayout.badges(for: .impact, faults: faults, frameRate: 60,
                                             includeLowerConfidence: false, handedness: .right,
                                             frame: frame(), geometry: geometry)
        XCTAssertTrue(badges.isEmpty, "A read too low-confidence to display anywhere else must not badge either")
    }

    func testBadgeTextNamesTheFaultAndPosition() {
        let faults = [fault(.overTheTop, position: .delivery)]
        let badges = FaultBadgeLayout.badges(for: .delivery, faults: faults, frameRate: 60,
                                             includeLowerConfidence: true, handedness: .right,
                                             frame: frame(), geometry: geometry)
        XCTAssertEqual(badges.first?.text, "Over the top at Delivery")
    }
}
