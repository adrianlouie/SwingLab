import XCTest
@testable import SwingLab

/// Regression tests for `ModelProProfile`'s Custom-mode configuration —
/// enabling/disabling (metric, position) pairs must never delete
/// calibration, and `targets(shotType:view:)` (the one function
/// `SwingAnalyzer.analyze` actually reads) must reflect Custom filtering
/// exactly, since that's what makes Custom config affect real scoring and
/// not just what's displayed.
final class ModelProProfileConfigTests: XCTestCase {

    func testStandardModeIsByteIdenticalToBeforeConfigExisted() {
        let profile = ModelProProfile.default
        XCTAssertEqual(profile.configMode, .standard)
        let seeded = profile.targets(shotType: .fullSwing, view: .faceOn)
        // Every seeded row for this shot type/view should come through
        // unfiltered — Standard mode must not drop anything.
        let seededCount = profile.targets.filter { $0.shotType == .fullSwing && $0.view == .faceOn }.count
        XCTAssertEqual(seeded.count, seededCount)
    }

    func testCustomModeWithNilEnabledSetBehavesLikeStandard() {
        var profile = ModelProProfile.default
        profile.configModeRaw = .custom
        // enabledTargetIDs left nil — "customized but nothing chosen yet."
        let targets = profile.targets(shotType: .fullSwing, view: .faceOn)
        let seededCount = profile.targets.filter { $0.shotType == .fullSwing && $0.view == .faceOn }.count
        XCTAssertEqual(targets.count, seededCount)
    }

    func testCustomModeWithEmptySetDisablesEverything() {
        var profile = ModelProProfile.default
        profile.configModeRaw = .custom
        profile.enabledTargetIDs = [] // explicit: the user unchecked everything
        XCTAssertTrue(profile.targets(shotType: .fullSwing, view: .faceOn).isEmpty)
    }

    func testDisablingATargetNeverDeletesItsCalibration() {
        var profile = ModelProProfile.default
        guard let spineTarget = profile.targets.first(where: {
            $0.shotType == .fullSwing && $0.view == .faceOn && $0.kind == .spineTilt
        }) else {
            return XCTFail("expected a seeded spineTilt target for fullSwing/faceOn")
        }
        // Hand-tune it, the way Settings' TargetEditor would.
        if let idx = profile.targets.firstIndex(where: { $0.id == spineTarget.id }) {
            profile.targets[idx].low = 2
            profile.targets[idx].high = 12
        }

        profile.configModeRaw = .custom
        profile.enabledTargetIDs = Set(profile.targets
            .filter { $0.shotType == .fullSwing && $0.view == .faceOn && $0.kind != .spineTilt }
            .map(\.id))

        XCTAssertFalse(profile.targets(shotType: .fullSwing, view: .faceOn).isEmpty)
        XCTAssertNil(profile.target(shotType: .fullSwing, view: .faceOn, position: .address, kind: .spineTilt),
                    "Disabled in Custom mode, so it shouldn't be scored")
        XCTAssertEqual(profile.targets.first(where: { $0.id == spineTarget.id })?.low, 2,
                       "Disabling must not delete the tuned calibration underneath")

        // Re-enable: the tuned numbers should come back exactly.
        profile.enabledTargetIDs?.insert(spineTarget.id)
        let restored = profile.target(shotType: .fullSwing, view: .faceOn, position: .address, kind: .spineTilt)
        XCTAssertEqual(restored?.low, 2)
        XCTAssertEqual(restored?.high, 12)
    }

    func testEnablingAPairNeverSeededSynthesizesAStartingTarget() {
        var profile = ModelProProfile.default
        // hipTurn at .address was never seeded for fullSwing/faceOn.
        let syntheticID = MetricTarget(shotType: .fullSwing, view: .faceOn, position: .address,
                                       kind: .hipTurn, low: 0, high: 0).id
        XCTAssertNil(profile.targets.first(where: { $0.id == syntheticID }),
                    "sanity check: this pair really isn't pre-seeded")

        profile.configModeRaw = .custom
        profile.enabledTargetIDs = Set(profile.targets
            .filter { $0.shotType == .fullSwing && $0.view == .faceOn }.map(\.id))
        profile.enabledTargetIDs?.insert(syntheticID)

        let target = profile.target(shotType: .fullSwing, view: .faceOn, position: .address, kind: .hipTurn)
        XCTAssertNotNil(target, "Enabling a never-seeded pair should synthesize a usable starting target")
        XCTAssertLessThan(target?.low ?? 0, target?.high ?? 0)
    }

    func testRetiredKindsStayInertEvenIfSomehowEnabled() {
        var profile = ModelProProfile.default
        profile.configModeRaw = .custom
        let bogusID = MetricTarget(shotType: .fullSwing, view: .downTheLine, position: .impact,
                                   kind: .swingPath, low: -5, high: 5).id
        profile.enabledTargetIDs = [bogusID]
        XCTAssertTrue(profile.targets(shotType: .fullSwing, view: .downTheLine).isEmpty,
                     "A retired kind must never resurface via Custom mode")
    }

    func testMetricTargetIDRoundTripsThroughParse() {
        let target = MetricTarget(shotType: .pitch, view: .downTheLine, position: .top,
                                  kind: .postureChange, low: 0, high: 5)
        let parsed = MetricTarget.parse(id: target.id)
        XCTAssertEqual(parsed?.shotType, .pitch)
        XCTAssertEqual(parsed?.view, .downTheLine)
        XCTAssertEqual(parsed?.position, .top)
        XCTAssertEqual(parsed?.kind, .postureChange)
    }
}
