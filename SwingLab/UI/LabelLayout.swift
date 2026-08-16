import CoreGraphics
import SwiftUI

/// Every line and circle already drawn on the frame, so a label can be
/// placed somewhere that doesn't sit on top of one. Segments cover bones,
/// the spine, shoulder/hip lines, the plane line and the head-drift arrow;
/// circles cover the two head positions.
struct OverlayObstacles {
    private(set) var segments: [(CGPoint, CGPoint)] = []
    private(set) var circles: [(center: CGPoint, radius: CGFloat)] = []

    mutating func addSegment(_ a: CGPoint, _ b: CGPoint) {
        segments.append((a, b))
    }

    mutating func addCircle(center: CGPoint, radius: CGFloat) {
        circles.append((center, radius))
    }

    func intersects(_ rect: CGRect) -> Bool {
        segments.contains { LabelLayout.segmentIntersectsRect($0.0, $0.1, rect) }
            || circles.contains { LabelLayout.circleIntersectsRect($0.center, $0.radius, rect) }
    }

    /// A continuous badness score for the least-bad fallback, when nothing is
    /// fully clean: one point per segment crossed, plus how far a circle
    /// pokes into the rect.
    func overlapPenalty(_ rect: CGRect) -> CGFloat {
        var penalty: CGFloat = 0
        for (a, b) in segments where LabelLayout.segmentIntersectsRect(a, b, rect) {
            penalty += 1
        }
        for (center, radius) in circles {
            let d = LabelLayout.distance(from: center, toClosestPointOn: rect)
            if d < radius { penalty += (radius - d) / max(radius, 1) }
        }
        return penalty
    }
}

/// One label that wants to be drawn near `anchor`.
struct LabelRequest: Identifiable {
    var id: String
    var text: String
    var anchor: CGPoint
    var tint: Color
    /// Lower places first, so higher-priority labels get first pick of the
    /// clean slots and never get pushed aside by a later, less important one.
    var priority: Int
    /// A fault badge renders with a filled, colored backing (its severity
    /// color) instead of the plain dark pill every angle/distance label
    /// uses — the same distinction the reference screenshots draw between
    /// a metric readout and a "something's wrong here" callout. Purely a
    /// rendering hint; `LabelLayout.place`'s placement logic doesn't care.
    var isFaultBadge: Bool = false
}

/// Where a label actually ended up, and the leader line to draw if it had to
/// move far from its anchor.
struct PlacedLabel: Identifiable {
    var request: LabelRequest
    var rect: CGRect
    var leader: (CGPoint, CGPoint)?
    var id: String { request.id }
}

/// Deterministic label placement: no physics, no iteration to convergence —
/// just "try the nearest clean slot, in a fixed order, and fall back to the
/// least-bad one." Same input always produces the same output.
enum LabelLayout {

    /// Right, then alternating around the clock, so the first thing tried is
    /// usually the most natural-looking placement.
    private static let directions: [CGVector] = [
        CGVector(dx: 1, dy: 0), CGVector(dx: 0.707, dy: -0.707),
        CGVector(dx: 0, dy: -1), CGVector(dx: -0.707, dy: -0.707),
        CGVector(dx: -1, dy: 0), CGVector(dx: -0.707, dy: 0.707),
        CGVector(dx: 0, dy: 1), CGVector(dx: 0.707, dy: 0.707),
    ]
    /// Radius is the OUTER loop, direction the inner one, so every direction
    /// at the nearest radius is tried before any direction at the next —
    /// nearby placements always win over far ones.
    private static let radii: [CGFloat] = [14, 30, 52, 80]

