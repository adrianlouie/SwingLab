import CoreGraphics
import Foundation

/// A user-drawn reference mark on the video overlay — a line or circle the
/// golfer places and resizes themselves, for pointing at whatever they want
/// to see (a target line, a reference angle, a circle around something),
/// entirely independent of anything the app measures or detects.
///
/// Points are stored as fractions (0...1) of the video container's own
/// size at the time of drawing — the same "unit square" convention every
/// other overlay element is authored in. Unlike the pose-derived overlays,
/// though, these are deliberately NOT re-projected through
/// `FrameGeometry`'s zoom/pan math: they're anchored to the container as
/// displayed, a conscious simplification given these are a coach's-
/// telestrator-style aid, not a body-relative measurement — a shape drawn
/// while zoomed in will look offset if you then zoom back out. Ephemeral,
/// like `ResultsView`'s `zoom`/`panOffset` — reset when you leave the
/// screen, never saved with the swing.
struct OverlayAnnotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case line
        case circle
    }

    let id: UUID
    var kind: Kind
    /// Line: one endpoint. Circle: center — dragging this moves the whole
    /// circle, the same role a line's separate midpoint handle plays.
    var start: CGPoint
    /// Line: the other endpoint. Circle: a point on the edge — its distance
    /// from `start` is the radius, so dragging this resizes the circle.
    var end: CGPoint

    init(id: UUID = UUID(), kind: Kind, start: CGPoint, end: CGPoint) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// A sensible default line, centered in the frame, immediately visible
    /// and draggable into place.
    static func defaultLine() -> OverlayAnnotation {
        OverlayAnnotation(kind: .line, start: CGPoint(x: 0.3, y: 0.5), end: CGPoint(x: 0.7, y: 0.5))
    }

    /// A sensible default circle, centered in the frame.
    static func defaultCircle() -> OverlayAnnotation {
        OverlayAnnotation(kind: .circle, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.65, y: 0.5))
    }
}
