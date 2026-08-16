import Foundation

/// Owns the on-disk video files for the swing library, inside the app's
/// Application Support sandbox.
enum VideoStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SwingVideos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Copies a recorded/imported video into the library and returns the
    /// stored file name.
    static func store(videoAt sourceURL: URL) throws -> String {
        let fileName = UUID().uuidString + "." + (sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)
        let destination = url(for: fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return fileName
    }

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
