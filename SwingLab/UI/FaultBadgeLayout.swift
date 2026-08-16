import SwiftUI

/// Computes which fault, if any, gets an on-video badge for the position
/// currently on screen, and where. Shared by `OverlayCanvas` (which draws
/// it, fully obstacle-aware, alongside the existing angle/distance labels)
/// and `FaultBadgeOverlay` (which needs the same rect to place an invisible
/// tap target) — one function, not two independent computations that could
/// drift apart the way `PoseKinematics` was pulled out to prevent earlier.
///
/// Capped to the single firmest fault at a position on purpose: several
/// faults anchored close together (e.g. `earlyExtension`/`bodyDrop`/
/// `bodyRise` all near the neck at impact) would otherwise get pushed
/// apart by collision avoidance into a scattered, hard-to-read cluster.
/// The rest stay reachable through the existing fault list below the video.
enum FaultBadgeLayout {
    struct Badge: Identifiable {
        var fault: SwingFault
        var text: String
        var anchor: CGPoint
        var id: String { fault.id }
    }

    /// Crude but serviceable: real `GraphicsContext` text measurement isn't
    /// available outside a `Canvas` draw pass, and `FaultBadgeOverlay` (a
    /// plain SwiftUI view) needs the identical size `OverlayCanvas` uses for
    /// its tap target to line up. Fault titles are short and fairly
    /// consistent in length, so a character-count estimate is close enough
    /// — worth swapping for real measurement only if real usage shows badges
    /// visibly mis-sized.
    static func estimatedSize(for text: String) -> CGSize {
        CGSize(width: min(240, max(70, CGFloat(text.count) * 6.8 + 28)), height: 34)
    }

    static func severityColor(_ severity: FaultSeverity) -> Color {
        switch severity {
        case .slight, .clear: return Theme.amber
        case .severe: return .red
        }
    }

    /// The one fault (if any) to badge at `position`, already filtered
    /// through the same `FaultDisplay.isVisible` gate every other fault
    /// list on screen respects — a low-confidence read must never appear
    /// as a badge any more than it appears in the list.
    static func badges(for position: SwingPosition,
                       faults: [SwingFault],
                       frameRate: Double,
                       includeLowerConfidence: Bool,
                       handedness: Handedness,
                       frame: PoseFrame,
                       geometry: FrameGeometry) -> [Badge] {
        let atPosition = faults
            .filter { $0.position == position }
            .filter { FaultDisplay.isVisible($0, frameRate: frameRate, includeLowerConfidence: includeLowerConfidence) }

        guard let worst = atPosition.max(by: { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            return a.confidence < b.confidence
        }) else { return [] }

        guard let anchor = screenAnchor(for: worst.kind, handedness: handedness,
                                        frame: frame, geometry: geometry) else { return [] }

        let text = worst.position.map { "\(worst.kind.title) at \($0.shortLabel)" } ?? worst.kind.title
        return [Badge(fault: worst, text: text, anchor: anchor)]
    }

    private static func screenAnchor(for kind: SwingFaultKind, handedness: Handedness,
                                     frame: PoseFrame, geometry: FrameGeometry) -> CGPoint? {
        switch kind.anchor(handedness: handedness) {
        case .handsCenter:
            guard let hands = frame.handsCenter, hands.confidence > 0.2 else { return nil }
            return geometry.point(hands)
        case .joint(let joint):
            guard let jp = frame[joint], jp.confidence > 0.2 else { return nil }
            return geometry.point(jp)
        case nil:
            return nil
        }
    }

    /// `LabelRequest`s ready to merge into the same `LabelLayout.place` call
    /// as the existing angle/distance labels, so a badge and a metric label
    /// mutually avoid each other rather than each pretending the other
    /// doesn't exist. Priority -1 (lower than the existing 0/1) so a badge
    /// — arguably more urgent than a numeric readout — gets first pick of
    /// the clean slots.
    static func labelRequests(for badges: [Badge]) -> [LabelRequest] {
        badges.map { badge in
            LabelRequest(id: badge.id, text: badge.text, anchor: badge.anchor,
                        tint: severityColor(badge.fault.severity), priority: -1, isFaultBadge: true)
        }
    }

    static func sizes(for badges: [Badge]) -> [String: CGSize] {
        Dictionary(uniqueKeysWithValues: badges.map { ($0.id, estimatedSize(for: $0.text)) })
    }
}
