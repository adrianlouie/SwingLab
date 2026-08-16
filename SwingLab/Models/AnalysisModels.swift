import Foundation

/// A body joint, decoupled from Vision's own types so the geometry and
/// detection layers stay pure Swift and unit-testable.
enum Joint: String, Codable, CaseIterable {
    case nose, neck
    case leftEye, rightEye, leftEar, rightEar
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case root // mid-hip
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

extension Joint {
    /// The limb connections used to draw a stick figure. Shared by the video
    /// overlay, the ModelPro ghost, and the pose editor so all three render
    /// the same body.
    static let skeletonBones: [(Joint, Joint)] = [
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    /// The same joint on the other side of the body. Mirroring a pose has to
    /// swap these identities, not just the coordinates: a mirrored right
    /// shoulder *is* a left shoulder, and code that picks a side by handedness
    /// (the swing-plane line, for one) reads the wrong joint otherwise.
    var mirrored: Joint {
        switch self {
        case .leftEye: return .rightEye
        case .rightEye: return .leftEye
        case .leftEar: return .rightEar
        case .rightEar: return .leftEar
        case .leftShoulder: return .rightShoulder
        case .rightShoulder: return .leftShoulder
        case .leftElbow: return .rightElbow
        case .rightElbow: return .leftElbow
        case .leftWrist: return .rightWrist
        case .rightWrist: return .leftWrist
        case .leftHip: return .rightHip
        case .rightHip: return .leftHip
        case .leftKnee: return .rightKnee
        case .rightKnee: return .leftKnee
        case .leftAnkle: return .rightAnkle
        case .rightAnkle: return .leftAnkle
        case .nose, .neck, .root: return self
        }
    }

    /// Face landmarks, used to fit the head circle. Vision tracks these but the
    /// app originally ignored them and guessed a head size from the nose.
    static let faceJoints: [Joint] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]

    /// Joints the pose editor lets you drag. The face landmarks move with the
    /// head rather than being posed individually.
    static var draggableJoints: [Joint] {
        allCases.filter { !faceJoints.contains($0) || $0 == .nose }
    }

    var displayName: String {
        switch self {
        case .nose: return "Head"
        case .leftEye: return "Left eye"
        case .rightEye: return "Right eye"
        case .leftEar: return "Left ear"
        case .rightEar: return "Right ear"
        case .neck: return "Neck"
        case .leftShoulder: return "Left shoulder"
        case .rightShoulder: return "Right shoulder"
        case .leftElbow: return "Left elbow"
        case .rightElbow: return "Right elbow"
        case .leftWrist: return "Left hand"
        case .rightWrist: return "Right hand"
        case .root: return "Hips"
        case .leftHip: return "Left hip"
        case .rightHip: return "Right hip"
        case .leftKnee: return "Left knee"
        case .rightKnee: return "Right knee"
        case .leftAnkle: return "Left ankle"
        case .rightAnkle: return "Right ankle"
        }
    }
}

/// A single joint location in normalized image coordinates.
/// Origin is bottom-left (Vision's convention); x and y are 0...1.
struct JointPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var confidence: Double
}

/// Rotation measured directly from Apple's 3D body pose, rather than inferred
/// from how narrow the shoulders look on a flat image. Only populated on the
/// key frames, since the 3D request is far heavier than the 2D one.
struct BodyTurn3D: Codable, Equatable {
    var shoulderTurn: Double
    var hipTurn: Double
    var spineTilt: Double

    var xFactor: Double { shoulderTurn - hipTurn }

    /// `hipTurn`, but `nil` when it reads suspiciously close to exactly
    /// zero — confirmed against real footage that Apple's 3D body-pose
    /// hip-axis estimate can land on a near-frozen value across an entire
    /// swing (`(-1.0000, 0.0000)` at every single key frame, address
    /// through finish, to 4 decimal places — not real-world noise around a
    /// genuinely small hip turn). `VNHumanBodyPose3DObservation` exposes no
    /// per-joint confidence to gate on directly (`VNHumanBodyRecognizedPoint3D`
    /// has no `.confidence` property, confirmed against the SDK), so this is
    /// the only signal available: treat a too-good-to-be-true flat zero as
    /// "don't trust this," not "hips didn't move," and let callers fall back
    /// to the 2D estimate instead. `SwingAnalyzer`/`.xFactor` both read this,
    /// not `hipTurn` directly, so the guard can't be bypassed by one call
    /// site and not the other. See `CLAUDE.md` "reliableHipTurn".
    var reliableHipTurn: Double? { hipTurn > 1.0 ? hipTurn : nil }
}

