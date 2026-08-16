import XCTest
import SwiftData
@testable import SwingLab

/// `SwingRescorer` is the direct regression test for the bug that started
/// this round of work: a down-the-line swing analysed as if it were face-on
/// produced a meaningless, heavily-weighted "shoulder turn" reading. These
/// tests confirm that correcting the view afterwards actually fixes it.
@MainActor
final class SwingRescorerTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: SwingRecord.self,
                                        configurations: .init(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func joint(_ x: Double, _ y: Double, _ c: Double = 0.9) -> JointPoint {
        JointPoint(x: x, y: y, confidence: c)
    }

    /// Address square to the camera; at the top the shoulders foreshorten
    /// hard relative to the hips — a real, honest face-on coil pattern.
    private func pose(shoulderHalfWidth: Double, hipHalfWidth: Double, time: Double = 0) -> PoseFrame {
        PoseFrame(time: time, joints: [
            .nose: joint(0.5, 0.9), .neck: joint(0.5, 0.82),
            .leftShoulder: joint(0.5 - shoulderHalfWidth, 0.8),
            .rightShoulder: joint(0.5 + shoulderHalfWidth, 0.8),
            .leftWrist: joint(0.49, 0.5), .rightWrist: joint(0.51, 0.5),
            .root: joint(0.5, 0.52),
            .leftHip: joint(0.5 - hipHalfWidth, 0.52), .rightHip: joint(0.5 + hipHalfWidth, 0.52),
            .leftAnkle: joint(0.42, 0.04), .rightAnkle: joint(0.58, 0.04),
        ])
    }

    private func makeMisTaggedRecord() -> (SwingRecord, SwingAnalysis) {
        // This pose sequence is a real face-on coil (shoulders foreshorten far
        // more than hips at the top). The bug reproduced here is tagging it
        // .downTheLine at capture time despite that — a golfer filmed face-on
        // but the app told the wrong thing, or vice versa; the direction
        // doesn't matter, what matters is that isVisible must strip whatever
        // the WRONG view can't see.
        let address = pose(shoulderHalfWidth: 0.10, hipHalfWidth: 0.06)
        let top = pose(shoulderHalfWidth: 0.02, hipHalfWidth: 0.045, time: 0.8)
        let positions = [
            DetectedPosition(position: .address, frameIndex: 0, time: 0),
            DetectedPosition(position: .top, frameIndex: 1, time: 0.8),
        ]

        // Scored under the WRONG view first, exactly like the reported bug:
        // shoulderTurn gets computed and weighted into the score even though
        // this is (we're about to claim) really a down-the-line clip.
        let (metrics, overall) = SwingAnalyzer.analyze(frames: [address, top], positions: positions,
                                                        profile: .default, shotType: .fullSwing,
                                                        view: .faceOn, handedness: .right)
        let faults = FaultDetector.detect(context: .init(
            frames: [address, top], positions: positions, space: .square,
            handedness: .right, view: .faceOn, frameRate: 120, ballOverride: nil))

        let analysis = SwingAnalysis(frames: [address, top], positions: positions, metrics: metrics,
                                     overallScore: overall, frameRate: 120, duration: 1.0, faults: faults)
        let record = SwingRecord(videoFileName: "test.mov", viewType: .faceOn, handedness: .right,
                                 shotType: .fullSwing, overallScore: overall, thumbnailData: nil,
                                 analysis: analysis, coachingText: "")
        context.insert(record)
        return (record, analysis)
    }

    // MARK: - The regression test

    func testCorrectingTheViewRemovesTheUnmeasurableMetrics() async {
        let (record, analysis) = makeMisTaggedRecord()
        XCTAssertTrue(record.analysis!.metrics.contains { $0.kind == .shoulderTurn },
                     "Sanity check: the wrong view really did produce a shoulder-turn reading")

        await SwingRescorer.rescore(record: record, analysis: analysis, view: .downTheLine,
                                    shotType: .fullSwing, club: nil, profile: .default, context: context)

        let corrected = record.analysis!
        XCTAssertFalse(corrected.metrics.contains { $0.kind == .shoulderTurn },
                       "Correcting to Down-the-Line must drop the unmeasurable shoulder-turn reading")
        XCTAssertEqual(record.viewType, .downTheLine)
    }

    func testRescoringUsesTheStoredSpaceNotSquare() async {
        // The bug this specifically guards: the old saveAndRescore called
        // SwingAnalyzer.analyze without `space:`, silently re-scoring in
        // square coordinates and reinflating angles by ~1.78x on a 9:16 clip.
        let (record, analysis) = makeMisTaggedRecord()
        var widened = analysis
        widened.storedSpace = PoseSpace(aspect: 9.0 / 16.0)
        record.updateAnalysis(widened)

        await SwingRescorer.rescore(record: record, analysis: widened, view: .faceOn,
                                    shotType: .fullSwing, club: nil, profile: .default, context: context)

        XCTAssertEqual(record.analysis!.space.aspect, 9.0 / 16.0, accuracy: 1e-9,
                       "Re-scoring must preserve the swing's real coordinate space")
    }

    func testRescoringRecomputesFaultsForTheNewView() async {
        // overTheTop only exists down-the-line; a fault computed under the old
        // view must not survive a view correction that makes it meaningless.
        let (record, _) = makeMisTaggedRecord()
        var withStaleFault = record.analysis!
        withStaleFault.storedFaults = [SwingFault(kind: .overTheTop, severity: .clear,
                                                   confidence: 0.8, evidence: [], position: .delivery)]
        record.updateAnalysis(withStaleFault)
        XCTAssertTrue(record.analysis!.faults.contains { $0.kind == .overTheTop })

        await SwingRescorer.rescore(record: record, analysis: withStaleFault, view: .faceOn,
                                    shotType: .fullSwing, club: nil, profile: .default, context: context)

        XCTAssertFalse(record.analysis!.faults.contains { $0.kind == .overTheTop },
                       "A DTL-only fault must not survive being re-scored under Face-On")
    }

    func testRescoringUpdatesTheStoredViewAndShotType() async {
        let (record, analysis) = makeMisTaggedRecord()
        await SwingRescorer.rescore(record: record, analysis: analysis, view: .downTheLine,
                                    shotType: .pitch, club: nil, profile: .default, context: context)
        XCTAssertEqual(record.viewType, .downTheLine)
        XCTAssertEqual(record.shotType, .pitch)
    }

    func testRescoringChangesTheOverallScore() async {
        let (record, analysis) = makeMisTaggedRecord()
        let before = record.overallScore
        await SwingRescorer.rescore(record: record, analysis: analysis, view: .downTheLine,
                                    shotType: .fullSwing, club: nil, profile: .default, context: context)
        XCTAssertNotEqual(record.overallScore, before,
                          "Dropping the unmeasurable metrics should change the weighted score")
    }

    func testRescoringPersistsThroughTheModelContext() async {
        let (record, analysis) = makeMisTaggedRecord()
        await SwingRescorer.rescore(record: record, analysis: analysis, view: .downTheLine,
                                    shotType: .fullSwing, club: nil, profile: .default, context: context)
        // Re-fetch through the context rather than trusting the in-memory
        // reference, to confirm `context.save()` actually ran.
        let fetched = try! context.fetch(FetchDescriptor<SwingRecord>())
        XCTAssertEqual(fetched.first?.viewType, .downTheLine)
    }
}
