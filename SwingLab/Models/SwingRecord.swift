import Foundation
import SwiftData

/// One analyzed swing in the library. The heavyweight analysis payload
/// (pose frames, positions, metrics) is stored as a single JSON blob so the
/// schema stays simple; the video lives on disk via `VideoStore`.
@Model
final class SwingRecord {
    var date: Date = Date()
    var videoFileName: String = ""
    var viewTypeRaw: String = CameraViewType.faceOn.rawValue
    var handednessRaw: String = Handedness.right.rawValue
    var shotTypeRaw: String = ShotType.fullSwing.rawValue
    var overallScore: Double = 0
    var isReference: Bool = false
    var thumbnailData: Data?
    var analysisData: Data?
    var coachingText: String = ""
    /// What the golfer says happened to the shot. A SwiftData property with a
    /// default, so this is a safe lightweight migration.
    var shotResultRaw: String = ShotResult.unknown.rawValue
    /// Empty means unspecified — every record saved before club selection
    /// existed decodes to this, and `ClubAdjustment` treats "unspecified" as
    /// zero shift, so old records re-score byte-identically.
    var clubRaw: String = ""

    init(date: Date = Date(),
         videoFileName: String,
         viewType: CameraViewType,
         handedness: Handedness,
         shotType: ShotType,
         overallScore: Double,
         thumbnailData: Data?,
         analysis: SwingAnalysis?,
         coachingText: String) {
        self.date = date
        self.videoFileName = videoFileName
        self.viewTypeRaw = viewType.rawValue
        self.handednessRaw = handedness.rawValue
        self.shotTypeRaw = shotType.rawValue
        self.overallScore = overallScore
        self.isReference = false
        self.thumbnailData = thumbnailData
        self.analysisData = analysis.flatMap { try? JSONEncoder().encode($0) }
        self.coachingText = coachingText
    }

    // Settable, not just get-only: changing the camera view or shot type on an
    // already-analysed swing (through `SwingRescorer`) is how a mis-tagged
    // view — the thing that let a back-view clip get scored as face-on and
    // produce a meaningless shoulder-turn reading — gets corrected without a
    // re-import.
    var viewType: CameraViewType {
        get { CameraViewType(rawValue: viewTypeRaw) ?? .faceOn }
        set { viewTypeRaw = newValue.rawValue }
    }
    var handedness: Handedness { Handedness(rawValue: handednessRaw) ?? .right }
    var shotType: ShotType {
        get { ShotType(rawValue: shotTypeRaw) ?? .fullSwing }
        set { shotTypeRaw = newValue.rawValue }
    }
    var shotResult: ShotResult {
        get { ShotResult(rawValue: shotResultRaw) ?? .unknown }
        set { shotResultRaw = newValue.rawValue }
    }
    var club: GolfClub? {
        get { GolfClub(rawValue: clubRaw) }
        set { clubRaw = newValue?.rawValue ?? "" }
    }

    /// Faults, re-ranked against whatever the golfer reported.
    var faults: [SwingFault] {
        FaultDetector.reconcile(faults: analysis?.faults ?? [], with: shotResult)
    }

    var analysis: SwingAnalysis? {
        guard let data = analysisData else { return nil }
        return try? JSONDecoder().decode(SwingAnalysis.self, from: data)
    }

    func updateAnalysis(_ analysis: SwingAnalysis) {
        analysisData = try? JSONEncoder().encode(analysis)
        overallScore = analysis.overallScore
    }

    var videoURL: URL {
        VideoStore.url(for: videoFileName)
    }
}
