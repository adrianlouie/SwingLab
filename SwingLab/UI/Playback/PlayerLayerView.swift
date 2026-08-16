import AVFoundation
import SwiftUI

/// A `UIView` whose backing layer *is* an `AVPlayerLayer`, so sizing the view
/// sizes the layer for free through ordinary UIKit bounds-tracking — no
/// manual `layoutSubviews` frame math needed.
final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Wraps the container above so SwiftUI can size and position it exactly
/// like the still `Image` it replaces during playback — `.frame(...).position(...)`
/// against the very same `FrameGeometry.contentRect` the overlay reads, which
/// is what keeps video and overlay from ever physically disagreeing about
/// where the body is.
///
/// `videoGravity` is `.resize` (stretch to fill), not `.resizeAspect`:
/// `contentRect` is already aspect-correct for the video's own pixel aspect,
/// so a second aspect-fit pass inside the layer would be redundant, not
/// wrong — but redundant unit conversions are exactly where an off-by-a-hair
/// mismatch hides.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resize
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}