/// The full detected pose for one video frame.
struct PoseFrame: Codable {
    var time: Double // seconds from the start of the video
    var joints: [Joint: JointPoint]
    /// Present only on key frames where the 3D pose request succeeded.
    var turn3D: BodyTurn3D?

    init(time: Double, joints: [Joint: JointPoint], turn3D: BodyTurn3D? = nil) {
        self.time = time
        self.joints = joints
        self.turn3D = turn3D
    }

    subscript(_ joint: Joint) -> JointPoint? {
        joints[joint]
    }

    /// Midpoint of both wrists — our proxy for the hands/club position.
    ///
    /// Falls back to a single wrist, which is convenient for drawing but wrong
    /// for motion analysis: when one wrist drops out the "hands" jump by half a
    /// wrist separation in a single frame, which reads as an enormous speed
    /// spike. Detection code uses `handsCenter(minConfidence:)` instead.
    var handsCenter: JointPoint? {
        guard let l = joints[.leftWrist], let r = joints[.rightWrist] else {
            return joints[.leftWrist] ?? joints[.rightWrist]
        }
        return JointPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2,
                          confidence: min(l.confidence, r.confidence))
    }

    /// Strict hands position: nil unless *both* wrists are confidently tracked,
    /// so a dropout becomes a gap to interpolate rather than a phantom jump.
    func handsCenter(minConfidence: Double) -> JointPoint? {
        guard let l = joints[.leftWrist], let r = joints[.rightWrist],
              l.confidence >= minConfidence, r.confidence >= minConfidence else { return nil }
        return JointPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2,
                          confidence: min(l.confidence, r.confidence))
    }

    /// Centre and radius of the head, fitted to whichever face landmarks are
    /// visible. Ear-to-ear spans the head width; in profile only one ear shows,
    /// so ear-to-nose approximates the depth instead.
    ///
    /// The centre is in normalized image coordinates; the radius is a fraction
    /// of image *height*, so drawing code scales it by the height alone and
    /// gets a real circle rather than an ellipse.
    func headCircle(space: PoseSpace = .square) -> (center: JointPoint, radius: Double)? {
        let face = Joint.faceJoints.compactMap { joints[$0] }.filter { $0.confidence > 0.2 }
        guard !face.isEmpty, let neck = joints[.neck], neck.confidence > 0.2 else { return nil }

        var cx = face.map(\.x).reduce(0, +) / Double(face.count)
        var cy = face.map(\.y).reduce(0, +) / Double(face.count)

        let leftEar = joints[.leftEar].flatMap { $0.confidence > 0.2 ? $0 : nil }
        let rightEar = joints[.rightEar].flatMap { $0.confidence > 0.2 ? $0 : nil }
        let nose = joints[.nose].flatMap { $0.confidence > 0.2 ? $0 : nil }

        var radius: Double
        if let l = leftEar, let r = rightEar {
            radius = SwingGeometry.distance(l, r, space: space) * 0.75
        } else if let ear = leftEar ?? rightEar, let nose {
            radius = SwingGeometry.distance(ear, nose, space: space) * 0.85
        } else if let nose {
            radius = SwingGeometry.distance(nose, neck, space: space) * 0.70
        } else {
            return nil
        }
        guard radius > 0.0001 else { return nil }

        // Nudge off the face toward the skull centre, away from the neck.
        let dx = space.isoX(cx - neck.x)
        let dy = cy - neck.y
        let d = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        cx += space.denormX(dx / d * radius * 0.35)
        cy += dy / d * radius * 0.35

        return (JointPoint(x: cx, y: cy, confidence: face.map(\.confidence).max() ?? 0), radius)
    }
}

/// A key swing position matched to a specific frame of the video.
struct DetectedPosition: Codable, Identifiable {
    var position: SwingPosition
    var frameIndex: Int
    var time: Double
    /// How sure the detector is, 0...1. Optional so records saved before this
    /// existed still decode.
    var storedConfidence: Double?

    var id: String { position.rawValue }

    var confidence: Double { storedConfidence ?? 1.0 }

    /// Worth prompting the user to check and nudge this one.
    var isUncertain: Bool { confidence < 0.6 }

    init(position: SwingPosition, frameIndex: Int, time: Double, confidence: Double = 1.0) {
        self.position = position
        self.frameIndex = frameIndex
        self.time = time
        self.storedConfidence = confidence
    }
}

enum MetricStatus: String, Codable {
    case good
    case needsWork
}

