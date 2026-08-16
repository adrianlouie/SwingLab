import XCTest
@testable import SwingLab

/// `FrameGeometry` is the single source of truth for where the video sits in
/// its container. If these tests hold, the overlay and the video view can
/// never physically disagree about where the body is — which is the whole
/// point of introducing it (previously they were two independent layouts
/// that only happened to agree at zoom 1).
final class FrameGeometryTests: XCTestCase {

    // MARK: - baseRect / aspect fit

    func testBaseRectFillsWidthWhenVideoIsWiderThanContainer() {
        // 16:9 video in a 9:16 container: video is far wider, so it's
        // letterboxed — full width, centred vertically.
        let g = FrameGeometry(container: CGSize(width: 300, height: 600), aspect: 16.0 / 9.0)
        XCTAssertEqual(g.baseRect.width, 300, accuracy: 0.01)
        XCTAssertLessThan(g.baseRect.height, 600)
        XCTAssertEqual(g.baseRect.midY, 300, accuracy: 0.01, "Should be vertically centred")
    }

    func testBaseRectFillsHeightWhenVideoIsTallerThanContainer() {
        // A 9:16 portrait clip in a roughly square container is pillarboxed.
        let g = FrameGeometry(container: CGSize(width: 400, height: 400), aspect: 9.0 / 16.0)
        XCTAssertEqual(g.baseRect.height, 400, accuracy: 0.01)
        XCTAssertLessThan(g.baseRect.width, 400)
        XCTAssertEqual(g.baseRect.midX, 200, accuracy: 0.01, "Should be horizontally centred")
    }

    func testInvalidAspectFallsBackToSquare() {
        let g = FrameGeometry(container: CGSize(width: 200, height: 200), aspect: 0)
        XCTAssertEqual(g.aspect, 1, "A zero or negative aspect must not propagate into the layout math")
    }

    func testEmptyContainerProducesNoNaN() {
        let g = FrameGeometry(container: .zero, aspect: 9.0 / 16.0)
        XCTAssertEqual(g.baseRect, .zero)
        XCTAssertFalse(g.contentRect.width.isNaN)
        XCTAssertFalse(g.contentRect.height.isNaN)
    }

    // MARK: - Zoom

    func testZoomOneMatchesBaseRect() {
        let g = FrameGeometry(container: CGSize(width: 300, height: 500), aspect: 9.0 / 16.0, zoom: 1)
        XCTAssertEqual(g.contentRect, g.baseRect)
    }

