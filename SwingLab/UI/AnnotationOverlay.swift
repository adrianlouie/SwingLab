import SwiftUI

/// Freeform user-drawn reference marks — lines and circles the golfer adds,
/// drags, and resizes themselves, entirely separate from anything the app
/// measures. Rendered as real SwiftUI shapes with real drag gestures, not
/// inside `OverlayCanvas`'s `Canvas` (which has `.allowsHitTesting(false)`
/// and can't host gestures at all) — same "thin sibling view" pattern as
/// `FaultBadgeOverlay`.
///
/// A named coordinate space (`coordinateSpaceName`) is what makes dragging a
/// small handle deep in the view tree report *container-relative* drag
/// locations rather than locations relative to the tiny handle itself —
/// without it, `value.location` inside each handle's own gesture would be
/// relative to that ~22pt circle, useless for placing anything.
struct AnnotationOverlay: View {
    @Binding var annotations: [OverlayAnnotation]
    let size: CGSize

    static let coordinateSpaceName = "annotationOverlay"

    var body: some View {
        ZStack {
            ForEach($annotations) { $annotation in
                AnnotationShapeView(annotation: $annotation, size: size) {
                    annotations.removeAll { $0.id == annotation.id }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.coordinateSpaceName)
    }
}

/// One line or circle, plus its own drag handles.
///
/// A dedicated child view (not a computed property inside `AnnotationOverlay`)
/// because whole-shape dragging needs its own per-gesture `@State` snapshot
/// of where the shape started, to compute a stable delta as the drag
/// continues — that only works with real per-instance state, which a
/// `ForEach` row view gets for free and a shared helper function wouldn't.
private struct AnnotationShapeView: View {
    @Binding var annotation: OverlayAnnotation
    let size: CGSize
    let onDelete: () -> Void

    /// Snapshot of `annotation` taken at the start of a whole-shape drag —
    /// `nil` whenever no such drag is in progress. Needed because
    /// `DragGesture.translation` is cumulative from gesture start, but
    /// `annotation` itself keeps changing on every `onChanged` call, so
    /// naively adding `translation` to the *current* value would run away.
    @State private var dragOrigin: OverlayAnnotation?

    private let handleDiameter: CGFloat = 24
    private let color = Color.orange

    private var start: CGPoint { screenPoint(annotation.start) }
    private var end: CGPoint { screenPoint(annotation.end) }
    private var midpoint: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }

    private func screenPoint(_ fraction: CGPoint) -> CGPoint {
        CGPoint(x: fraction.x * size.width, y: fraction.y * size.height)
    }

    private func fraction(of screen: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, screen.x / max(size.width, 1))),
               y: min(1, max(0, screen.y / max(size.height, 1))))
    }

    var body: some View {
        ZStack {
            switch annotation.kind {
            case .line:
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                moveHandle(at: midpoint, systemImage: "arrow.up.and.down.and.arrow.left.and.right")

            case .circle:
                let radius = max(hypot(end.x - start.x, end.y - start.y), 1)
                Circle()
                    .stroke(color, style: StrokeStyle(lineWidth: 3))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(start)
                moveHandle(at: start, systemImage: "move.3d")
            }

            endpointHandle(at: end, dragsStart: false)
            deleteButton
        }
    }

    // MARK: - Handles

    private func moveHandle(at point: CGPoint, systemImage: String) -> some View {
        Circle()
            .fill(color.opacity(0.9))
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: handleDiameter, height: handleDiameter)
            .position(point)
            .gesture(moveDrag)
            .accessibilityIdentifier("annotationMove.\(annotation.id)")
    }

    private func endpointHandle(at point: CGPoint, dragsStart: Bool) -> some View {
        Circle()
            .fill(.white)
            .overlay { Circle().stroke(color, lineWidth: 2) }
            .frame(width: handleDiameter, height: handleDiameter)
            .position(point)
            .gesture(endpointDrag(dragsStart: dragsStart))
            .accessibilityIdentifier(dragsStart ? "annotationStart.\(annotation.id)" : "annotationEnd.\(annotation.id)")
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .background(Circle().fill(.white).frame(width: 14, height: 14))
        }
        .position(x: start.x + 18, y: start.y - 18)
        .accessibilityIdentifier("annotationDelete.\(annotation.id)")
    }

    // MARK: - Gestures

    /// Endpoint drag: the handle follows the finger directly — an absolute
    /// location in the named coordinate space, not a translation delta —
    /// which is what makes it read as "grab this end and put it wherever."
    /// Doubles as the circle's resize handle: dragging `end` changes the
    /// distance from `start` (the center), which is the radius.
    private func endpointDrag(dragsStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(AnnotationOverlay.coordinateSpaceName))
            .onChanged { value in
                let f = fraction(of: value.location)
                if dragsStart {
                    annotation.start = f
                } else {
                    annotation.end = f
                }
            }
    }

    /// Whole-shape move: translates both `start` and `end` by the same
    /// delta, so length/size/angle stay exactly what they were — this is
    /// the "drag and drop it wherever" gesture, as opposed to the endpoint
    /// handles, which are "change its length and size."
    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(AnnotationOverlay.coordinateSpaceName))
            .onChanged { value in
                let origin = dragOrigin ?? annotation
                if dragOrigin == nil { dragOrigin = origin }
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                annotation.start = clamped(CGPoint(x: origin.start.x + dx, y: origin.start.y + dy))
                annotation.end = clamped(CGPoint(x: origin.end.x + dx, y: origin.end.y + dy))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
    }
}

/// "+ Line" / "+ Circle" / "Clear" controls for adding and clearing
/// annotations — separate from `AnnotationOverlay` itself since it isn't
/// part of the video overlay stack, just a row of buttons `ResultsView`
/// places near it.
struct AnnotationToolbar: View {
    @Binding var annotations: [OverlayAnnotation]

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.impact()
                annotations.append(.defaultLine())
            } label: {
                Label("Line", systemImage: "line.diagonal")
            }
            .accessibilityIdentifier("addLineAnnotation")

            Button {
                Haptics.impact()
                annotations.append(.defaultCircle())
            } label: {
                Label("Circle", systemImage: "circle")
            }
            .accessibilityIdentifier("addCircleAnnotation")

            Spacer()

            if !annotations.isEmpty {
                Button(role: .destructive) {
                    annotations.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .accessibilityIdentifier("clearAnnotations")
            }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
