import XCTest
@testable import SwingLab

/// `PoseTimeline` maps an `AVPlayer`'s current time to the nearest pose
/// frame during playback. It has to handle ordinary forward playback (a
/// cheap walk), scrubbing (a jump either direction), and the edges (before
/// the first frame, after the last).
final class PoseTimelineTests: XCTestCase {

    private let times = stride(from: 0.0, through: 2.0, by: 1.0 / 30.0).map { $0 }

    func testWalksForwardMonotonically() {
        var timeline = PoseTimeline(times: times)
        var lastIndex = -1
        for t in stride(from: 0.0, through: 2.0, by: 1.0 / 30.0) {
            guard let idx = timeline.index(at: t) else { return XCTFail("expected an index at \(t)") }
            XCTAssertGreaterThanOrEqual(idx, lastIndex, "must never walk backward during forward playback")
            lastIndex = idx
        }
    }

    func testLandsOnTheNearestFrameBetweenSamples() {
        var timeline = PoseTimeline(times: [0, 1, 2, 3])
        XCTAssertEqual(timeline.index(at: 0.4), 0)
        XCTAssertEqual(timeline.index(at: 0.6), 1)
    }

    func testBackwardSeekJumpsDirectlyRatherThanWalking() {
        var timeline = PoseTimeline(times: times)
        _ = timeline.index(at: 1.8)
        let idx = timeline.index(at: 0.1)
        XCTAssertEqual(idx, Int((0.1 / (1.0 / 30.0)).rounded()))
    }

    func testForwardScrubJumpsDirectly() {
        var timeline = PoseTimeline(times: times)
        _ = timeline.index(at: 0.1)
        let idx = timeline.index(at: 1.9)
        XCTAssertEqual(idx, Int((1.9 / (1.0 / 30.0)).rounded()))
    }

    func testOutOfSpanReturnsNil() {
        var timeline = PoseTimeline(times: [1, 2, 3])
        XCTAssertNil(timeline.index(at: -5))
        XCTAssertNil(timeline.index(at: 50))
    }

    func testEmptyTimelineAlwaysReturnsNil() {
        var timeline = PoseTimeline(times: [])
        XCTAssertNil(timeline.index(at: 0))
    }

    func testSingleFrameTimelineAlwaysReturnsThatFrame() {
        var timeline = PoseTimeline(times: [5.0])
        XCTAssertEqual(timeline.index(at: 5.0), 0)
        XCTAssertEqual(timeline.index(at: 5.001), 0)
    }
}