/// One measurement scored against its ideal range.
struct MetricResult: Codable, Identifiable {
    var kind: MetricKind
    var position: SwingPosition
    var measured: Double
    var idealLow: Double
    var idealHigh: Double
    var weight: Double

    var id: String { "\(kind.rawValue)@\(position.rawValue)" }

    var status: MetricStatus {
        (measured >= idealLow && measured <= idealHigh) ? .good : .needsWork
    }

    /// 0–100. Full marks inside the ideal range, falling off linearly with
    /// distance outside it (one full range-width outside = 0).
    var score: Double {
        if status == .good { return 100 }
        let width = max(idealHigh - idealLow, 0.001)
        let distance = measured < idealLow ? (idealLow - measured) : (measured - idealHigh)
        return max(0, 100 - (distance / width) * 100)
    }

    /// Signed distance outside the ideal range (0 when inside).
    var delta: Double {
        if measured < idealLow { return measured - idealLow }
        if measured > idealHigh { return measured - idealHigh }
        return 0
    }
}

/// Everything the analysis pipeline produced for one swing. Stored as a
/// single Codable blob on the SwiftData record.
///
/// IMPORTANT for anyone adding a field: Swift's synthesized decoder throws on a
/// missing key *even when the property has a default value*, and
/// `SwingRecord.analysis` decodes with `try?`. A non-optional new field would
/// therefore turn every previously saved swing into "No analysis data" with no
/// error anywhere. New fields must be optional (with a computed accessor
/// supplying the default), exactly as `storedSpace` and `window` are here.
struct SwingAnalysis: Codable {
    var frames: [PoseFrame]
    var positions: [DetectedPosition]
    var metrics: [MetricResult]
    var overallScore: Double
    var frameRate: Double
    var duration: Double

    /// Coordinate space the frames were measured in. Absent on records saved
    /// before the anisotropy fix — those were measured in square space.
    var storedSpace: PoseSpace?
    /// Sub-range of the source clip these frames cover, for long videos
    /// containing more than one swing.
    var windowStart: Double?
    var windowEnd: Double?
    /// Full duration of the source clip, which `duration` no longer equals once
    /// only a window is stored.
    var sourceDuration: Double?
    /// Named diagnoses. Optional for the same decoding reason as the rest.
    var storedFaults: [SwingFault]?

    var faults: [SwingFault] { storedFaults ?? [] }

    var space: PoseSpace { storedSpace ?? .square }

    var window: ClosedRange<Double>? {
        guard let start = windowStart, let end = windowEnd, end > start else { return nil }
        return start...end
    }

    init(frames: [PoseFrame],
         positions: [DetectedPosition],
         metrics: [MetricResult],
         overallScore: Double,
         frameRate: Double,
         duration: Double,
         space: PoseSpace? = nil,
         window: ClosedRange<Double>? = nil,
         sourceDuration: Double? = nil,
         faults: [SwingFault]? = nil) {
        self.frames = frames
        self.positions = positions
        self.metrics = metrics
        self.overallScore = overallScore
        self.frameRate = frameRate
        self.duration = duration
        self.storedSpace = space
        self.windowStart = window?.lowerBound
        self.windowEnd = window?.upperBound
        self.sourceDuration = sourceDuration
        self.storedFaults = faults
    }

    func frame(for position: SwingPosition) -> PoseFrame? {
        guard let detected = positions.first(where: { $0.position == position }),
              frames.indices.contains(detected.frameIndex) else { return nil }
        return frames[detected.frameIndex]
    }

    func detected(for position: SwingPosition) -> DetectedPosition? {
        positions.first { $0.position == position }
    }

    /// Time range worth playing back, in the source clip's own timeline
    /// (`PoseFrame.time` is a presentation timestamp against the original
    /// asset, so this lines up directly with `AVPlayer` seeks on that file —
    /// no window-relative math needed).
    ///
    /// Deliberately NOT `window`: the scanner window can carry several
    /// seconds of standing around before/after the swing, and `window` is nil
    /// on every record saved before it existed. Deriving from the detected
    /// address/finish positions instead is correct on old and new records
    /// alike, with no migration.
    var playbackRange: ClosedRange<Double> {
        let lo = frames.first?.time ?? 0
        let hi = max(frames.last?.time ?? duration, lo)
        guard let address = detected(for: .address), let finish = detected(for: .finish) else {
            return lo...hi
        }
        let start = max(lo, address.time - 0.35)
        let end = min(hi, finish.time + 0.5)
        guard end > start else { return lo...hi }
        return start...end
    }
}
