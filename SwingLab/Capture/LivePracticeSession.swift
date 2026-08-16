import Foundation
import AVFoundation
import SwiftData
import UIKit

/// Drives Practice mode: a live camera preview that watches for a swing to
/// finish on its own, analyzes just that window through the same pipeline
/// recorded/imported clips use, and speaks the result.
///
/// **Recording model, simplified from the original plan on purpose.** The
/// plan called for rotating into a new file every ~12s to avoid one
/// ever-growing recording, stitching across segment boundaries when a swing
/// straddled one. That's real complexity (an `AVMutableComposition` stitch,
/// a restart-boundary race) for a problem a typical practice session doesn't
/// actually have: `AnalysisPipeline.runLive` already extracts just a
/// sub-range of a longer file via `VideoPoseExtractor`'s existing
/// `timeRange` option, the same mechanism every recorded/imported clip goes
/// through. So this records **one continuous file for the whole session**
/// and lets that mechanism pull out only the detected window — no rotation,
/// no stitching, no restart-boundary gap risk. The cost is disk space for a
/// single ongoing recording, which is small next to the risk being removed.
///
/// **Orientation is fixed to portrait.** Locking this down (rather than
/// tracking interface rotation live) matches how the reference app's own
/// screenshots are all portrait, and keeps the orientation math a known
/// constant (`.right`, the same mapping `VideoOrientation`'s doc comment
/// already establishes for a back-camera 90°-rotated capture) instead of a
/// live-tracked variable. Practice mode simply doesn't support rotating the
/// phone mid-session in this first version.
///
/// **Needs a real device to verify at all** — live capture, live Vision
/// sampling, and the timestamp alignment between the live sample-buffer
/// clock and the recorded file's internal clock (see `recordingStartPTS`)
/// cannot be exercised in Simulator.
@MainActor
@Observable
final class LivePracticeSession: NSObject {

    enum State: Equatable {
        case idle
        case requestingAccess
        case denied
        case failed(String)
        /// Session running, watching for a swing.
        case watching
        /// A swing was detected; running it through the real pipeline.
        case analyzing
        /// Just spoke a result; briefly shown before returning to `.watching`.
        case spoke(String)
    }

    private(set) var state: State = .idle
    private(set) var activeFrameRate: Double = 0

    // `nonisolated` on purpose: these are the objects `configureAndStart`/
    // `configureHighestFrameRate` (also `nonisolated`, below) and `stop`'s
    // background-queue closure all need to touch off the main actor —
    // exactly the AVFoundation-documented pattern of driving a capture
    // session from its own serial queue, never the main thread. Without
    // this, the compiler correctly points out that a `@MainActor` class's
    // properties are isolated by default regardless of the object's own
    // thread-safety, which — before this fix — was silently bouncing all
    // of `configureAndStart`'s "background" work back onto the main thread
    // through an implicit actor hop. Not just a warning: that defeated the
    // whole point of `sessionQueue`.
    nonisolated let session = AVCaptureSession()
    private nonisolated let movieOutput = AVCaptureMovieFileOutput()
    private nonisolated let videoDataOutput = AVCaptureVideoDataOutput()
    private nonisolated let sessionQueue = DispatchQueue(label: "swinglab.practice.session")
    private nonisolated let sampleQueue = DispatchQueue(label: "swinglab.practice.sample")

    private var detector: StreamingSwingDetector?
    private var eventTask: Task<Void, Never>?
    private var recordingURL: URL?
    /// The live sample-buffer clock's presentation time at the moment
    /// `movieOutput` started actually recording — subtracted from every
    /// later sample so times fed to `StreamingSwingDetector`, and later
    /// handed to `AnalysisPipeline.runLive`, line up with the recorded
    /// file's own internal (0-based) timeline. Best-effort: set from the
    /// first live sample observed once `movieOutput.isRecording` reads
    /// true, which can lag the true recording start by a frame or two —
    /// harmless for swing-window detection, but exactly the kind of detail
    /// that needs confirming against a real recorded file, not assumed.
    private var recordingStartPTS: CMTime?
    private var orientedSize = CGSize(width: 1080, height: 1920)
    private var poseSpace: PoseSpace { PoseSpace(aspect: orientedSize.width / orientedSize.height) }

    private var lastSampleTime: CMTime?
    /// ~12Hz — matches the coarse scan rate the rest of the app already
    /// uses (`VideoPoseExtractor.Options.coarse`), which is plenty to
    /// resolve lift/energy shape without taxing the device running Vision
    /// continuously alongside an active recording.
    private let sampleInterval = CMTime(value: 1, timescale: 12)

    private let announcer = PracticeAnnouncer()
    private let profile: ModelProProfile
    private let context: ModelContext
    private let pipeline = AnalysisPipeline()

    var shotType: ShotType = .fullSwing
    var view: CameraViewType = .downTheLine
    var handedness: Handedness = .right
    var club: GolfClub?

