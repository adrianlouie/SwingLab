import Foundation
import SwiftUI
import SwiftData
import AVFoundation
import UIKit

/// Drives the whole on-device analysis flow for one video and reports
/// progress to the UI.
@MainActor
final class AnalysisPipeline: ObservableObject {

    enum Stage: Equatable {
        case idle
        case preparing
        case extractingPoses(Double) // 0...1
        case detectingPositions
        case measuringRotation
        case scoring
        case coaching
        case done
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var finishedRecord: SwingRecord?

    /// Soft failures with a specific, user-facing explanation — thrown
    /// rather than returned so `run` and `reextract` share one `catch` that
    /// turns any failure, soft or hard, into `stage = .failed(message)`.
    private enum PipelineFailure: LocalizedError {
        case notUpright
        case noPositions

        var errorDescription: String? {
            switch self {
            case .notUpright:
                return "The golfer couldn't be tracked properly in this video — the body reads as sideways. If the clip was rotated or exported oddly, try re-exporting it from Photos."
            case .noPositions:
                return "Couldn't find a swing in this video. Make sure the clip contains one full swing with your whole body visible."
            }
        }
    }

    /// Pass 1 alone, split out from `run` so the setup sheet can kick it off
    /// the moment it appears — while the golfer is still picking camera view
    /// and club — instead of only starting it once "Analyze" is tapped.
    ///
    /// No swing-window detection here anymore (a deliberate call: better to
    /// just analyze the whole clip recorded/imported than have
    /// it guess at a sub-window and risk cutting the real swing short —
    /// exactly the class of bug this session's earlier real-footage work
    /// kept finding). This is now just a cheap `AVURLAsset` duration read,
    /// no Vision involved at all — nothing left to run at coarse frame rate.
    /// `SwingWindowScanner` itself is untouched and still runs — just not
    /// from here — inside Practice mode's `StreamingSwingDetector`, which
    /// still needs to detect when a swing ends in a live, continuous
    /// recording; that's a different problem ("has a swing just happened")
    /// than this one ("where in an already-finished clip is the swing").
    struct Preflight {
        var coarseDuration: Double
    }

    func preflight(videoURL: URL) async throws -> Preflight {
        // Deliberately doesn't touch `stage` — this runs silently in the
        // background while the setup sheet is still showing the form, and a
        // `stage` change here would flip `isRunning` and hide it.
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        return Preflight(coarseDuration: duration)
    }

