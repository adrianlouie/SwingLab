import XCTest
@testable import SwingLab

/// Regression tests for "it only allows one upload and then bugs out."
///
/// The bug was a state machine that relied entirely on SwiftUI writing values
/// back through presentation bindings, with no explicit reset anywhere. These
/// tests drive the coordinator directly so the sequencing is verified without
/// depending on SwiftUI's presentation timing.
@MainActor
final class ImportCoordinatorTests: XCTestCase {

    private func makeRecord(score: Double = 80) -> SwingRecord {
        SwingRecord(videoFileName: "test-\(UUID().uuidString).mov",
                    viewType: .faceOn,
                    handedness: .right,
                    shotType: .fullSwing,
                    overallScore: score,
                    thumbnailData: nil,
                    analysis: nil,
                    coachingText: "")
    }

    private func tempVideo() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-test-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        return url
    }

    // MARK: - Core flow

    func testBeginPresentsSetupStep() {
        let coordinator = ImportCoordinator()
        let url = tempVideo()
        coordinator.begin(videoURL: url)
        XCTAssertEqual(coordinator.step, .setup(url))
        XCTAssertTrue(coordinator.isPresenting)
    }

    func testFinishClosesSheetAndDefersThePush() {
        let coordinator = ImportCoordinator()
        coordinator.begin(videoURL: tempVideo())
        let record = makeRecord()

        coordinator.finish(record: record)

        // Sheet closes immediately, but the push waits for dismissal — doing
        // both at once is what SwiftUI drops.
        XCTAssertNil(coordinator.step)
        XCTAssertNotNil(coordinator.pendingPush)

        var pushed: SwingRecord?
        coordinator.consumePendingPush { pushed = $0 }
        XCTAssertIdentical(pushed, record)
        XCTAssertNil(coordinator.pendingPush)
    }

    func testPendingPushIsDeliveredOnlyOnce() {
        let coordinator = ImportCoordinator()
        coordinator.begin(videoURL: tempVideo())
        coordinator.finish(record: makeRecord())

        var count = 0
        coordinator.consumePendingPush { _ in count += 1 }
        coordinator.consumePendingPush { _ in count += 1 }
        XCTAssertEqual(count, 1, "A stale push must not fire again on the next dismissal")
    }

    func testConsumePendingPushDoesNothingWhenIdle() {
        let coordinator = ImportCoordinator()
        var called = false
        coordinator.consumePendingPush { _ in called = true }
        XCTAssertFalse(called)
    }

    // MARK: - The reported bug

    /// Three imports back to back. Under the old design the second one silently
    /// did nothing because a latch was left set with no code path to clear it.
    func testManySequentialImportsAllPresentAndPush() {
        let coordinator = ImportCoordinator()
        var pushedRecords: [SwingRecord] = []

        for i in 0..<3 {
            let url = tempVideo()
            coordinator.begin(videoURL: url)
            XCTAssertEqual(coordinator.step, .setup(url),
                           "Import \(i + 1) should present its own setup step")

            coordinator.finish(record: makeRecord(score: Double(i)))
            XCTAssertNil(coordinator.step, "Import \(i + 1) should close its sheet")

            coordinator.consumePendingPush { pushedRecords.append($0) }
        }

        XCTAssertEqual(pushedRecords.count, 3)
        XCTAssertEqual(pushedRecords.map(\.overallScore), [0, 1, 2])
    }

    func testCancelLeavesNoResidualState() {
        let coordinator = ImportCoordinator()
        coordinator.begin(videoURL: tempVideo())
        coordinator.cancel()

        XCTAssertNil(coordinator.step)
        XCTAssertNil(coordinator.pendingPush)
        XCTAssertFalse(coordinator.isPresenting)

        // And a fresh import still works afterwards.
        let url = tempVideo()
        coordinator.begin(videoURL: url)
        XCTAssertEqual(coordinator.step, .setup(url))
    }

    func testImportAfterAFailureStillWorks() {
        let coordinator = ImportCoordinator()
        coordinator.fail("broken file")
        XCTAssertEqual(coordinator.step, .failed("broken file"))

        coordinator.cancel()
        let url = tempVideo()
        coordinator.begin(videoURL: url)
        XCTAssertEqual(coordinator.step, .setup(url))
    }

    // MARK: - Photo-library picking

    func testStartPickingPresentsThePicker() {
        let coordinator = ImportCoordinator()
        coordinator.startPicking()
        XCTAssertEqual(coordinator.step, .picking)
    }

    /// The picked clip is held until the picker has dismissed, for the same
    /// reason the results push is: starting one presentation inside another's
    /// teardown is unreliable.
    func testPickedVideoOpensSetupOnlyAfterThePickerDismisses() {
        let coordinator = ImportCoordinator()
        let url = tempVideo()
        coordinator.startPicking()

        coordinator.stagePickedVideo(.success(url))
        XCTAssertNil(coordinator.step, "Picker should close first")

        coordinator.consumePickedVideo()
        XCTAssertEqual(coordinator.step, .setup(url))
    }

    func testCancellingThePickerLeavesNothingBehind() {
        let coordinator = ImportCoordinator()
        coordinator.startPicking()
        coordinator.stagePickedVideo(nil)          // user tapped Cancel
        coordinator.consumePickedVideo()
        XCTAssertNil(coordinator.step)
    }

    func testPickerFailureSurfacesAsAFailedStep() {
        let coordinator = ImportCoordinator()
        coordinator.startPicking()
        coordinator.stagePickedVideo(.failure(VideoPickerError.noFile))
        coordinator.consumePickedVideo()

        guard case .failed(let message)? = coordinator.step else {
            return XCTFail("expected a failure step")
        }
        XCTAssertTrue(message.contains("iCloud"),
                      "The message should hint at the usual cause rather than an opaque code")
    }

    func testConsumingAPickTwiceOnlyOpensSetupOnce() {
        let coordinator = ImportCoordinator()
        coordinator.stagePickedVideo(.success(tempVideo()))
        coordinator.consumePickedVideo()
        coordinator.cancel()

        coordinator.consumePickedVideo()
        XCTAssertNil(coordinator.step, "A consumed pick must not re-present")
    }

    func testPickingRepeatedlyWorks() {
        let coordinator = ImportCoordinator()
        for i in 0..<3 {
            coordinator.startPicking()
            let url = tempVideo()
            coordinator.stagePickedVideo(.success(url))
            coordinator.consumePickedVideo()
            XCTAssertEqual(coordinator.step, .setup(url), "Pick \(i + 1) should open setup")
            coordinator.finish(record: makeRecord())
            coordinator.consumePendingPush { _ in }
        }
    }

    // MARK: - Recording

    func testRecordedVideoIsHeldUntilTheCameraDismisses() {
        let coordinator = ImportCoordinator()
        let url = tempVideo()

        coordinator.stageRecordedVideo(url)
        XCTAssertNil(coordinator.step,
                     "Opening a sheet while the recorder is still dismissing is what breaks")

        coordinator.consumeRecordedVideo()
        XCTAssertEqual(coordinator.step, .setup(url))
    }

    func testConsumingRecordedVideoTwiceOnlyPresentsOnce() {
        let coordinator = ImportCoordinator()
        coordinator.stageRecordedVideo(tempVideo())
        coordinator.consumeRecordedVideo()
        coordinator.cancel()

        coordinator.consumeRecordedVideo()
        XCTAssertNil(coordinator.step, "A consumed recording must not re-present")
    }

    func testDismissingTheRecorderWithoutRecordingDoesNothing() {
        let coordinator = ImportCoordinator()
        coordinator.consumeRecordedVideo()
        XCTAssertNil(coordinator.step)
    }

    // MARK: - Temp files

    /// Each import copied ~48 MB into the temp directory and never removed it.
    func testTemporaryFileIsRemovedOnCancel() {
        let coordinator = ImportCoordinator()
        let url = tempVideo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        coordinator.begin(videoURL: url)
        coordinator.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Cancelling an import should not leave the clip behind")
    }

    func testTemporaryFileIsRemovedAfterFinishing() {
        let coordinator = ImportCoordinator()
        let url = tempVideo()
        coordinator.begin(videoURL: url)
        coordinator.finish(record: makeRecord())

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNonTemporarySourceIsLeftAlone() {
        let coordinator = ImportCoordinator()
        let url = tempVideo()
        coordinator.begin(videoURL: url, isTemporary: false)
        coordinator.cancel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "A file we don't own must never be deleted")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Step identity

    /// `.sheet(item:)` reuses the presented view when the id is unchanged, so
    /// two different clips must produce different ids.
    func testStepsForDifferentVideosHaveDifferentIdentities() {
        let a = ImportCoordinator.Step.setup(tempVideo())
        let b = ImportCoordinator.Step.setup(tempVideo())
        XCTAssertNotEqual(a.id, b.id)
    }
}
