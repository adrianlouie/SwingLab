import XCTest
@testable import SwingLab

/// `SwingAnalysis.playbackRange` is what bounds the AVPlayer to just the
/// swing — not the up-to-five-second scanner window, and correctly on
/// records saved before `window` existed (every record until this feature).
final class PlaybackRangeTests: XCTestCase {

    private func frames(from start: Double, to end: Double, step: Double = 1.0 / 30.0) -> [PoseFrame] {
        stride(from: start, through: end, by: step).map { PoseFrame(time: $0, joints: [:]) }
    }

    func testDerivedFromAddressAndFinishNotWindow() {
        let analysis = SwingAnalysis(
            frames: frames(from: 0, to: 6),
            positions: [
                DetectedPosition(position: .address, frameIndex: 60, time: 2.0),
                DetectedPosition(position: .finish, frameIndex: 150, time: 5.0),
            ],
            metrics: [], overallScore: 80, frameRate: 30, duration: 6)

        let range = analysis.playbackRange
        XCTAssertEqual(range.lowerBound, 2.0 - 0.35, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 5.0 + 0.5, accuracy: 0.001)
    }

    func testClampsToTheFramesActuallyAvailable() {
        // Address sits right at the start of what was captured, so the
        // usual 0.35s pre-roll would reach before frame zero.
        let analysis = SwingAnalysis(
            frames: frames(from: 0, to: 2),
            positions: [
                DetectedPosition(position: .address, frameIndex: 0, time: 0.1),
                DetectedPosition(position: .finish, frameIndex: 60, time: 1.9),
            ],
            metrics: [], overallScore: 80, frameRate: 30, duration: 2)

        let range = analysis.playbackRange
        XCTAssertEqual(range.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 2, accuracy: 0.001)
    }

    /// No positions at all is what every record saved before position
    /// detection existed would decode to — must not crash or produce an
    /// inverted range.
    func testFallsBackToFullFrameSpanWithoutAddressOrFinish() {
        let analysis = SwingAnalysis(
            frames: frames(from: 0, to: 3),
            positions: [], metrics: [], overallScore: 80, frameRate: 30, duration: 3)

        let range = analysis.playbackRange
        XCTAssertEqual(range.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 3, accuracy: 0.001)
    }

    func testNeverProducesAnInvertedRange() {
        // Finish detected essentially on top of address — a degenerate case
        // a bad detection could produce.
        let analysis = SwingAnalysis(
            frames: frames(from: 0, to: 1),
            positions: [
                DetectedPosition(position: .address, frameIndex: 15, time: 0.5),
                DetectedPosition(position: .finish, frameIndex: 15, time: 0.5),
            ],
            metrics: [], overallScore: 80, frameRate: 30, duration: 1)

        let range = analysis.playbackRange
        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
    }
}

/// `ProblemStop.stops` is what tells `SwingPlayerController` where to pause.
final class ProblemStopTests: XCTestCase {

    private func analysis(faults: [SwingFault]) -> SwingAnalysis {
        SwingAnalysis(
            frames: [PoseFrame(time: 0, joints: [:])],
            positions: [
                DetectedPosition(position: .top, frameIndex: 0, time: 0.8),
                DetectedPosition(position: .impact, frameIndex: 0, time: 1.1),
            ],
            metrics: [], overallScore: 80, frameRate: 60, duration: 2,
            faults: faults)
    }

    func testGroupsFaultsByPositionAndResolvesTime() {
        let faults = [
            SwingFault(kind: .sway, severity: .clear, confidence: 0.8, evidence: [], position: .top),
            SwingFault(kind: .reversePivot, severity: .clear, confidence: 0.8, evidence: [], position: .top),
            SwingFault(kind: .casting, severity: .clear, confidence: 0.8, evidence: [], position: .impact),
        ]
        let stops = ProblemStop.stops(faults: faults, analysis: analysis(faults: faults))

        XCTAssertEqual(stops.count, 2)
        let top = stops.first { $0.position == .top }
        XCTAssertEqual(top?.faults.count, 2)
        XCTAssertEqual(top?.time, 0.8)
    }

    func testStopsAreSortedByTime() {
        let faults = [
            SwingFault(kind: .casting, severity: .clear, confidence: 0.8, evidence: [], position: .impact),
            SwingFault(kind: .sway, severity: .clear, confidence: 0.8, evidence: [], position: .top),
        ]
        let stops = ProblemStop.stops(faults: faults, analysis: analysis(faults: faults))
        XCTAssertEqual(stops.map(\.position), [.top, .impact])
    }

    func testFaultsWithoutAPositionAreDropped() {
        let faults = [SwingFault(kind: .fatTendency, severity: .clear, confidence: 0.8, evidence: [], position: nil)]
        let stops = ProblemStop.stops(faults: faults, analysis: analysis(faults: faults))
        XCTAssertTrue(stops.isEmpty)
    }

    func testFaultAtAPositionNeverDetectedProducesNoStop() {
        let faults = [SwingFault(kind: .sway, severity: .clear, confidence: 0.8, evidence: [], position: .address)]
        let stops = ProblemStop.stops(faults: faults, analysis: analysis(faults: faults))
        XCTAssertTrue(stops.isEmpty, "address was never detected in this fixture, so there's nowhere to seek to")
    }
}
