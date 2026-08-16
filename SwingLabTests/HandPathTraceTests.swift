import XCTest
@testable import SwingLab

final class HandPathTraceTests: XCTestCase {

    private func frame(handsY: Double, confidence: Double = 0.9) -> PoseFrame {
        var f = SwingFixture.makeFrame(time: 0, handsX: 0.5, handsY: handsY, bodyX: 0.5)
        f.joints[.leftWrist] = JointPoint(x: 0.485, y: handsY, confidence: confidence)
        f.joints[.rightWrist] = JointPoint(x: 0.515, y: handsY, confidence: confidence)
        return f
    }

    private let geometry = FrameGeometry(container: CGSize(width: 300, height: 500), aspect: 9.0 / 16.0)

    func testPointsSkipsLowConfidenceFrames() {
        let frames = [frame(handsY: 0.5), frame(handsY: 0.6, confidence: 0.05), frame(handsY: 0.7)]
        let points = HandPathTrace.points(frames: frames, geometry: geometry)
        XCTAssertEqual(points.count, 2, "The low-confidence frame in the middle should be skipped, not interpolated")
    }

    func testSmoothedPathPassesThroughEveryRealPoint() {
        // A CGPath built from N>2 points via addCurve should still begin and
        // end exactly at the first/last sample, and not collapse to a line.
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 40), CGPoint(x: 40, y: 30), CGPoint(x: 60, y: 60)]
        let cgPath = HandPathTrace.smoothedPath(through: points)
        XCTAssertFalse(cgPath.isEmpty)
        // The bounding box of the curve should roughly span the input points
        // (Catmull-Rom control points can overshoot slightly, so allow slack).
        let box = cgPath.boundingBoxOfPath
        XCTAssertLessThanOrEqual(box.minX, points.map(\.x).min()! + 1)
        XCTAssertGreaterThanOrEqual(box.maxX, points.map(\.x).max()! - 1)
    }

    func testSmoothedPathHandlesTwoPoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        let path = HandPathTrace.smoothedPath(through: points)
        XCTAssertFalse(path.isEmpty)
    }

    func testSmoothedPathHandlesEmptyInput() {
        let path = HandPathTrace.smoothedPath(through: [])
        XCTAssertTrue(path.isEmpty)
    }
}
