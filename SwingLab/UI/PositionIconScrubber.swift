import SwiftUI

/// A small stick-figure silhouette suggesting where the hands/club are for
/// one swing phase. Deliberately a simplified approximation — one consistent
/// body (head, torso, legs) with a position-specific hand point — not
/// anatomically precise per position the way real illustration work would
/// be. Good enough to make 8 small scrubber icons visually distinguishable
/// at a glance; revisit with real artwork if that turns out not to be
/// enough. Placement is hard-coded relative offsets rather than an angle
/// computed from a formula, so each position's silhouette can be reasoned
/// about (and adjusted) independently without back-deriving trigonometry.
struct PositionStickFigure: Shape {
    let position: SwingPosition

    /// Hands position relative to the shoulder, as a fraction of the
    /// icon's own height. Negative dy is up, negative dx is toward the
    /// back of the swing (arbitrary — this is a generic icon, not tied to
    /// the clip's actual handedness or camera view).
    private var handOffset: (dx: CGFloat, dy: CGFloat) {
        switch position {
        case .address: return (0.05, 0.55)
        case .takeaway: return (-0.35, 0.45)
        case .halfwayBack: return (-0.55, 0.15)
        case .top: return (-0.45, -0.35)
        case .transition: return (-0.35, -0.15)
        case .delivery: return (0.15, 0.25)
        case .impact: return (0.10, 0.55)
        case .finish: return (0.50, -0.45)
        }
    }

    /// A slight forward lean for the ball-striking positions, upright at
    /// the top of the swing and the finish.
    private var leansForward: Bool {
        position == .address || position == .impact || position == .delivery
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let headRadius = rect.height * 0.13
        let midX = rect.midX + (leansForward ? rect.width * 0.04 : 0)
        let headCenter = CGPoint(x: midX, y: rect.minY + headRadius)
        path.addEllipse(in: CGRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                                   width: headRadius * 2, height: headRadius * 2))

        let shoulder = CGPoint(x: midX, y: headCenter.y + headRadius * 1.0)
        let hip = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.24)

        path.move(to: shoulder)
        path.addLine(to: hip)

        let footSpread = rect.width * 0.15
        path.move(to: hip)
        path.addLine(to: CGPoint(x: hip.x - footSpread, y: rect.maxY))
        path.move(to: hip)
        path.addLine(to: CGPoint(x: hip.x + footSpread, y: rect.maxY))

        let offset = handOffset
        let hands = CGPoint(x: shoulder.x + rect.width * offset.dx,
                            y: shoulder.y + rect.height * offset.dy)
        path.move(to: shoulder)
        path.addLine(to: hands)

        return path
    }
}

/// A single horizontal scrubber of position icons, replacing the two
/// separate controls `ResultsView` used to have (`jumpToBar`'s 5-primary
/// SF-Symbol buttons and `positionPicker`'s all-8 text capsules) — one
/// control, all detected positions, matching the reference app's single
/// icon row rather than two overlapping ones.
struct PositionIconScrubber: View {
    let positions: [SwingPosition]
    @Binding var selected: SwingPosition

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(positions) { position in
                    Button {
                        Haptics.impact()
                        withAnimation(.easeOut(duration: 0.15)) { selected = position }
                    } label: {
                        VStack(spacing: 3) {
                            PositionStickFigure(position: position)
                                .stroke(selected == position ? .white : Color.primary,
                                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .frame(width: 22, height: 28)
                            Text(position.shortLabel)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(minWidth: 54)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .background(selected == position ? Theme.fairway : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(selected == position ? .white : .primary)
                    }
                    .accessibilityIdentifier("positionScrubber.\(position.rawValue)")
                }
            }
            .padding(.vertical, 2)
        }
    }
}
