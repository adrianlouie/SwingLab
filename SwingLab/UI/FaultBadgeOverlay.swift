import SwiftUI

/// Invisible tap target sitting over wherever `OverlayCanvas` drew its fault
/// badge. `OverlayCanvas` draws on a `Canvas` with `.allowsHitTesting(false)`
/// (pure drawing, no interaction) — rather than making the whole canvas
/// hit-testable, this is a thin sibling `View` that recomputes the same
/// badge (via `FaultBadgeLayout`, the one shared source of truth for "which
/// fault, what text, where") and renders a real SwiftUI `Button` there.
///
/// Placement here is intentionally simpler than `OverlayCanvas`'s: it places
/// the single badge (there's never more than one, by design — see
/// `FaultBadgeLayout`) against an empty obstacle set rather than rebuilding
/// the full skeleton/label obstacle picture, since with only one badge and
/// no other labels to avoid *within this view's own computation*, that
/// full rebuild would duplicate a good deal of `OverlayCanvas`'s drawing
/// code for a case that has nothing to collide with here. The one edge case
/// this accepts: if the real render nudged the badge to avoid a nearby
/// metric label or a skeleton line, this tap target can be very slightly
/// offset from the visible badge. Worth revisiting only if that turns out
/// to be a real annoyance in practice, not something to engineer away blind.
struct FaultBadgeOverlay: View {
    let frame: PoseFrame
    let position: SwingPosition
    let handedness: Handedness
    let faults: [SwingFault]
    let frameRate: Double
    let includeLowerConfidenceFaults: Bool
    let geometry: FrameGeometry
    let size: CGSize
    let onTap: (SwingFault) -> Void

    private var badge: FaultBadgeLayout.Badge? {
        FaultBadgeLayout.badges(for: position, faults: faults, frameRate: frameRate,
                                includeLowerConfidence: includeLowerConfidenceFaults,
                                handedness: handedness, frame: frame, geometry: geometry).first
    }

    var body: some View {
        if let badge {
            let placed = LabelLayout.place(FaultBadgeLayout.labelRequests(for: [badge]),
                                           sizes: FaultBadgeLayout.sizes(for: [badge]),
                                           obstacles: OverlayObstacles(),
                                           bounds: CGRect(origin: .zero, size: size))
            if let rect = placed.first?.rect {
                Button {
                    Haptics.impact()
                    onTap(badge.fault)
                } label: {
                    Color.clear
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .accessibilityIdentifier("faultBadge.\(badge.fault.kind.rawValue)")
                .accessibilityLabel(badge.text)
            }
        }
    }
}
