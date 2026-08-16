import XCTest
import SwiftUI
@testable import SwingLab

/// `LabelLayout` is what stops a label rendering on top of the line or circle
/// it's explaining — previously the spine-angle label and the head-drift
/// label used fixed offsets with no awareness of anything else on screen, and
/// the swing-plane line could paint directly over the spine label.
final class LabelLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 700)
    private let labelSize = CGSize(width: 50, height: 20)

    private func request(_ id: String, anchor: CGPoint, priority: Int = 0) -> LabelRequest {
        LabelRequest(id: id, text: "x", anchor: anchor, tint: .green, priority: priority)
    }

    // MARK: - Segment / circle / rect intersection primitives

    func testSegmentIntersectsRectWhenEndpointInside() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(LabelLayout.segmentIntersectsRect(CGPoint(x: 15, y: 15), CGPoint(x: 100, y: 100), rect))
    }

    func testSegmentIntersectsRectWhenPassingThrough() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        // Passes straight through without either endpoint inside.
        XCTAssertTrue(LabelLayout.segmentIntersectsRect(CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20), rect))
    }

    func testSegmentDoesNotIntersectARectItMisses() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertFalse(LabelLayout.segmentIntersectsRect(CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), rect))
    }

    func testCircleIntersectsRectWhenOverlapping() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(LabelLayout.circleIntersectsRect(CGPoint(x: 10, y: 10), 5, rect),
                     "Circle centred on the corner should overlap")
        XCTAssertFalse(LabelLayout.circleIntersectsRect(CGPoint(x: 100, y: 100), 5, rect))
    }

    func testCircleTangentToRectDoesNotCountAsIntersecting() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        // Centre 10pt to the left of the rect, radius exactly 10 touches the edge.
        XCTAssertFalse(LabelLayout.circleIntersectsRect(CGPoint(x: -0.001, y: 20), 10, rect))
    }

    // MARK: - Obstacle-aware placement

    func testLabelAvoidsAKnownObstacle() {
        var obstacles = OverlayObstacles()
        // A vertical line right where the label would naturally go (directly
        // right of the anchor, the first direction tried).
        obstacles.addSegment(CGPoint(x: 114, y: 80), CGPoint(x: 114, y: 120))

        let anchor = CGPoint(x: 100, y: 100)
        let placed = LabelLayout.place([request("a", anchor: anchor)],
                                       sizes: ["a": labelSize], obstacles: obstacles, bounds: bounds)
        XCTAssertEqual(placed.count, 1)
        XCTAssertFalse(obstacles.intersects(placed[0].rect),
                       "The chosen slot must not overlap the known obstacle")
    }

    func testTwoLabelsNearTheSameAnchorDoNotOverlapEachOther() {
        let anchor = CGPoint(x: 100, y: 100)
        let placed = LabelLayout.place(
            [request("a", anchor: anchor, priority: 0), request("b", anchor: anchor, priority: 1)],
            sizes: ["a": labelSize, "b": labelSize], obstacles: OverlayObstacles(), bounds: bounds)

        XCTAssertEqual(placed.count, 2)
        XCTAssertFalse(placed[0].rect.intersects(placed[1].rect),
                       "Two labels anchored at the same point must not land on top of each other")
    }

    func testHigherPriorityLabelGetsTheNearestSlot() {
        let anchor = CGPoint(x: 100, y: 100)
        let placed = LabelLayout.place(
            [request("low", anchor: anchor, priority: 5), request("high", anchor: anchor, priority: 0)],
            sizes: ["low": labelSize, "high": labelSize], obstacles: OverlayObstacles(), bounds: bounds)

        let high = placed.first { $0.request.id == "high" }!
        let low = placed.first { $0.request.id == "low" }!
        let highDistance = hypot(high.rect.midX - anchor.x, high.rect.midY - anchor.y)
        let lowDistance = hypot(low.rect.midX - anchor.x, low.rect.midY - anchor.y)
        XCTAssertLessThanOrEqual(highDistance, lowDistance,
                                 "Priority 0 should be placed before priority 5 and claim the nearer slot")
    }

    // MARK: - Bounds clamping

    func testLabelNeverRendersOutsideBounds() {
        // Anchor right at the edge, so the natural placement would spill over.
        let anchor = CGPoint(x: 2, y: 2)
        let placed = LabelLayout.place([request("edge", anchor: anchor)],
                                       sizes: ["edge": labelSize], obstacles: OverlayObstacles(), bounds: bounds)
        guard let rect = placed.first?.rect else { return XCTFail("expected a placement") }
        XCTAssertTrue(bounds.contains(CGPoint(x: rect.minX, y: rect.minY)))
        XCTAssertTrue(bounds.contains(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    func testAnchorOutsideBoundsIsSkippedEntirely() {
        // Simulates a joint that panned out of the visible area while zoomed.
        let anchor = CGPoint(x: -500, y: -500)
        let placed = LabelLayout.place([request("offscreen", anchor: anchor)],
                                       sizes: ["offscreen": labelSize], obstacles: OverlayObstacles(), bounds: bounds)
        XCTAssertTrue(placed.isEmpty, "A label whose anchor is off-screen should not be drawn at all")
    }

    // MARK: - Determinism

    func testSameInputProducesTheSamePlacementEveryTime() {
        var obstacles = OverlayObstacles()
        obstacles.addSegment(CGPoint(x: 90, y: 60), CGPoint(x: 90, y: 140))
        obstacles.addCircle(center: CGPoint(x: 130, y: 100), radius: 12)
        let requests = [request("a", anchor: CGPoint(x: 100, y: 100)),
                        request("b", anchor: CGPoint(x: 200, y: 300), priority: 1)]
        let sizes = ["a": labelSize, "b": labelSize]

        let first = LabelLayout.place(requests, sizes: sizes, obstacles: obstacles, bounds: bounds)
        let second = LabelLayout.place(requests, sizes: sizes, obstacles: obstacles, bounds: bounds)

        XCTAssertEqual(first.map(\.rect), second.map(\.rect))
    }

    // MARK: - Least-overlap fallback

    /// Surround the anchor completely so no clean slot exists at any radius,
    /// and confirm placement still produces something inside bounds rather
    /// than crashing or returning nothing.
    func testFallsBackGracefullyWhenNothingIsClean() {
        var obstacles = OverlayObstacles()
        for radius: CGFloat in [14, 30, 52, 80] {
            for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 8) {
                let center = CGPoint(x: 100 + radius * cos(angle), y: 100 + radius * sin(angle))
                obstacles.addCircle(center: center, radius: 10)
            }
        }
        let placed = LabelLayout.place([request("boxed", anchor: CGPoint(x: 100, y: 100))],
                                       sizes: ["boxed": labelSize], obstacles: obstacles, bounds: bounds)
        XCTAssertEqual(placed.count, 1)
        XCTAssertTrue(bounds.contains(CGPoint(x: placed[0].rect.midX, y: placed[0].rect.midY)))
    }

    // MARK: - Leader lines

    func testLeaderLineAppearsOnlyWhenPlacementMovedFar() {
        // A completely open area: the nearest clean slot should be very close
        // to the anchor (14pt radius), well under the 26pt leader threshold.
        let placed = LabelLayout.place([request("near", anchor: CGPoint(x: 200, y: 350))],
                                       sizes: ["near": labelSize], obstacles: OverlayObstacles(), bounds: bounds)
        XCTAssertNil(placed.first?.leader, "A nearby placement shouldn't need a leader line")
    }

    func testMissingSizeSkipsTheLabel() {
        let placed = LabelLayout.place([request("nosize", anchor: CGPoint(x: 100, y: 100))],
                                       sizes: [:], obstacles: OverlayObstacles(), bounds: bounds)
        XCTAssertTrue(placed.isEmpty)
    }
}
