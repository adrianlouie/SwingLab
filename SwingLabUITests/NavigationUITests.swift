import XCTest

/// Smoke tests that every top-level screen loads and its key controls are
/// present. These drive the real app in the Simulator.
final class NavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        dismissOnboardingIfPresent()
    }

    /// Onboarding auto-presents on a fresh install; close it so the tabs are
    /// reachable.
    private func dismissOnboardingIfPresent() {
        let gotIt = app.buttons["Got it"]
        if gotIt.waitForExistence(timeout: 5) {
            gotIt.tap()
        }
    }

    func testLibraryScreenShowsEmptyStateAndActions() {
        XCTAssertTrue(app.navigationBars["SwingLab"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No swings yet"].exists)
        XCTAssertTrue(app.buttons["Record"].exists)
        XCTAssertTrue(app.buttons["Import"].exists)
        attachScreenshot(named: "Library")
    }

    func testOnboardingCanBeReopened() {
        app.buttons["Got it"].tap(ifExists: true)
        app.navigationBars["SwingLab"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["How to Film"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stand back about 10–15 feet"].exists)
        attachScreenshot(named: "Onboarding")
    }

    func testProgressTabLoads() {
        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 10))
        // With no swings analyzed, the empty state should explain why.
        XCTAssertTrue(app.staticTexts["Not enough swings"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Progress")
    }

    func testSettingsShowsEditableIdealRanges() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // The Feedback (Standard/Custom) section sits above the per-category
        // metric editors, so — same as testSettingsShotTypeAndViewPickersChangeContent
        // below — the list renders lazily and needs a scroll to reach them.
        let spineAngle = app.staticTexts["Spine Angle"]
        var attempts = 0
        while !spineAngle.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(spineAngle.waitForExistence(timeout: 3))

        // Spine Angle (Setup Posture) is the first category and typically
        // visible with zero scrolling, but Shoulder Turn/Head Drift sit in
        // later categories (Body Rotation/Head Stability) further down —
        // needs its own scroll-until-found, not just whatever scrolling
        // (possibly none) it took to find Spine Angle above.
        attempts = 0
        while !app.staticTexts["Shoulder Turn"].exists && !app.staticTexts["Head Drift"].exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(app.staticTexts["Shoulder Turn"].exists || app.staticTexts["Head Drift"].exists)
        attachScreenshot(named: "Settings")
    }

    /// Each swing position should head exactly one section — the earlier bug
    /// produced several consecutive sections all titled "Top".
    func testSettingsGroupsEachPositionIntoOneSection() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let topHeaders = app.staticTexts.matching(NSPredicate(format: "label == %@", "Top"))
        XCTAssertLessThanOrEqual(topHeaders.count, 1,
                                 "Found \(topHeaders.count) 'Top' section headers; positions should be grouped")
    }

    func testSettingsShotTypeAndViewPickersChangeContent() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Switch to Down-the-Line, which has plane/posture metrics that the
        // face-on profile does not.
        app.buttons["Camera View, Face-On"].tap()
        XCTAssertTrue(app.buttons["Down-the-Line"].waitForExistence(timeout: 5))
        app.buttons["Down-the-Line"].tap()

        // The list renders lazily, so scroll until a DTL-only metric appears.
        let postureChange = app.staticTexts["Posture Change"]
        var attempts = 0
        while !postureChange.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(postureChange.exists,
                      "Down-the-Line profile should expose posture/plane targets")
        attachScreenshot(named: "Settings-DTL")
    }

    func testSettingsShowsAnExplanationForEachMetric() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let spineAngle = app.staticTexts["Spine Angle"]
        var attempts = 0
        while !spineAngle.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(spineAngle.waitForExistence(timeout: 3))
        // The plain-language description should sit under the metric name.
        let description = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Forward tilt of your spine")
        ).firstMatch
        XCTAssertTrue(description.exists, "Each setting should explain what it controls")
    }

    func testSettingsFeedbackModeTogglesToCustomConfig() {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Custom"].waitForExistence(timeout: 5))
        app.buttons["Custom"].tap()

        let configLink = app.buttons["Choose What to Measure"]
        XCTAssertTrue(configLink.waitForExistence(timeout: 5))
        configLink.tap()
        XCTAssertTrue(app.navigationBars["Choose What to Measure"].waitForExistence(timeout: 5))
        // "Setup Posture" is a MetricCategory section header — the same
        // proven-reliable static-text-section-header pattern the other
        // Settings tests already check (e.g. "Posture Change" above).
        XCTAssertTrue(app.staticTexts["Setup Posture"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Settings-CustomConfig")
    }

    func testRecordScreenOpensAndCloses() {
        app.buttons["Record"].tap()
        // The Simulator has no camera, so we expect either the permission
        // prompt path or the failure message — never a crash or a hang.
        let closed = app.buttons["Import"].waitForExistence(timeout: 8)
        XCTAssertTrue(closed || app.state == .runningForeground,
                      "App should stay responsive after opening the recorder")
        attachScreenshot(named: "Record")
    }

    /// Same "no crash, no hang" bar as `testRecordScreenOpensAndCloses` —
    /// the Simulator has no camera, so `LivePracticeSession` should land on
    /// its `.denied`/`.failed` state, not crash, and switching away should
    /// tear the session down cleanly (`onDisappear` -> `session.stop()`)
    /// rather than leaving a dangling capture session behind.
    func testPracticeTabOpensAndStaysResponsive() {
        app.tabBars.buttons["Practice"].tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        attachScreenshot(named: "Practice")
        XCTAssertEqual(app.state, .runningForeground, "App should stay responsive with Practice open")

        // Switching away and back should be clean, not crash on teardown.
        app.tabBars.buttons["Swings"].tap()
        XCTAssertTrue(app.navigationBars["SwingLab"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Taps only when the element is actually on screen, for optional steps.
    func tap(ifExists: Bool) {
        if ifExists && exists && isHittable { tap() }
    }
}