    init(context: ModelContext, profile: ModelProProfile) {
        self.context = context
        self.profile = profile
    }

    func start() {
        guard state == .idle else { return }
        state = .requestingAccess
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else { self.state = .denied; return }
                self.sessionQueue.async { self.configureAndStart() }
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        let detector = detector
        self.detector = nil
        Task { await detector?.reset() }
        if movieOutput.isRecording { movieOutput.stopRecording() }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
        state = .idle
    }

    // MARK: - Session setup

    private nonisolated func configureAndStart() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in self.state = .failed("The back camera isn't available on this device.") }
            return
        }
        session.addInput(input)

        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        // Without this, a `.mov`'s header only finalizes when recording
        // stops, so `AnalysisPipeline.runLive` reading the file mid-session
        // (the whole point of the single-continuous-recording design above)
        // could hit an incomplete/unreadable asset. Periodic movie
        // fragments keep it readable up through the last-written fragment
        // throughout — the documented AVFoundation mechanism for exactly
        // this "read while still recording" case.
        movieOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }

        session.commitConfiguration()
        configureHighestFrameRate(device: device)

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        // Portrait-locked (see type doc comment): the sensor's native
        // landscape dimensions swap after the fixed `.right` rotation.
        let sensorSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        Task { @MainActor in self.orientedSize = CGSize(width: sensorSize.height, height: sensorSize.width) }

        session.startRunning()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("practice-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)

        Task { @MainActor in
            self.recordingURL = url
            self.recordingStartPTS = nil
            let detector = StreamingSwingDetector(space: self.poseSpace)
            self.detector = detector
            self.state = .watching
            self.eventTask = Task { [weak self] in
                let stream = await detector.events()
                for await event in stream {
                    guard let self else { return }
                    if case let .swingCompleted(window, _) = event {
                        await self.handleSwingCompleted(window: window)
                    }
                }
            }
        }
    }

    /// Same device-format search `CameraRecorder` uses, kept independent
    /// rather than shared — Practice mode's session is a different
    /// `AVCaptureSession` instance with its own lifecycle, and duplicating
    /// this small, stable search is lower-risk than threading a shared
    /// dependency between two otherwise-unrelated capture screens.
    private nonisolated func configureHighestFrameRate(device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestRate: Double = 0
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.height >= 720 else { continue }
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate > bestRate {
                bestRate = range.maxFrameRate
                bestFormat = format
            }
        }
        guard let format = bestFormat, bestRate > 30 else {
            Task { @MainActor in self.activeFrameRate = 30 }
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(bestRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            Task { @MainActor in self.activeFrameRate = bestRate }
        } catch {
            Task { @MainActor in self.activeFrameRate = 30 }
        }
    }

    // MARK: - Swing completion

    private func handleSwingCompleted(window: ClosedRange<Double>) async {
        guard state == .watching, let recordingURL else { return }
        state = .analyzing
        await pipeline.runLive(videoURL: recordingURL,
                               window: window,
                               sourceDuration: CMTimeGetSeconds(movieOutput.recordedDuration),
                               shotType: shotType,
                               view: view,
                               handedness: handedness,
                               club: club,
                               profile: profile,
                               context: context)

        if case .done = pipeline.stage, let record = pipeline.finishedRecord {
            pipeline.finishedRecord = nil
            let faults = record.analysis?.faults
            announcer.announce(faults: faults, overallScore: record.overallScore)
            state = .spoke(record.coachingText.isEmpty ? "Swing analyzed." : record.coachingText)
        } else if case .failed(let message) = pipeline.stage {
            // A swing that fails to analyze (e.g. body left frame, poor
            // light) shouldn't end the session — say so briefly and keep
            // watching, the same tolerant spirit as "Swing Not Detected?
            // Try These Tips" in the setup copy.
            announcer.speak("Couldn't read that one — try again.")
            state = .spoke(message)
        }

        // Briefly show the result, then resume watching.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard state != .idle else { return }
        state = .watching
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension LivePracticeSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        Task { @MainActor [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            if self.recordingStartPTS == nil { self.recordingStartPTS = pts }
            guard let startPTS = self.recordingStartPTS else { return }

            if let last = self.lastSampleTime, CMTimeSubtract(pts, last) < self.sampleInterval { return }
            self.lastSampleTime = pts

            let relativeTime = CMTimeGetSeconds(CMTimeSubtract(pts, startPTS))
            guard relativeTime >= 0 else { return }

            let frame = VideoPoseExtractor.poseFrame(from: pixelBuffer, time: relativeTime, cgOrientation: .right)
            await self.detector?.ingest(frame)
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension LivePracticeSession: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // Nothing to do — Practice mode reads the (still-growing, or now
        // finished) file directly by URL whenever a swing completes; there's
        // no per-recording completion handler to route through, unlike
        // `CameraRecorder`'s one-shot record-then-hand-off flow.
    }
}
