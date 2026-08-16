import CoreGraphics

/// A smoothed screen-space curve tracing the hands (the club proxy the rest
/// of the app already uses) across a swing, for the on-video path
/// visualization. Pure rendering over already-extracted pose data — no new
/// measurement, no `SwingAnalyzer`/`FaultDetector` involvement, just a
/// friendlier-looking path through points the app already has.
enum HandPathTrace {
    /// One point per frame with a confidently-tracked hands position,
    /// projected to screen space via `geometry`. Frames without confident
    /// tracking are skipped outright, not interpolated — this is
    /// decorative, not a measurement `SwingSignal`-style gap-filling would
    /// be appropriate for; a gap in the drawn curve is more honest than
    /// inventing a position Vision never reported.
    static func points(frames: [PoseFrame], geometry: FrameGeometry, minConfidence: Double = 0.25) -> [CGPoint] {
        frames.compactMap { frame in
            guard let hands = frame.handsCenter, hands.confidence > minConfidence else { return nil }
            return geometry.point(hands)
        }
    }

    /// Catmull-Rom smoothed path through `points` — reads as a smooth swing
    /// arc rather than a jagged frame-to-frame polyline, without inventing
    /// any position: the curve still passes through every real sample.
    static func smoothedPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return path
        }
        for i in 0..<points.count - 1 {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
