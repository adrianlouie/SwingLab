import Foundation
import SwiftData

/// The one path that re-scores an already-analysed swing — after a frame is
/// nudged, or the camera view, shot type or club is corrected.
///
/// This exists because the code it replaces (`AdjustFramesSheet.saveAndRescore`)
/// had two real bugs: it called `SwingAnalyzer.analyze` without `space:`,
/// which silently re-scored in square coordinates and reintroduced the ~1.5x
/// angle inflation that a whole earlier round of work fixed, and it never
/// re-ran `FaultDetector`, so a swing's faults went stale the moment its
/// frames or view changed — a fault computed under the OLD view can name
/// something the new view can't even see (`overTheTop` is down-the-line only,
/// `sway`/`slide`/`hangBack`/`reversePivot` are face-on only).
///
/// Every caller that changes something about an analysed swing — the frame
/// nudge sheet, a camera-view correction, a club change, or
/// `AnalysisPipeline.reextract` handing off freshly re-extracted
/// frames/positions after the swing window was corrected — must go through
/// this rather than hand-rolling the same four steps, which is exactly how
/// the dropped `space:` argument happened the first time.
enum SwingRescorer {

    @MainActor
    static func rescore(record: SwingRecord,
                        analysis: SwingAnalysis,
                        view: CameraViewType,
                        shotType: ShotType,
                        club: GolfClub?,
                        profile: ModelProProfile,
                        context: ModelContext) async {
        let (metrics, overall) = SwingAnalyzer.analyze(frames: analysis.frames,
                                                        positions: analysis.positions,
                                                        profile: profile,
                                                        shotType: shotType,
                                                        view: view,
                                                        handedness: record.handedness,
                                                        space: analysis.space,
                                                        club: club)

        let faults = FaultDetector.detect(context: .init(
            frames: analysis.frames,
            positions: analysis.positions,
            space: analysis.space,
            handedness: record.handedness,
            view: view,
            frameRate: analysis.frameRate,
            ballOverride: nil))

        var updated = analysis
        updated.metrics = metrics
        updated.overallScore = overall
        updated.storedFaults = faults

        record.viewType = view
        record.shotType = shotType
        record.club = club
        record.updateAnalysis(updated)
        try? context.save()

        // Coaching runs in the background — it's an LLM call (or the rules
        // fallback), and there's no reason to hold the UI for it.
        let shotResult = record.shotResult
        let frameRate = analysis.frameRate
        Task {
            let text = await Coach.coaching(for: metrics, faults: faults, shotResult: shotResult,
                                            shotType: shotType, view: view, overallScore: overall,
                                            frameRate: frameRate)
            await MainActor.run {
                record.coachingText = text
                try? context.save()
            }
        }
    }
}