    static func place(_ requests: [LabelRequest],
                      sizes: [String: CGSize],
                      obstacles: OverlayObstacles,
                      bounds: CGRect) -> [PlacedLabel] {
        var placed: [PlacedLabel] = []
        var liveObstacles = obstacles

        for request in requests.sorted(by: { $0.priority < $1.priority }) {
            // The anchor itself is off the visible area (panned out of frame
            // while zoomed, most likely) — nothing sensible to draw.
            guard bounds.contains(request.anchor), let size = sizes[request.id], size.width > 0 else { continue }

            let candidates = candidateRects(anchor: request.anchor, size: size, bounds: bounds)

            var chosen: CGRect?
            for rect in candidates {
                if !liveObstacles.intersects(rect) && !placed.contains(where: { $0.rect.intersects(rect) }) {
                    chosen = rect
                    break
                }
            }

            let rect = chosen ?? candidates.min(by: { a, b in
                let pa = liveObstacles.overlapPenalty(a) + placedOverlapPenalty(a, placed)
                let pb = liveObstacles.overlapPenalty(b) + placedOverlapPenalty(b, placed)
                return pa < pb
            }) ?? clamp(CGRect(x: request.anchor.x - size.width / 2, y: request.anchor.y - size.height / 2,
                               width: size.width, height: size.height), in: bounds)

            let distance = hypot(rect.midX - request.anchor.x, rect.midY - request.anchor.y)
            let leader: (CGPoint, CGPoint)?
            if distance > 26 {
                let edge = nearestPoint(on: rect, from: request.anchor)
                leader = (request.anchor, edge)
                liveObstacles.addSegment(request.anchor, edge)
            } else {
                leader = nil
            }

            placed.append(PlacedLabel(request: request, rect: rect, leader: leader))
        }

        return placed
    }

    private static func candidateRects(anchor: CGPoint, size: CGSize, bounds: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        out.reserveCapacity(radii.count * directions.count)
        for radius in radii {
            for direction in directions {
                let center = CGPoint(x: anchor.x + direction.dx * radius,
                                     y: anchor.y + direction.dy * radius)
                let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                  width: size.width, height: size.height)
                out.append(clamp(rect, in: bounds))
            }
        }
        return out
    }

    private static func placedOverlapPenalty(_ rect: CGRect, _ placed: [PlacedLabel]) -> CGFloat {
        placed.reduce(0) { $0 + ($1.rect.intersects(rect) ? 1 : 0) }
    }

    /// Keeps a rect fully inside `bounds` — a label must never render partway
    /// off the visible frame.
    private static func clamp(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width >= rect.width, bounds.height >= rect.height else {
            // The container is smaller than the label; centre it and accept
            // the overflow rather than producing a negative-size rect.
            return rect
        }
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private static func nearestPoint(on rect: CGRect, from point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
               y: min(max(point.y, rect.minY), rect.maxY))
    }

    // MARK: - Geometry primitives

    static func distance(from point: CGPoint, toClosestPointOn rect: CGRect) -> CGFloat {
        let closest = nearestPoint(on: rect, from: point)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    static func circleIntersectsRect(_ center: CGPoint, _ radius: CGFloat, _ rect: CGRect) -> Bool {
        distance(from: center, toClosestPointOn: rect) < radius
    }

    static func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        let tl = CGPoint(x: rect.minX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.minY)
        let bl = CGPoint(x: rect.minX, y: rect.maxY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY)
        return segmentsIntersect(a, b, tl, tr) || segmentsIntersect(a, b, tr, br)
            || segmentsIntersect(a, b, br, bl) || segmentsIntersect(a, b, bl, tl)
    }

    /// Standard orientation-based segment intersection test, including the
    /// collinear/touching cases.
    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Int {
            let value = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if abs(value) < 1e-9 { return 0 }
            return value > 0 ? 1 : 2
        }
        func onSegment(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            min(a.x, c.x) <= b.x && b.x <= max(a.x, c.x) && min(a.y, c.y) <= b.y && b.y <= max(a.y, c.y)
        }
        let o1 = orientation(p1, p2, p3)
        let o2 = orientation(p1, p2, p4)
        let o3 = orientation(p3, p4, p1)
        let o4 = orientation(p3, p4, p2)

        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(p1, p3, p2) { return true }
        if o2 == 0 && onSegment(p1, p4, p2) { return true }
        if o3 == 0 && onSegment(p3, p1, p4) { return true }
        if o4 == 0 && onSegment(p3, p2, p4) { return true }
        return false
    }
}
