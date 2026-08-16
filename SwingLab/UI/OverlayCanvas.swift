import SwiftUI

/// Draws the line-and-angle overlays for one pose frame on top of the video
/// frame image: skeleton, spine line, shoulder/hip lines, the shaft-at-address
/// reference line, head-stability circles, and angle labels.
///
/// Labels are the one thing NOT drawn as the geometry is built. Every stroke
/// (skeleton, spine, shoulder/hip lines, shaft line, head circles, drift
/// arrow) is drawn immediately and also recorded into `OverlayObstacles`;
/// labels are collected as `LabelRequest`s and placed only once everything
/// else is down, via `LabelLayout`, then drawn in one final pass on top of
/// all of it. Previously the two labels used fixed offsets with no collision
/// awareness, and the draw order meant a line could paint directly over a
/// label — both are what this fixes.
struct OverlayCanvas: View {
    let frame: PoseFrame
    let addressFrame: PoseFrame?
    let position: SwingPosition
    let viewType: CameraViewType
    let handedness: Handedness
    var space: PoseSpace = .square
    var ballOverride: JointPoint? = nil
    /// Movement beyond this turns the head circle amber. Comes from the user's
    /// own ideal range so the overlay agrees with the score.
    var headDriftLimitInches: Double = 3
    /// Faults to consider for the on-video badge at `position` — empty by
    /// default so every existing call site (which didn't pass this) keeps
    /// drawing exactly what it did before. See `FaultBadgeLayout` for why
    /// at most one badge ever renders.
    var faults: [SwingFault] = []
    var frameRate: Double = 30
    var includeLowerConfidenceFaults: Bool = true
    /// Frames to trace the hands through (typically address...finish) for
    /// the swing-path curve — empty by default, same "existing call sites
    /// see no change" reasoning as `faults` above.
    var pathFrames: [PoseFrame] = []

    /// width / height of the oriented video frame.
    let imageAspect: CGFloat
    /// 1 = fit. Identity by default so every existing call site (which
    /// doesn't zoom) is unaffected; the zoomable frame viewer passes real
    /// values computed from the same `FrameGeometry` its video view uses, so
    /// the two can never disagree about where the body is.
    var zoom: CGFloat = 1
    var panOffset: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            let geometry = FrameGeometry(container: size, aspect: imageAspect, zoom: zoom, offset: panOffset)
            var obstacles = OverlayObstacles()
            var labelRequests: [LabelRequest] = []

            drawSkeleton(context: context, geometry: geometry, obstacles: &obstacles)
            drawHeadComparison(context: context, geometry: geometry,
                              obstacles: &obstacles, labels: &labelRequests)
            drawSpine(context: context, geometry: geometry,
                     obstacles: &obstacles, labels: &labelRequests)
            drawShoulderAndHipLines(context: context, geometry: geometry, obstacles: &obstacles)
            drawSwingPlaneShading(context: context, geometry: geometry, obstacles: &obstacles)
            drawHandPathTrace(context: context, geometry: geometry, obstacles: &obstacles)
            drawAddressShaftLine(context: context, geometry: geometry, obstacles: &obstacles)

            let badges = FaultBadgeLayout.badges(for: position, faults: faults, frameRate: frameRate,
                                                 includeLowerConfidence: includeLowerConfidenceFaults,
                                                 handedness: handedness, frame: frame, geometry: geometry)
            labelRequests.append(contentsOf: FaultBadgeLayout.labelRequests(for: badges))

            drawLabels(labelRequests, context: context, bounds: CGRect(origin: .zero, size: size),
                      obstacles: obstacles, badgeSizes: FaultBadgeLayout.sizes(for: badges))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Skeleton

