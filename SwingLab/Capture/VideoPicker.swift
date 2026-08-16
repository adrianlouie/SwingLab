import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Picks one video from the photo library and copies it somewhere we own.
///
/// This deliberately does *not* use `PhotosPicker` + `Transferable`.
/// `FileRepresentation` is designed for exporting a file the app already owns;
/// on the way in, Photos vends a security-scoped URL that it can't resolve, and
/// the failure surfaces as an opaque "CoreTransferable support error 0". Going
/// through `NSItemProvider.loadFileRepresentation` directly is the supported
/// path for large media, streams rather than loading the whole clip into
/// memory, and doesn't need photo-library permission at all, because the picker
/// runs out of process.
struct VideoPicker: UIViewControllerRepresentable {
    /// Called with a URL inside our own temporary directory, or an error.
    let onPicked: (Result<URL, Error>?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        // Ask for the original rather than a transcode, so the frame rate and
        // rotation metadata analysis depends on survive intact.
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: (Result<URL, Error>?) -> Void
        private var hasFinished = false

        init(onPicked: @escaping (Result<URL, Error>?) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !hasFinished else { return }
            hasFinished = true

            guard let provider = results.first?.itemProvider else {
                finish(nil)                       // user cancelled
                return
            }

            // Ask for whichever movie type this asset actually is, rather than
            // assuming .movie: Photos vends .quickTimeMovie for iPhone
            // recordings and .mpeg4Movie for plenty of imported clips.
            let candidates = [UTType.movie, .quickTimeMovie, .mpeg4Movie, .video]
            guard let type = candidates.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) else {
                finish(.failure(VideoPickerError.notAVideo))
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, error in
                // The vended URL is only valid inside this closure, so copy
                // before returning.
                if let error {
                    self?.finish(.failure(error))
                    return
                }
                guard let url else {
                    self?.finish(.failure(VideoPickerError.noFile))
                    return
                }
                do {
                    let destination = try VideoPicker.copyToTemporary(url)
                    self?.finish(.success(destination))
                } catch {
                    self?.finish(.failure(error))
                }
            }
        }

        private func finish(_ result: Result<URL, Error>?) {
            DispatchQueue.main.async { [onPicked] in onPicked(result) }
        }
    }

    static func copyToTemporary(_ source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)

        // Some providers hand back a security-scoped URL; ask for access and
        // give it back afterwards. Harmless when it isn't scoped.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

enum VideoPickerError: LocalizedError {
    case notAVideo
    case noFile

    var errorDescription: String? {
        switch self {
        case .notAVideo:
            return "That item isn't a video SwingLab can read."
        case .noFile:
            return "The video couldn't be copied out of your photo library. If it's stored in iCloud, let it finish downloading and try again."
        }
    }
}
