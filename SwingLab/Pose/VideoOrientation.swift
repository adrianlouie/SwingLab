import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// Reconciles the two coordinate spaces a video lives in.
///
/// `AVAssetReaderTrackOutput` hands back raw decoded buffers, which ignore the
/// track's rotation. An iPhone portrait clip is really a 1920×1080 landscape
/// buffer plus a 90° transform. Meanwhile `AVAssetImageGenerator` with
/// `appliesPreferredTrackTransform` returns the rotated, upright image.
///
/// Feeding raw buffers to Vision without saying so means it analyses a golfer
/// lying on their side — bad keypoints — and returns coordinates in a space the
/// displayed frame doesn't share. Passing the orientation fixes both at once:
/// Vision detects upright, and returns coordinates normalised to the *oriented*
/// image, which is exactly the space the displayed still lives in.
///
/// Verified empirically against real iPhone footage (see the notes on
/// `PoseExtractionDiagnostics`): a 90° transform needs `.right`, and the
/// resulting points land on the body with no further correction.
struct VideoOrientation {
    /// What to hand `VNImageRequestHandler`.
    let cgOrientation: CGImagePropertyOrientation
    /// Size of the image after rotation — the space Vision's normalised
    /// coordinates refer to once `cgOrientation` is supplied.
    let orientedSize: CGSize
    /// Clockwise rotation the transform encodes, in degrees (0/90/180/270).
    let rotationDegrees: Int

    var aspect: Double {
        guard orientedSize.height > 0 else { return 1 }
        return Double(orientedSize.width / orientedSize.height)
    }

    init(preferredTransform t: CGAffineTransform, naturalSize: CGSize) {
        let radians = atan2(Double(t.b), Double(t.a))
        var degrees = Int((radians * 180 / .pi).rounded())
        if degrees < 0 { degrees += 360 }
        rotationDegrees = degrees

        switch degrees {
        case 90:  cgOrientation = .right
        case 180: cgOrientation = .down
        case 270: cgOrientation = .left
        default:  cgOrientation = .up
        }

        let transformed = naturalSize.applying(t)
        orientedSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    /// Direct construction for when there's no file transform to read — live
    /// capture. `LivePracticeSession` locks the preview to portrait (see its
    /// own comment on why), so this is always `.right` there: the same
    /// mapping this file's own doc comment already establishes for a
    /// back-camera, 90°-rotated portrait capture, just arriving from the
    /// camera live instead of a recorded file's stored transform.
    init(cgOrientation: CGImagePropertyOrientation, orientedSize: CGSize, rotationDegrees: Int) {
        self.cgOrientation = cgOrientation
        self.orientedSize = orientedSize
        self.rotationDegrees = rotationDegrees
    }

    static func load(from track: AVAssetTrack) async throws -> VideoOrientation {
        let transform = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        return VideoOrientation(preferredTransform: transform, naturalSize: natural)
    }
}

/// Sanity check on a detected pose: a standing golfer's head should be far
/// above their ankles, not beside them. If this reads low across a whole clip
/// the orientation is wrong, and we would rather say so than silently emit
/// garbage angles.
enum UprightnessCheck {

    /// 1.0 = perfectly vertical head-to-ankle, 0.0 = perfectly horizontal.
    static func score(_ frame: PoseFrame) -> Double? {
        guard let head = frame[.nose] ?? frame[.neck],
              let ankle = frame[.leftAnkle] ?? frame[.rightAnkle],
              head.confidence > 0.2, ankle.confidence > 0.2 else { return nil }
        let dx = abs(head.x - ankle.x)
        let dy = abs(head.y - ankle.y)
        guard dx + dy > 0.0001 else { return nil }
        return dy / (dx + dy)
    }

    /// Mean score across frames that have a usable pose.
    static func meanScore(_ frames: [PoseFrame]) -> Double? {
        let scores = frames.compactMap(score)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Real footage of an upright golfer scores well above this; a 90°-wrong
    /// orientation lands around 0.37.
    static let threshold = 0.5
}
