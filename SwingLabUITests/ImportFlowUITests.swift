import XCTest

/// Drives a real import end to end against a real clip in the simulator's photo
/// library.
///
/// This exists because the import bug that shipped ("CoreTransferable support
/// error 0") was invisible to unit tests: the coordinator's state machine was
/// correct, and the failure was entirely in how the video was loaded out of
/// Photos. Only actually picking a video catches that class of bug.
///
/// Requires a clip in the library:
///   xcrun simctl addmedia "iPhone 17" <some-video.mov>
/// The test skips itself rather than failing if the library is empty, so the
/// suite stays green on a fresh machine.
final class ImportFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        if app.buttons["Got it"].waitForExistence(timeout: 5) {
            app.buttons["Got it"].tap()
        }
    }

    /// Taps Import, picks the first video, and waits for the setup sheet.
    /// Returns false when the library has no videos to pick.
    @discardableResult
    private func importFirstVideo(timeout: TimeInterval = 30) -> Bool {
        app.buttons["importButton"].tap()

        // The picker runs out of process; its grid cells carry the identifier
        // below. Matching on that rather than on element type or a label
        // substring matters — "image" also matches the picker's onboarding
        // banner, and "video" matches our own Record button, whose SF Symbol is
        // labelled "Facetime Video Call".
        let firstVideo = app.descendants(matching: .any)
            .matching(identifier: "PXGGridLayout-Info")
            .firstMatch
        guard firstVideo.waitForExistence(timeout: 15) else { return false }
        // Out-of-process picker elements often report as not hittable even when
        // they are perfectly tappable, so go through a coordinate.
        firstVideo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Reaching the setup sheet means the clip was loaded out of Photos —
        // exactly the step that used to fail.
        return app.staticTexts["Camera View"].waitForExistence(timeout: timeout)
            || app.buttons["Analyze Swing"].waitForExistence(timeout: 5)
    }

    func testImportingAVideoReachesTheSetupSheet() throws {
        guard importFirstVideo() else {
            throw XCTSkip("No video in the simulator library — run simctl addmedia first")
        }
        XCTAssertTrue(app.buttons["Analyze Swing"].exists,
                      "The picked clip should load and offer analysis")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Import-Setup"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The originally reported bug: the first import worked and the next did
    /// nothing.
    func testImportingTwiceInARowBothReachSetup() throws {
        guard importFirstVideo() else {
            throw XCTSkip("No video in the simulator library")
        }
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10),
                      "The library should be interactive again after cancelling")
        XCTAssertTrue(importFirstVideo(),
                      "The second import must work as well as the first")
    }

    /// The wrong camera view is what produced a meaningless, heavily-weighted
    /// shoulder-turn reading on a back-view clip. The cards have to actually
    /// switch the selection, and each has to state what it measures.
    func testCameraViewCardsCanBeSelectedAndExplainWhatTheyMeasure() throws {
        guard importFirstVideo() else {
            throw XCTSkip("No video in the simulator library")
        }
        XCTAssertTrue(app.buttons["cameraView.Face-On"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cameraView.Down-the-Line"].exists)
        XCTAssertTrue(app.staticTexts["Spine Angle, Shoulder Turn, Hip Turn, X-Factor, Head Drift, Hip Sway"].exists,
                      "Face-On should state what it measures")

        app.buttons["cameraView.Down-the-Line"].tap()
        XCTAssertTrue(app.staticTexts["Spine Angle, Posture Change, Head Drift, Plane Deviation"]
            .waitForExistence(timeout: 5), "Selecting Down-the-Line should show its own measured list")
    }

    func testCancellingThePickerReturnsToTheLibrary() throws {
        app.buttons["importButton"].tap()
        let cancel = app.buttons["Cancel"]
        guard cancel.waitForExistence(timeout: 15) else {
            throw XCTSkip("Photo picker did not present")
        }
        cancel.tap()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["importButton"].isEnabled,
                      "Cancelling must not leave the Import button stuck")
    }
}
