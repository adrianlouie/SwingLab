import Foundation
import AVFoundation
import Vision

enum PoseExtractionError: LocalizedError {
    case noVideoTrack
    case cannotReadVideo(underlying: String?)
    case noPersonDetected

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That file doesn't contain a video track."
        case .cannotReadVideo(let underlying):
            let base = "The video couldn't be read. Try re-exporting or re-recording it."
            guard let underlying, !underlying.isEmpty else { return base }
            return base + " (\(underlying))"
        case .noPersonDetected:
            return "No golfer was detected in the video. Make sure your full body is visible and well lit, filmed from about 10–15 feet away."
        }
    }
}

/// Runs Apple Vision body-pose detection across every frame of a video,
/// entirely on-device.
struct VideoPoseExtractor {

    /// Maps Vision's joint names onto our pure-Swift `Joint` enum.
    private static let jointMap: [VNHumanBodyPoseObservation.JointName: Joint] = [
        .nose: .nose, .neck: .neck,
        .leftEye: .leftEye, .rightEye: .rightEye,
        .leftEar: .leftEar, .rightEar: .rightEar,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .root: .root,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    /// How much of a clip to analyse, and how densely.
    struct Options {
        /// Restrict analysis to this slice of the clip.
        var timeRange: ClosedRange<Double>?
        /// Minimum gap between analysed frames. 0 analyses every frame; a
        /// coarse scan uses something like 1/12s to skim a long clip cheaply.
        var minimumSampleInterval: Double = 0
        /// Hard ceiling on analysed frames, so a long slow-motion clip can't
        /// run for minutes or bloat the stored blob.
        var maximumFrames: Int = 3000

        static let dense = Options()
        static func coarse(sampleHz: Double) -> Options {
            Options(timeRange: nil, minimumSampleInterval: 1.0 / sampleHz, maximumFrames: 1200)
        }
    }

    /// Extracts pose frames from the video at `url`. Reports progress 0...1.
    func extractPoses(from url: URL,
                      options: Options = .dense,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> PoseExtractionResult {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw PoseExtractionError.noVideoTrack }

        let orientation = try await VideoOrientation.load(from: track)
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)

        var frames: [PoseFrame] = []
        var truncated = false
        var lastReportedProgress = 0.0

        // Real phone footage is sometimes partly corrupt — one of the sample
        // clips decodes fine for 22s of its 27s and then reports "Cannot
        // Decode" forever. Losing the whole analysis over a damaged tail would
        // be the wrong call, so read what we can, then try once to pick up
        // past the bad patch.
        let rangeStart = options.timeRange?.lowerBound ?? 0
        let rangeEnd = options.timeRange?.upperBound ?? duration
        var startTime = CMTime(seconds: rangeStart, preferredTimescale: 600)
        var attempts = 0
        var lastKeptTime = -Double.infinity

        while attempts < 2 {
            attempts += 1
            let outcome = try await readSegment(asset: asset,
                                                track: track,
                                                orientation: orientation,
                                                from: startTime,
                                                endTime: rangeEnd,
                                                duration: duration,
                                                rangeStart: rangeStart,
                                                rangeEnd: rangeEnd,
                                                options: options,
                                                lastKeptTime: &lastKeptTime,
                                                frameCount: frames.count,
                                                lastReportedProgress: &lastReportedProgress,
                                                progress: progress) { frame in
                frames.append(frame)
            }

            guard case .failed = outcome else { break }
            truncated = true
            guard let lastTime = frames.last?.time,
                  rangeEnd - lastTime > 1.0 else { break }
            // Skip half a second past the failure and try to resume.
            startTime = CMTime(seconds: lastTime + 0.5, preferredTimescale: 600)
        }

        guard !frames.isEmpty else {
            throw PoseExtractionError.cannotReadVideo(underlying: "no frames could be decoded")
        }
        let detectedAny = frames.contains { $0.joints.count >= 6 }
        guard detectedAny else { throw PoseExtractionError.noPersonDetected }

        return PoseExtractionResult(frames: frames,
                                    frameRate: Self.effectiveFrameRate(of: frames),
                                    duration: duration,
                                    space: PoseSpace(aspect: orientation.aspect),
                                    orientation: orientation,
                                    truncated: truncated)
    }

    /// Runs Vision body-pose detection on one already-decoded pixel buffer.
    /// The one place this happens — both the batch file reader above and
    /// `LivePracticeSession`'s live capture delegate call this, rather than
    /// each running its own `VNDetectHumanBodyPoseRequest`, which is exactly
    /// the kind of duplication that let the offline/live signal math drift
    /// apart before `PoseKinematics` was pulled out for the same reason.
    static func poseFrame(from pixelBuffer: CVPixelBuffer, time: Double,
                          cgOrientation: CGImagePropertyOrientation) -> PoseFrame {
        let request = VNDetectHumanBodyPoseRequest()
        // Telling Vision the orientation makes it detect on an upright
        // golfer AND return coordinates in the oriented image's space — the
        // same space the displayed still frame (or live preview) lives in.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: cgOrientation,
                                            options: [:])
        try? handler.perform([request])