    func testZoomScalesAboutTheContainerCentre() {
        let container = CGSize(width: 300, height: 500)
        let g1 = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 1)
        let g2 = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 2)

        XCTAssertEqual(g2.contentRect.width, g1.contentRect.width * 2, accuracy: 0.01)
        XCTAssertEqual(g2.contentRect.height, g1.contentRect.height * 2, accuracy: 0.01)
        // Centre stays put when there's no pan offset.
        XCTAssertEqual(g2.contentRect.midX, g1.contentRect.midX, accuracy: 0.01)
        XCTAssertEqual(g2.contentRect.midY, g1.contentRect.midY, accuracy: 0.01)
    }

    func testOffsetShiftsTheContentRect() {
        let container = CGSize(width: 300, height: 500)
        let g = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 2,
                              offset: CGSize(width: 20, height: -15))
        let base = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 2)
        XCTAssertEqual(g.contentRect.midX, base.contentRect.midX + 20, accuracy: 0.01)
        XCTAssertEqual(g.contentRect.midY, base.contentRect.midY - 15, accuracy: 0.01)
    }

    // MARK: - point(_:) — the guarantee that overlays stay glued to the body

    /// A joint at the dead centre of the pose (0.5, 0.5) must land at the
    /// content rect's centre, at every zoom level. This is the direct test
    /// that overlays cannot drift off the body under zoom.
    func testCentreJointMapsToContentRectCentreAtEveryZoom() {
        let container = CGSize(width: 300, height: 500)
        for zoom: CGFloat in [1, 1.5, 2, 4, 6] {
            let g = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: zoom)
            let p = g.point(JointPoint(x: 0.5, y: 0.5, confidence: 1))
            XCTAssertEqual(p.x, g.contentRect.midX, accuracy: 0.01, "at zoom \(zoom)")
            XCTAssertEqual(p.y, g.contentRect.midY, accuracy: 0.01, "at zoom \(zoom)")
        }
    }

    func testPointHandlesTheBottomLeftOriginFlip() {
        // Vision's (0,0) is bottom-left; SwiftUI's origin is top-left. A pose
        // point at y=1 (top of the body, e.g. the head) must land at the TOP
        // of the content rect, not the bottom.
        let g = FrameGeometry(container: CGSize(width: 300, height: 500), aspect: 9.0 / 16.0)
        let top = g.point(JointPoint(x: 0.5, y: 1.0, confidence: 1))
        let bottom = g.point(JointPoint(x: 0.5, y: 0.0, confidence: 1))
        XCTAssertEqual(top.y, g.contentRect.minY, accuracy: 0.01)
        XCTAssertEqual(bottom.y, g.contentRect.maxY, accuracy: 0.01)
    }

    func testPointScalesConsistentlyWithZoom() {
        let container = CGSize(width: 300, height: 500)
        let g1 = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 1)
        let g2 = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 3)
        // A joint at the top-left corner of the frame should move exactly in
        // proportion to how much the content rect grew.
        let p1 = g1.point(JointPoint(x: 0, y: 1, confidence: 1))
        let p2 = g2.point(JointPoint(x: 0, y: 1, confidence: 1))
        XCTAssertEqual(p1.x, g1.contentRect.origin.x, accuracy: 0.01)
        XCTAssertEqual(p1.y, g1.contentRect.origin.y, accuracy: 0.01)
        XCTAssertEqual(p2.x, g2.contentRect.origin.x, accuracy: 0.01)
        XCTAssertEqual(p2.y, g2.contentRect.origin.y, accuracy: 0.01)
    }

    // MARK: - length(_:) — labels must NOT use this; geometry (head circles) must

    func testLengthScalesWithZoomButIsIndependentOfAspect() {
        let container = CGSize(width: 300, height: 500)
        let g1 = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 1)
        let g2 = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 2)
        XCTAssertEqual(g2.length(0.1), g1.length(0.1) * 2, accuracy: 0.01)
    }

    // MARK: - clampedOffset — you can never pan the body off-screen

    func testClampedOffsetIsZeroAtOrBelowOneX() {
        let base = CGRect(x: 0, y: 50, width: 300, height: 400)
        let clamped = FrameGeometry.clampedOffset(CGSize(width: 500, height: 500),
                                                  zoom: 1, baseRect: base, container: CGSize(width: 300, height: 500))
        XCTAssertEqual(clamped, .zero, "Nothing to pan at 1x")
    }

    func testClampedOffsetKeepsContentCoveringTheContainer() {
        let container = CGSize(width: 300, height: 500)
        let base = FrameGeometry(container: container, aspect: 9.0 / 16.0).baseRect
        let huge = CGSize(width: 10_000, height: 10_000)
        let clamped = FrameGeometry.clampedOffset(huge, zoom: 2, baseRect: base, container: container)

        let g = FrameGeometry(container: container, aspect: 9.0 / 16.0, zoom: 2, offset: clamped)
        XCTAssertLessThanOrEqual(g.contentRect.minX, 0.01)
        XCTAssertGreaterThanOrEqual(g.contentRect.maxX, container.width - 0.01)
        XCTAssertLessThanOrEqual(g.contentRect.minY, 0.01)
        XCTAssertGreaterThanOrEqual(g.contentRect.maxY, container.height - 0.01)
    }

    func testClampedOffsetIsSymmetric() {
        let container = CGSize(width: 300, height: 500)
        let base = FrameGeometry(container: container, aspect: 9.0 / 16.0).baseRect
        let positive = FrameGeometry.clampedOffset(CGSize(width: 1000, height: 1000),
                                                    zoom: 2, baseRect: base, container: container)
        let negative = FrameGeometry.clampedOffset(CGSize(width: -1000, height: -1000),
                                                    zoom: 2, baseRect: base, container: container)
        XCTAssertEqual(positive.width, -negative.width, accuracy: 0.01)
        XCTAssertEqual(positive.height, -negative.height, accuracy: 0.01)
    }
}
