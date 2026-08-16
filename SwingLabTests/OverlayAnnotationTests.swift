import XCTest
@testable import SwingLab

/// The interactive drag/resize/move behavior lives in `AnnotationShapeView`,
/// a private SwiftUI view type with no exposed pure logic to unit test
/// (same situation as `ResultsView`'s zoom/pan, which also isn't unit
/// tested) — this covers the one genuinely pure piece, the model and its
/// default factories.
final class OverlayAnnotationTests: XCTestCase {

    func testDefaultLineIsHorizontalAndCentered() {
        let line = OverlayAnnotation.defaultLine()
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.start.y, line.end.y, "Default line should be horizontal")
        XCTAssertNotEqual(line.start.x, line.end.x, "Default line should have nonzero length")
        // Both endpoints within the visible unit square.
        for point in [line.start, line.end] {
            XCTAssertTrue((0...1).contains(point.x))
            XCTAssertTrue((0...1).contains(point.y))
        }
    }

    func testDefaultCircleHasPositiveRadius() {
        let circle = OverlayAnnotation.defaultCircle()
        XCTAssertEqual(circle.kind, .circle)
        let radius = hypot(circle.end.x - circle.start.x, circle.end.y - circle.start.y)
        XCTAssertGreaterThan(radius, 0)
    }

    func testEachAnnotationGetsAUniqueID() {
        let a = OverlayAnnotation.defaultLine()
        let b = OverlayAnnotation.defaultLine()
        XCTAssertNotEqual(a.id, b.id)
    }

    func testEqualityComparesAllFields() {
        let id = UUID()
        let a = OverlayAnnotation(id: id, kind: .line, start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.3, y: 0.4))
        let b = OverlayAnnotation(id: id, kind: .line, start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.3, y: 0.4))
        var c = b
        c.end = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