    /// Pass 2 onward, given an already-computed `Preflight` — never re-reads
    /// clip duration a second time, which the old single `run` did
    /// implicitly on every call.
    ///
    /// Always extracts and analyzes the ENTIRE clip — no window. Trimming
    /// belongs to the golfer, not a guess: `reextract` below (via Adjust
    /// Frames) is there if a clip genuinely needs narrowing after the fact,
    /// with the golfer able to see exactly what's being cut.
    func run(videoURL: URL,
             preflight: Preflight,
             shotType: ShotType,
             view: CameraViewType,
             handedness: Handedness,
             club: GolfClub? = nil,
             profile: ModelProProfile,
             context: ModelContext) async {
        do {
            let extractor = VideoPoseExtractor()

            // Pass 2: full frame rate, across the whole clip. No frame cap —
            // a long clip is the golfer's own call to trim (see doc comment
            // above), not something this pipeline second-guesses by capping
            // silently.
            stage = .extractingPoses(0)
            let extraction = try await extractor.extractPoses(
                from: videoURL,
                options: .init(timeRange: nil, minimumSampleInterval: 0, maximumFrames: .max)
            ) { fraction in
                Task { @MainActor [weak self] in
                    if case .extractingPoses = self?.stage {
                        self?.stage = .extractingPoses(fraction)
                    }
                }
            }
            var frames = extraction.frames

            guard extraction.looksUpright else { throw PipelineFailure.notUpright }

            stage = .detectingPositions
            let positions = PositionDetector.detectPositions(frames: frames,
                                                             shotType: shotType,
                                                             space: extraction.space)
            guard !positions.isEmpty else { throw PipelineFailure.noPositions }

            // Measure true rotation with 3D pose, but only on the key frames —
            // the 3D request is far too heavy to run on every frame.
            stage = .measuringRotation
            let keyTimes = positions.map(\.time)
            let measurements = await Pose3DExtractor().measure(url: videoURL, at: keyTimes)
            if !measurements.isEmpty {
                let turns = Pose3DExtractor.turns(from: measurements)
                for detected in positions {
                    guard frames.indices.contains(detected.frameIndex) else { continue }
                    // Match on the nearest measured time.
                    if let match = turns.min(by: {
                        abs($0.key - detected.time) < abs($1.key - detected.time)
                    }), abs(match.key - detected.time) < 0.05 {
                        frames[detected.frameIndex].turn3D = match.value
                    }
                }
            }

            stage = .scoring
            let (metrics, overall) = SwingAnalyzer.analyze(frames: frames,
                                                           positions: positions,
                                                           profile: profile,
                                                           shotType: shotType,
                                                           view: view,
                                                           handedness: handedness,
                                                           space: extraction.space,
                                                           club: club)

            let faults = FaultDetector.detect(context: .init(
                frames: frames,
                positions: positions,
                space: extraction.space,
                handedness: handedness,
                view: view,
                frameRate: extraction.frameRate,
                ballOverride: nil))

            stage = .coaching
            let coachingText = await Coach.coaching(for: metrics, faults: faults,
                                                    shotResult: .unknown, shotType: shotType,
                                                    view: view, overallScore: overall,
                                                    frameRate: extraction.frameRate)

            // No `window` — the whole clip was analyzed, so `duration` and
            // `sourceDuration` describe the same span. `sourceDuration` is
            // still stored (rather than left to default from `duration`)
            // because `preflight.coarseDuration` comes from the container's
            // own metadata, not from re-deriving it out of the extracted
            // frame count, keeping one honest source for "how long is this
            // clip" that doesn't drift if extraction ever drops frames.
            let analysis = SwingAnalysis(frames: frames,
                                         positions: positions,
                                         metrics: metrics,
                                         overallScore: overall,
                                         frameRate: extraction.frameRate,
                                         duration: extraction.duration,
                                         space: extraction.space,
                                         sourceDuration: preflight.coarseDuration,
                                         faults: faults)

            // Move the video into the library and snapshot a thumbnail.
            let fileName = try VideoStore.store(videoAt: videoURL)
            let thumbnail = await Self.thumbnailData(videoURL: VideoStore.url(for: fileName),
                                                     at: positions.first { $0.position == .impact }?.time ?? 0)

            let record = SwingRecord(videoFileName: fileName,
                                     viewType: view,
                                     handedness: handedness,
                                     shotType: shotType,
                                     overallScore: overall,
                                     thumbnailData: thumbnail,
                                     analysis: analysis,
                                     coachingText: coachingText)
            record.club = club
            context.insert(record)
            try? context.save()

            finishedRecord = record
            stage = .done
            Haptics.success()
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Entry point for Practice mode: `LivePracticeSession`'s
    /// `StreamingSwingDetector` already knows the window (no coarse re-scan
    /// needed, unlike `run`'s `preflight`), so this goes straight to pass-2
    /// extraction and everything after it — the exact same steps `run` and
    /// `reextract` both use, never a third copy of them. `sourceDuration`
    /// is the whole session recording's length at the moment this is
    /// called, mirroring what `run` stores from `preflight.coarseDuration`.
    func runLive(videoURL: URL,
                window: ClosedRange<Double>,
                sourceDuration: Double,
                shotType: ShotType,
                view: CameraViewType,
                handedness: Handedness,
                club: GolfClub?,
                profile: ModelProProfile,
                context: ModelContext) async {
        do {
            let extractor = VideoPoseExtractor()
            stage = .extractingPoses(0)
            let extraction = try await extractor.extractPoses(
                from: videoURL,
                options: .init(timeRange: window, minimumSampleInterval: 0, maximumFrames: .max)
            ) { fraction in
                Task { @MainActor [weak self] in
                    if case .extractingPoses = self?.stage {
                        self?.stage = .extractingPoses(fraction)
                    }
                }
            }
            var frames = extraction.frames

            guard extraction.looksUpright else { throw PipelineFailure.notUpright }

            stage = .detectingPositions
            let positions = PositionDetector.detectPositions(frames: frames,
                                                             shotType: shotType,
                                                             space: extraction.space)
            guard !positions.isEmpty else { throw PipelineFailure.noPositions }

            stage = .measuringRotation
            let keyTimes = positions.map(\.time)
            let measurements = await Pose3DExtractor().measure(url: videoURL, at: keyTimes)
            if !measurements.isEmpty {
                let turns = Pose3DExtractor.turns(from: measurements)
                for detected in positions {
                    guard frames.indices.contains(detected.frameIndex) else { continue }
                    if let match = turns.min(by: {
                        abs($0.key - detected.time) < abs($1.key - detected.time)
                    }), abs(match.key - detected.time) < 0.05 {
                        frames[detected.frameIndex].turn3D = match.value
                    }
                }
            }

            stage = .scoring
            let (metrics, overall) = SwingAnalyzer.analyze(frames: frames,
                                                           positions: positions,
                                                           profile: profile,
                                                           shotType: shotType,
                                                           view: view,
                                                           handedness: handedness,
                                                           space: extraction.space,
                                                           club: club)

            let faults = FaultDetector.detect(context: .init(
                frames: frames,
                positions: positions,
                space: extraction.space,
                handedness: handedness,
                view: view,
                frameRate: extraction.frameRate,
                ballOverride: nil))

            stage = .coaching
            let coachingText = await Coach.coaching(for: metrics, faults: faults,
                                                    shotResult: .unknown, shotType: shotType,
                                                    view: view, overallScore: overall,
                                                    frameRate: extraction.frameRate)

            let analysis = SwingAnalysis(frames: frames,
                                         positions: positions,
                                         metrics: metrics,
                                         overallScore: overall,
                                         frameRate: extraction.frameRate,
                                         duration: extraction.duration,
                                         space: extraction.space,
                                         window: window,
                                         sourceDuration: sourceDuration,
                                         faults: faults)

            let fileName = try VideoStore.store(videoAt: videoURL)
            let thumbnail = await Self.thumbnailData(videoURL: VideoStore.url(for: fileName),
                                                     at: positions.first { $0.position == .impact }?.time ?? 0)

            let record = SwingRecord(videoFileName: fileName,
                                     viewType: view,
                                     handedness: handedness,
                                     shotType: shotType,
                                     overallScore: overall,
                                     thumbnailData: thumbnail,
                                     analysis: analysis,
                                     coachingText: coachingText)
            record.club = club
            context.insert(record)
            try? context.save()

            finishedRecord = record
            stage = .done
            Haptics.success()
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Re-runs pose extraction across a NEW time window on an already-stored
    /// swing, for when auto-detection picked the wrong boundary — cutting
    /// off the start of the backswing, or including too much standing
    /// around. This is real work, not a cheap operation: unlike
    /// `SwingRescorer` (which only re-scores frames already extracted),
    /// re-detecting the window means re-decoding the video and re-running
    /// Vision across it.
    ///
    /// Everything after extraction — scoring, faults, coaching, persisting
    /// — routes through `SwingRescorer`, the one path for that, rather than
    /// a second copy of it living here. The frames/positions handed to it
    /// are real; only the metrics/faults/score are placeholders, immediately
    /// overwritten by the real ones `SwingRescorer` computes.
    func reextract(record: SwingRecord,
                   window: ClosedRange<Double>,
                   sourceDuration: Double,
                   view: CameraViewType,
                   shotType: ShotType,
                   club: GolfClub?,
                   profile: ModelProProfile,
                   context: ModelContext) async {
        do {
            let extractor = VideoPoseExtractor()
            stage = .extractingPoses(0)
            let extraction = try await extractor.extractPoses(
                from: record.videoURL,
                options: .init(timeRange: window, minimumSampleInterval: 0, maximumFrames: .max)
            ) { fraction in
                Task { @MainActor [weak self] in
                    if case .extractingPoses = self?.stage {
                        self?.stage = .extractingPoses(fraction)
                    }
                }
            }
            var frames = extraction.frames

            guard extraction.looksUpright else { throw PipelineFailure.notUpright }

            stage = .detectingPositions
            let positions = PositionDetector.detectPositions(frames: frames,
                                                             shotType: shotType,
                                                             space: extraction.space)
            guard !positions.isEmpty else { throw PipelineFailure.noPositions }

            stage = .measuringRotation
            let keyTimes = positions.map(\.time)
            let measurements = await Pose3DExtractor().measure(url: record.videoURL, at: keyTimes)
            if !measurements.isEmpty {
                let turns = Pose3DExtractor.turns(from: measurements)
                for detected in positions {
                    guard frames.indices.contains(detected.frameIndex) else { continue }
                    if let match = turns.min(by: {
                        abs($0.key - detected.time) < abs($1.key - detected.time)
                    }), abs(match.key - detected.time) < 0.05 {
                        frames[detected.frameIndex].turn3D = match.value
                    }
                }
            }

            stage = .scoring
            let bareAnalysis = SwingAnalysis(frames: frames,
                                             positions: positions,
                                             metrics: [],
                                             overallScore: 0,
                                             frameRate: extraction.frameRate,
                                             duration: extraction.duration,
                                             space: extraction.space,
                                             window: window,
                                             sourceDuration: sourceDuration,
                                             faults: nil)
            await SwingRescorer.rescore(record: record,
                                        analysis: bareAnalysis,
                                        view: view,
                                        shotType: shotType,
                                        club: club,
                                        profile: profile,
                                        context: context)

            stage = .done
            Haptics.success()
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    static func thumbnailData(videoURL: URL, at time: Double) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let result = try? await generator.image(at: cmTime) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.7)
    }
}

/// Loads full-resolution still frames from a stored video for the results
/// viewer, with a small in-memory cache.
@MainActor
final class FrameLoader: ObservableObject {
    private let generator: AVAssetImageGenerator
    // NSCache evicts the LEAST-recently-used entry as needed rather than
    // dumping everything at once — the old dictionary cleared its whole 40
    // entries the moment a 41st was added, which meant scrubbing through
    // AdjustFramesSheet's frame timeline (now uncapped — see `reextract`)
    // re-decoded from scratch over and over.
    private let cache: NSCache<NSNumber, UIImage> = {
        let c = NSCache<NSNumber, UIImage>()
        c.countLimit = 60
        return c
    }()

    init(videoURL: URL) {
        let asset = AVURLAsset(url: videoURL)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 240)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 240)
    }

    func image(at time: Double, cacheKey: Int) async -> UIImage? {
        let key = NSNumber(value: cacheKey)
        if let cached = cache.object(forKey: key) { return cached }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let result = try? await generator.image(at: cmTime) else { return nil }
        let image = UIImage(cgImage: result.image)
        cache.setObject(image, forKey: key)
        return image
    }
}
