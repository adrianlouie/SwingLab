import SwiftUI

/// The single source of truth for where the video frame sits inside its
/// container, at any zoom and pan offset.
///
/// Before this, the overlay computed its own aspect-fit rect and the video
/// view was a plain `.resizable().scaledToFit()` Image — two independent
/// layouts that happened to agree at zoom 1. Adding zoom (task: pinch/pan)
/// would have meant scaling one or the other and hoping they matched. Instead
/// both the video and `OverlayCanvas` read the same `FrameGeometry` value, so
/// the lines physically cannot drift off the body: there is only one place
/// that computes "where is the video," and everything else asks it.
struct FrameGeometry: Equatable {
    /// The space this geometry is being laid out into.
    var container: CGSize
    /// width / height of the oriented video frame.
    var aspect: CGFloat
    /// 1 = fit, higher = zoomed in.
    var zoom: CGFloat
    /// Pan offset in points, applied after scaling, already clamped by the
    /// caller (see `clampedOffset`).
    var offset: CGSize

    init(container: CGSize, aspect: CGFloat, zoom: CGFloat = 1, offset: CGSize = .zero) {
        self.container = container
        self.aspect = aspect > 0 ? aspect : 1
        self.zoom = max(zoom, 0.0001)
        self.offset = offset
    }

    /// The aspect-fit rect at zoom 1, centred in the container. This is what
    /// the old `OverlayCanvas.fittedRect` computed.
    var baseRect: CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            let height = container.width / aspect
            return CGRect(x: 0, y: (container.height - height) / 2,
                          width: container.width, height: height)
        } else {
            let width = container.height * aspect
            return CGRect(x: (container.width - width) / 2, y: 0,
                          width: width, height: container.height)
        }
    }

    /// Where the video should actually be drawn: `baseRect` scaled about the
    /// container's centre by `zoom`, then shifted by `offset`. The video view
    /// is sized and positioned to exactly this rect (not `.scaleEffect`, which
    /// would rasterize it at 1x first and blur it under magnification).
    var contentRect: CGRect {
        let base = baseRect
        let width = base.width * zoom
        let height = base.height * zoom
        let cx = container.width / 2 + offset.width
        let cy = container.height / 2 + offset.height
        return CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }

    /// Maps a normalized pose point (bottom-left origin, as Vision reports)
    /// into this container's coordinate space (top-left origin, as SwiftUI
    /// draws).
    func point(_ p: JointPoint) -> CGPoint {
        let rect = contentRect
        return CGPoint(x: rect.minX + p.x * rect.width,
                       y: rect.minY + (1 - p.y) * rect.height)
    }

    /// A length expressed as a fraction of the video's height (e.g. a head
    /// radius), scaled the same way the content is. Labels must NOT use this —
    /// they stay a fixed point size regardless of zoom.
    func length(_ heightFraction: Double) -> CGFloat {
        CGFloat(heightFraction) * contentRect.height
    }

    /// Clamps a proposed pan offset so the content rect always covers the
    /// container — the body can never be panned into empty space. Returns
    /// `.zero` at or below 1x, where there's nothing to pan.
    static func clampedOffset(_ raw: CGSize, zoom: CGFloat, baseRect: CGRect, container: CGSize) -> CGSize {
        guard zoom > 1.001 else { return .zero }
        let width = baseRect.width * zoom
        let height = baseRect.height * zoom
        let maxX = max(0, (width - container.width) / 2)
        let maxY = max(0, (height - container.height) / 2)
        return CGSize(width: min(max(raw.width, -maxX), maxX),
                      height: min(max(raw.height, -maxY), maxY))
    }
}
