import SwiftUI
import Observation

/// Owns the record/import → analyse → show-results flow.
///
/// The original code hung five presentation modifiers off one view — a
/// fullScreenCover, two sheets, a photosPicker and an alert — and pushed the
/// results screen from *inside* a sheet at the same moment that sheet was
/// dismissing. SwiftUI drops a navigation change made during a presentation
/// teardown, which left state stuck in its "presented" value with nothing on
/// screen, and since none of that state was ever reset in code, every later
/// import silently did nothing.
///
/// The rules here are what keep it reliable:
///   1. Exactly one sheet-class presentation is driven from this coordinator.
///   2. Navigation happens in the sheet's `onDismiss`, never inside its body.
///   3. Every piece of state has an explicit reset path.
@MainActor
@Observable
final class ImportCoordinator {

    /// The single sheet's content. One optional item, so there is one source of
    /// truth for "is something presented".
    enum Step: Identifiable, Equatable {
        case picking
        case setup(URL)
        case failed(String)

        var id: String {
            switch self {
            case .picking: return "picking"
            case .setup(let url): return "setup-\(url.absoluteString)"
            case .failed(let message): return "failed-\(message)"
            }
        }
    }

    var step: Step?

    /// Held until the sheet has fully dismissed, then handed to the navigation
    /// stack. This deferral is the core fix.
    private(set) var pendingPush: SwingRecord?

    /// Temp file backing the current step, deleted when we're done with it.
    private var temporaryURL: URL?

    /// A just-recorded clip, held until the camera has finished dismissing —
    /// same reason as `pendingPush`: opening a sheet from inside another
    /// presentation's teardown is unreliable.
    private var recordedURL: URL?

    /// Outcome of the photo-library picker, held until it has dismissed.
    private var pickedURL: URL?
    private var pickedError: String?

    var isPresenting: Bool { step != nil }

    // MARK: - Flow

    func begin(videoURL: URL, isTemporary: Bool = true) {
        temporaryURL = isTemporary ? videoURL : nil
        step = .setup(videoURL)
    }

    /// Called from the recorder's completion, while it is still on screen.
    func stageRecordedVideo(_ url: URL) {
        recordedURL = url
    }

    /// Called from the recorder's `onDismiss`, once it's safely gone.
    func consumeRecordedVideo() {
        guard let url = recordedURL else { return }
        recordedURL = nil
        begin(videoURL: url)
    }

    func startPicking() {
        step = .picking
    }

    /// The picker finished. Stash the outcome and close — the setup sheet opens
    /// from `onDismiss`, for the same reason the results push does: starting a
    /// presentation inside another one's teardown is unreliable.
    func stagePickedVideo(_ result: Result<URL, Error>?) {
        switch result {
        case .success(let url): pickedURL = url
        case .failure(let error): pickedError = error.localizedDescription
        case nil: break                      // cancelled
        }
        step = nil
    }

    func consumePickedVideo() {
        if let url = pickedURL {
            pickedURL = nil
            begin(videoURL: url)
        } else if let message = pickedError {
            pickedError = nil
            fail(message)
        }
    }

    func fail(_ message: String) {
        cleanUpTemporaryFile()
        step = .failed(message)
    }

    /// Analysis finished. Stash the record and close the sheet; the push
    /// happens once dismissal completes.
    func finish(record: SwingRecord) {
        pendingPush = record
        // The video has been copied into the library by now.
        cleanUpTemporaryFile()
        step = nil
    }

    func cancel() {
        cleanUpTemporaryFile()
        step = nil
    }

    /// Called from the sheet's `onDismiss`. Safe point to change navigation.
    func consumePendingPush(_ push: (SwingRecord) -> Void) {
        guard let record = pendingPush else { return }
        pendingPush = nil
        push(record)
    }

    private func cleanUpTemporaryFile() {
        if let url = temporaryURL {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURL = nil
    }
}