    private func drawSkeleton(context: GraphicsContext, geometry: FrameGeometry,
                              obstacles: inout OverlayObstacles) {
        var skeleton = Path()
        for (a, b) in Joint.skeletonBones {
            guard let ja = frame[a], let jb = frame[b],
                  ja.confidence > 0.2, jb.confidence > 0.2 else { continue }
            let pa = geometry.point(ja)
            let pb = geometry.point(jb)
            skeleton.move(to: pa)
            skeleton.addLine(to: pb)
            obstacles.addSegment(pa, pb)
        }
        context.stroke(skeleton, with: .color(.white.opacity(0.75)), lineWidth: 2)

        // Joint dots, excluding the face landmarks — those are represented by
        // the head circle instead of five dots crowding the face.
        for joint in Joint.allCases where !Joint.faceJoints.contains(joint) {
            guard let j = frame[joint], j.confidence > 0.2 else { continue }
            let p = geometry.point(j)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                        with: .color(Theme.lime))
        }
    }

    // MARK: - Head: where it started vs where it is now

    /// Two circles rather than one, because the useful thing isn't where the
    /// head is — it's how far it has moved off the setup position.
    private func drawHeadComparison(context: GraphicsContext, geometry: FrameGeometry,
                                    obstacles: inout OverlayObstacles,
                                    labels: inout [LabelRequest]) {
        let current = frame.headCircle(space: space)
        let start = addressFrame?.headCircle(space: space)

        if let start {
            let c = geometry.point(start.center)
            let r = geometry.length(start.radius)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(0.85)),
                          style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            obstacles.addCircle(center: c, radius: r)
        }

        guard let current else { return }
        let now = geometry.point(current.center)
        let radius = geometry.length(current.radius)

        // Drift uses the SAME stable single-joint measurement SwingAnalyzer
        // actually scores (`MetricKind.headDrift` → `SwingGeometry.headJoint`
        // + `horizontalDriftInches`) — deliberately NOT a Euclidean distance
        // between two independently-fitted `headCircle` centers.
        // `headCircle` averages whichever face landmarks (nose/eyes/ears)
        // happen to be confidently tracked *that frame*, and that set keeps
        // changing as the head rotates through a real swing — each time it
        // flips (e.g. gaining a second eye mid-backswing), the fitted center
        // jumps on its own, with nothing to do with real head motion. That
        // produced an on-screen number that climbed almost the entire swing
        // and never reflected the real back-and-forth, confirmed against
        // real footage (`CLAUDE.md` "head drift overlay"). The circles above
        // stay `headCircle`-based — fine for a visual head outline — only
        // the measured drift and its arrow now track one fixed joint.
        var driftInches: Double?
        var trackedFrom: CGPoint?
        if let addressFrame, let headJoint = SwingGeometry.headJoint(in: addressFrame),
           let addrPoint = addressFrame[headJoint], let curPoint = frame[headJoint],
           addrPoint.confidence > 0.2, curPoint.confidence > 0.2 {
            driftInches = SwingGeometry.horizontalDriftInches(joint: headJoint, address: addressFrame,
                                                               current: frame, space: space)
            trackedFrom = geometry.point(addrPoint)
        }

        let moved = (driftInches ?? 0) > headDriftLimitInches
        let color: Color = start == nil ? Theme.lime : (moved ? Theme.amber : Theme.good)

        // Arrow from the tracked joint's address position to where it is
        // now — not the headCircle centers, so the arrow always agrees with
        // the printed distance below.
        if let trackedFrom, let driftInches, driftInches > 0.35 {
            var line = Path()
            line.move(to: trackedFrom)
            line.addLine(to: now)
            context.stroke(line, with: .color(color), lineWidth: 2)
            obstacles.addSegment(trackedFrom, now)

            let angle = atan2(now.y - trackedFrom.y, now.x - trackedFrom.x)
            let head: CGFloat = 8
            var arrow = Path()
            arrow.move(to: now)
            arrow.addLine(to: CGPoint(x: now.x - head * cos(angle - .pi / 7),
                                      y: now.y - head * sin(angle - .pi / 7)))
            arrow.move(to: now)
            arrow.addLine(to: CGPoint(x: now.x - head * cos(angle + .pi / 7),
                                      y: now.y - head * sin(angle + .pi / 7)))
            context.stroke(arrow, with: .color(color), lineWidth: 2)
        }

        context.stroke(Path(ellipseIn: CGRect(x: now.x - radius, y: now.y - radius,
                                              width: radius * 2, height: radius * 2)),
                      with: .color(color), lineWidth: 3)
        obstacles.addCircle(center: now, radius: radius)

        if let driftInches {
            labels.append(LabelRequest(
                id: "headDrift",
                text: driftInches < 0.35 ? "head steady" : String(format: "head %.1f\"", driftInches),
                anchor: now,
                tint: color,
                priority: 1))
        }
    }

    // MARK: - Spine

    private func drawSpine(context: GraphicsContext, geometry: FrameGeometry,
                           obstacles: inout OverlayObstacles, labels: inout [LabelRequest]) {
        guard let neck = frame[.neck], let root = frame[.root],
              neck.confidence > 0.2, root.confidence > 0.2 else { return }

        let neckPoint = geometry.point(neck)
        let rootPoint = geometry.point(root)

        var spine = Path()
        spine.move(to: rootPoint)
        spine.addLine(to: neckPoint)
        context.stroke(spine, with: .color(Theme.lime), lineWidth: 3)
        obstacles.addSegment(rootPoint, neckPoint)

        // Dashed vertical reference through the hips.
        let verticalTop = CGPoint(x: rootPoint.x, y: neckPoint.y - 20)
        var vertical = Path()
        vertical.move(to: rootPoint)
        vertical.addLine(to: verticalTop)
        context.stroke(vertical, with: .color(.white.opacity(0.5)),
                      style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        obstacles.addSegment(rootPoint, verticalTop)

        if let tilt = SwingGeometry.spineTilt(frame: frame, space: space) {
            labels.append(LabelRequest(
                id: "spineTilt",
                text: String(format: "%.0f°", tilt),
                anchor: neckPoint,
                tint: Theme.lime,
                priority: 0))
        }
    }

    // MARK: - Shoulder / hip lines

    private func drawShoulderAndHipLines(context: GraphicsContext, geometry: FrameGeometry,
                                         obstacles: inout OverlayObstacles) {
        if let l = frame[.leftShoulder], let r = frame[.rightShoulder],
           l.confidence > 0.2, r.confidence > 0.2 {
            let pl = geometry.point(l)
            let pr = geometry.point(r)
            var line = Path()
            line.move(to: pl)
            line.addLine(to: pr)
            context.stroke(line, with: .color(.cyan), lineWidth: 2.5)
            obstacles.addSegment(pl, pr)
        }
        if let l = frame[.leftHip], let r = frame[.rightHip],
           l.confidence > 0.2, r.confidence > 0.2 {
            let pl = geometry.point(l)
            let pr = geometry.point(r)
            var line = Path()
            line.move(to: pl)
            line.addLine(to: pr)
            context.stroke(line, with: .color(.orange), lineWidth: 2.5)
            obstacles.addSegment(pl, pr)
        }
    }

    // MARK: - Swing plane shading (down-the-line only, decorative — the
    // math is still `SwingGeometry.planeLine`, the same primitive
    // `overTheTop` depends on; this only adds a rendering-only shape on
    // top, never touches the fault-detection math itself)

    /// A translucent band along the ball→shoulder plane line, extended a
    /// little past each end so it reads as a plane a club could travel
    /// along, not just a segment tightly bound to the two joints that
    /// defined it. Purely visual — screen-space geometry lives here, not in
    /// `SwingGeometry`, matching how every other shape this view draws
    /// (the head-drift arrow, the spine's dashed reference) is computed
    /// directly in screen space rather than normalized pose space.
    private func drawSwingPlaneShading(context: GraphicsContext, geometry: FrameGeometry,
                                       obstacles: inout OverlayObstacles) {
        guard viewType == .downTheLine, let address = addressFrame,
              let plane = SwingGeometry.planeLine(address: address, handedness: handedness,
                                                  space: space, ballOverride: ballOverride) else { return }

        let ball = geometry.point(plane.ball)
        let shoulder = geometry.point(plane.shoulder)
        let dx = shoulder.x - ball.x, dy = shoulder.y - ball.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux // perpendicular, screen space

        let extend = length * 0.18
        let halfWidth: CGFloat = 16
        let p0 = CGPoint(x: ball.x - ux * extend * 0.3, y: ball.y - uy * extend * 0.3)
        let p1 = CGPoint(x: shoulder.x + ux * extend, y: shoulder.y + uy * extend)

        var shape = Path()
        shape.move(to: CGPoint(x: p0.x + px * halfWidth, y: p0.y + py * halfWidth))
        shape.addLine(to: CGPoint(x: p1.x + px * halfWidth, y: p1.y + py * halfWidth))
        shape.addLine(to: CGPoint(x: p1.x - px * halfWidth, y: p1.y - py * halfWidth))
        shape.addLine(to: CGPoint(x: p0.x - px * halfWidth, y: p0.y - py * halfWidth))
        shape.closeSubpath()

        context.fill(shape, with: .color(.blue.opacity(0.20)))
        context.stroke(shape, with: .color(.blue.opacity(0.55)), lineWidth: 1)
        obstacles.addSegment(p0, p1)
    }

    // MARK: - Swing path trace (down-the-line only, decorative)

    /// A smoothed curve tracing the hands from address through finish —
    /// see `HandPathTrace` for why it's a pure function over already-
    /// extracted frames rather than a new measurement.
    private func drawHandPathTrace(context: GraphicsContext, geometry: FrameGeometry,
                                   obstacles: inout OverlayObstacles) {
        guard viewType == .downTheLine, pathFrames.count > 2 else { return }
        let points = HandPathTrace.points(frames: pathFrames, geometry: geometry)
        guard points.count > 2 else { return }

        let path = Path(HandPathTrace.smoothedPath(through: points))
        context.stroke(path, with: .color(.yellow.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6]))

        // A coarse subset as obstacles — exact curve geometry isn't worth
        // the cost, this only needs to keep labels from landing right on
        // top of an obviously-visible line.
        let stride = max(1, points.count / 12)
        for i in Swift.stride(from: 0, to: points.count - 1, by: stride) {
            obstacles.addSegment(points[i], points[min(points.count - 1, i + 1)])
        }
    }

    // MARK: - Shaft at address (down-the-line, a fixed reference for the whole video)

    /// The club shaft's line at address — ball up through the hands — drawn
    /// from `addressFrame` on every single frame of playback, never
    /// re-derived from whichever position is currently on screen. That's
    /// the whole point: a fixed line to check the swing against, in the
    /// same screen position start to finish, not something that could
    /// subtly drift per position the way computing it fresh each time might
    /// invite.
    private func drawAddressShaftLine(context: GraphicsContext, geometry: FrameGeometry,
                                      obstacles: inout OverlayObstacles) {
        guard viewType == .downTheLine, let address = addressFrame,
              let plane = SwingGeometry.planeLine(address: address, handedness: handedness,
                                                  space: space, ballOverride: ballOverride),
              let hands = address.handsCenter, hands.confidence > 0.2 else { return }

        let ball = geometry.point(plane.ball)
        let handsPoint = geometry.point(hands)
        guard ball != handsPoint else { return }

        var line = Path()
        line.move(to: ball)
        line.addLine(to: handsPoint)
        context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: ball.x - 4, y: ball.y - 4, width: 8, height: 8)),
                    with: .color(.white))
        obstacles.addSegment(ball, handsPoint)
    }

    // MARK: - Labels — always last, always on top

    private func drawLabels(_ requests: [LabelRequest], context: GraphicsContext,
                            bounds: CGRect, obstacles: OverlayObstacles,
                            badgeSizes: [String: CGSize] = [:]) {
        guard !requests.isEmpty else { return }

        var sizes: [String: CGSize] = badgeSizes
        var resolved: [String: GraphicsContext.ResolvedText] = [:]
        for request in requests {
            let font: Font = request.isFaultBadge ? .caption.bold() : .caption.bold().monospacedDigit()
            let text = context.resolve(
                Text(request.text).font(font).foregroundStyle(request.isFaultBadge ? .white : request.tint))
            resolved[request.id] = text
            // Badge sizes are pre-supplied (a crude estimate shared with
            // `FaultBadgeOverlay`'s tap target, which can't measure text via
            // a `GraphicsContext` at all) — only measure the rest here.
            if sizes[request.id] == nil {
                sizes[request.id] = text.measure(in: CGSize(width: 120, height: 40))
            }
        }

        let placed = LabelLayout.place(requests, sizes: sizes, obstacles: obstacles, bounds: bounds)

        for label in placed {
            if let (from, to) = label.leader {
                var leader = Path()
                leader.move(to: from)
                leader.addLine(to: to)
                context.stroke(leader, with: .color(label.request.tint.opacity(0.6)), lineWidth: 1)
            }

            let padded = label.rect.insetBy(dx: -4, dy: -3)
            let background: Color = label.request.isFaultBadge
                ? label.request.tint.opacity(0.92)
                : .black.opacity(0.55)
            context.fill(Path(roundedRect: padded, cornerRadius: label.request.isFaultBadge ? 8 : 5),
                        with: .color(background))
            if label.request.isFaultBadge {
                context.stroke(Path(roundedRect: padded, cornerRadius: 8), with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
            if let text = resolved[label.request.id] {
                context.draw(text, in: label.rect)
            }
        }
    }
}
