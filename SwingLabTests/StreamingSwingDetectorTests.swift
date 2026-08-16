import XCTest
@testable import SwingLab

/// Regression tests for `StreamingSwingDetector`, replaying the same
/// synthetic-but-realistic frame sequences `SwingFixture` already builds for
/// `PositionDetectorTests` — one frame at a time, the way a live capture
/// session would — asserting it fires near where the offline
/// `SwingWindowScanner` would land on the same full sequence, and does not
/// fire early or on a waggle-only sequence with no real swing in it.
final class StreamingSwingDetectorTests: XCTestCase {

    private func ingestAll(_ frames: [PoseFrame], into detector: StreamingSwingDetector) async -> [StreamingSwingDetector.SwingDetectionEvent] {
        var events: [StreamingSwingDetector.SwingDetectionEvent] = []
        let stream = await detector.events()
        let collector = Task {
            for await event in stream {
                events.append(event)
            }
        }
        for frame in frames {
            await detector.ingest(frame)
        }
        // Give the collector a moment to drain, then stop it — the stream
        // itself never finishes on its own (the detector runs for the life
        // of a practice session).
        try? await Task.sleep(nanoseconds: 10_000_000)
        collector.cancel()
        return events
    }

    func testFiresOnceAfterAGenuineSwingCompletes() async {
        let frames = SwingFixture.frames()
        let detector = StreamingSwingDetector(space: .square)

        let events = await ingestAll(frames, into: detector)

        let completions = events.compactMap { event -> (ClosedRange<Double>, Double)? in
            if case let .swingCompleted(window, topTime) = event { return (window, topTime) }
            return nil
        }
        XCTAssertEqual(completions.count, 1, "A single real swing should fire exactly once, not zero or repeatedly")

        guard let (window, topTime) = completions.first else { return }

        // Cross-check against the offline scanner run on the same full
        // sequence — the two must agree, since the streaming detector is
        // just the same batch algorithm run against a rolling buffer.
        let offline = SwingWindowScanner.scan(frames: frames, space: .square, clipDuration: frames.last!.time)
        guard let expected = offline.best else {
            XCTFail("offline scanner found no candidate on its own fixture")
            return
        }
        XCTAssertEqual(topTime, expected.topTime, accuracy: 0.05)
        XCTAssertEqual(window.lowerBound, expected.range.lowerBound, accuracy: 0.05)
        XCTAssertEqual(window.upperBound, expected.range.upperBound, accuracy: 0.05)
    }

    func testDoesNotFireOnWaggleWithNoRealSwing() async {
        // Walk-in + waggle + a long address hold, then stop — no backswing,
        // no downswing burst. Must never report a completed swing.
        var options = SwingFixture.Options()
        options.backswing = 0
        options.topPause = 0
        options.downswing = 0
        options.followThrough = 0
        options.finishHold = 2.0
        let frames = SwingFixture.frames(options)
        let detector = StreamingSwingDetector(space: .square)

        let events = await ingestAll(frames, into: detector)

        let completions = events.filter {
            if case .swingCompleted = $0 { return true }
            return false
        }
        XCTAssertTrue(completions.isEmpty, "No backswing/downswing happened — must never report a completed swing")
    }

    func testResetDiscardsHistoryBeforeItCanCompleteASwing() async {
        // Ingest well past the top and into the downswing burst — but stop
        // comfortably before any possible quiet-confirmation (which needs
        // at least ~1s past the burst; growForwards can't return early
        // sooner than that), then reset. If reset genuinely discards the
        // buffer, the few frames ingested afterward — nowhere near enough
        // to contain an address, a top, or a burst on their own — can't
        // complete a swing.
        let frames = SwingFixture.frames()
        let detector = StreamingSwingDetector(space: .square)
        let cutoff = frames.firstIndex { $0.time > 3.7 } ?? frames.count
        for frame in frames.prefix(cutoff) {
            await detector.ingest(frame)
        }
        await detector.reset()

        let events = await ingestAll(Array(frames.suffix(from: cutoff)), into: detector)
        let completions = events.filter {
            if case .swingCompleted = $0 { return true }
            return false
        }
        XCTAssertTrue(completions.isEmpty,
                      "Reset must discard buffered history — the tail end of a swing alone can't complete one")
    }
}