        var joints: [Joint: JointPoint] = [:]
        if let observation = request.results?.first,
           let recognized = try? observation.recognizedPoints(.all) {
            for (visionName, joint) in Self.jointMap {
                if let point = recognized[visionName], point.confidence > 0.1 {
                    joints[joint] = JointPoint(x: Double(point.location.x),
                                               y: Double(point.location.y),
                                               confidence: Double(point.confidence))
                }
            }
        }
        return PoseFrame(time: time, joints: joints)
    }

    private enum SegmentOutcome { case completed, failed }

    /// Decodes one contiguous stretch, running pose detection per frame.
    /// Returns `.failed` when the decoder gives up partway.
    private func readSegment(asset: AVURLAsset,
                             track: AVAssetTrack,
                             orientation: VideoOrientation,
                             from startTime: CMTime,
                             endTime: Double,
                             duration: Double,
                             rangeStart: Double,
                             rangeEnd: Double,
                             options: Options,
                             lastKeptTime: inout Double,
                             frameCount: Int,
                             lastReportedProgress: inout Double,
                             progress: @escaping @Sendable (Double) -> Void,
                             emit: (PoseFrame) -> Void) async throws -> SegmentOutcome {
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw PoseExtractionError.cannotReadVideo(underlying: nil)
        }
        if startTime > .zero || endTime < duration {
            let end = CMTime(seconds: min(endTime, duration), preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: startTime, end: max(end, startTime))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        // Must stay true: with it false the reader vends buffers from a shared
        // pool, and holding each one for the ~10ms Vision takes can starve the
        // decoder.
        output.alwaysCopiesSampleData = true
        reader.add(output)
        guard reader.startReading() else {
            throw PoseExtractionError.cannotReadVideo(underlying: reader.error?.localizedDescription)
        }

        var kept = frameCount

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

            if time > rangeEnd { break }
            guard kept < options.maximumFrames else { break }
            // Decoding is cheap; Vision is not. Skipping the pose request on
            // unwanted frames is what makes the coarse scan fast.
            if options.minimumSampleInterval > 0,
               time - lastKeptTime < options.minimumSampleInterval {
                continue
            }
            lastKeptTime = time
            kept += 1

            emit(Self.poseFrame(from: pixelBuffer, time: time, cgOrientation: orientation.cgOrientation))

            // Throttle progress: reporting every frame spawned thousands of
            // MainActor hops on a long clip.
            let span = max(rangeEnd - rangeStart, 0.0001)
            let fraction = min(1.0, max(0, (time - rangeStart) / span))
            if fraction - lastReportedProgress >= 0.01 {
                lastReportedProgress = fraction
                progress(fraction)
            }
        }

        return reader.status == .failed ? .failed : .completed
    }

    /// Frame rate from the median gap between frames. `nominalFrameRate` is
    /// unreliable — one of the sample clips reports 29.888 for 30fps footage,
    /// and it is meaningless for variable-rate or slow-motion video.
    static func effectiveFrameRate(of frames: [PoseFrame]) -> Double {
        guard frames.count > 2 else { return 30 }
        var deltas: [Double] = []
        deltas.reserveCapacity(frames.count - 1)
        for i in 1..<frames.count {
            let dt = frames[i].time - frames[i - 1].time
            if dt > 0 { deltas.append(dt) }
        }
        guard !deltas.isEmpty else { return 30 }
        deltas.sort()
        let median = deltas[deltas.count / 2]
        guard median > 0 else { return 30 }
        return (1.0 / median).rounded()
    }
}

/// Everything the extractor learned about a clip, kept together so callers
/// can't accidentally analyse points without knowing their coordinate space.
struct PoseExtractionResult {
    var frames: [PoseFrame]
    var frameRate: Double
    var duration: Double
    var space: PoseSpace
    var orientation: VideoOrientation
    /// The clip was damaged and only decoded partway.
    var truncated: Bool = false

    /// True when the detected poses look like an upright person. A low score
    /// means the orientation is wrong and the numbers should not be trusted.
    var looksUpright: Bool {
        guard let score = UprightnessCheck.meanScore(frames) else { return true }
        return score >= UprightnessCheck.threshold
    }

    /// How much of the clip we actually got, 0...1.
    var coverage: Double {
        guard duration > 0, let last = frames.last?.time else { return 0 }
        return min(1.0, last / duration)
    }
}
