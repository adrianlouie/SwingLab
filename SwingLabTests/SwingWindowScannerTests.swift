import XCTest
@testable import SwingLab

/// Regression tests for `SwingWindowScanner.findCandidates`, built directly
/// against a hand-constructed `Signal` so the failure modes found on real
/// footage can be pinned without needing a real clip.
final class SwingWindowScannerTests: XCTestCase {

    /// Confirmed against a real clip: the golfer's hands sit *higher* at the
    /// finish than they did at the top of the backswing (a normal follow-
    /// through), and the finish-like local max landed within
    /// `minimumSeparation` of the genuine top. The old grouping order
    /// ("collapse first, keep whichever peak has the higher raw lift, filter
    /// survivors for a downswing afterward") let the finish's higher lift
    /// value evict the true top from the group *before* either was tested
    /// for a downswing — so the surviving representative was the finish,
    /// which has no downswing after it, and the whole swing was discarded
    /// with zero candidates found even though a real top with a real
    /// downswing burst was right there in the raw peaks.
    func testGenuineTopSurvivesAHigherFinishLiftNearby() {
        // (time, lift, energy-of-the-step-ending-here). Quiet address, a
        // backswing rise into a genuine top with a real downswing burst
        // right after it, then a finish that ends up higher than the top
        // but with nothing fast following it.
        var samples: [(t: Double, lift: Double, energy: Double?)] = []
        for i in 0...20 { samples.append((Double(i) * 0.1, -1.0, i == 0 ? nil : 0.05)) }
        samples += [
            (2.1, -0.6, 0.3),
            (2.2, -0.2, 0.3),
            (2.3, 0.10, 0.3),
            (2.4, 0.50, 0.3),   // the genuine top
            (2.5, 0.48, 9.0),   // downswing burst starts right after
            (2.6, 0.55, 8.5),
            (2.7, 0.60, 0.3),   // burst has passed
            (2.8, 0.62, 0.2),
            (2.9, 0.64, 0.15),
            (3.0, 0.70, 0.1),   // the finish: higher than the top...
            (3.1, 0.65, 0.1),   // ...but no burst follows it
        ]
        for i in 0...20 { samples.append((3.2 + Double(i) * 0.1, 0.60, 0.05)) }

        let signal = SwingWindowScanner.Signal(
            times: samples.map(\.t),
            handsBody: samples.map { _ in nil },
            lift: samples.map { $0.lift },
            energy: samples.map(\.energy),
            quality: samples.map { _ in 1.0 },
            scale: 1.0)

        let candidates = SwingWindowScanner.findCandidates(signal: signal, tuning: .default)

        XCTAssertEqual(candidates.count, 1,
                       "A genuine top with a real downswing burst must not be discarded just because a later, unrelated finish sits higher and nearby")
        XCTAssertEqual(candidates.first?.topTime ?? -1, 2.4, accuracy: 0.05,
                       "The candidate's top should land on the real top of the backswing, not the finish")
    }
}
