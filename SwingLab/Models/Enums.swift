import Foundation

/// Which direction the camera was facing when the swing was filmed.
enum CameraViewType: String, Codable, CaseIterable, Identifiable {
    case faceOn = "Face-On"
    case downTheLine = "Down-the-Line"

    var id: String { rawValue }

    var filmingTip: String {
        switch self {
        case .faceOn:
            return "Stand ~10–15 ft away, camera at hands height, facing your chest."
        case .downTheLine:
            return "Stand ~10–15 ft behind you, camera at hands height, looking down the target line."
        }
    }
}

enum Handedness: String, Codable, CaseIterable, Identifiable {
    case right = "Right-handed"
    case left = "Left-handed"

    var id: String { rawValue }
}

enum ShotType: String, Codable, CaseIterable, Identifiable {
    case fullSwing = "Full Swing"
    case pitch = "Pitch"
    case chip = "Chip"
    case putt = "Putt"

    var id: String { rawValue }

    /// Which key positions apply to this shot type. Short-game swings are
    /// shorter, so we track fewer checkpoints.
    var positions: [SwingPosition] {
        switch self {
        case .fullSwing:
            return [.address, .takeaway, .halfwayBack, .top, .transition, .delivery, .impact, .finish]
        case .pitch:
            return [.address, .halfwayBack, .top, .impact, .finish]
        case .chip, .putt:
            return [.address, .top, .impact, .finish]
        }
    }
}

/// The key checkpoints of the swing, in chronological order — the
/// position-by-position framework used by the ModelPro methodology.
enum SwingPosition: String, Codable, CaseIterable, Identifiable {
    case address = "Address"
    case takeaway = "Takeaway"
    case halfwayBack = "Halfway Back"
    case top = "Top"
    case transition = "Transition"
    case delivery = "Delivery"
    case impact = "Impact"
    case finish = "Finish"

    var id: String { rawValue }

    /// A short but still readable label for tight controls. Never an acronym —
    /// "HWB" and "DLV" meant nothing to anyone reading the screen.
    var shortLabel: String {
        switch self {
        case .address: return "Address"
        case .takeaway: return "Takeaway"
        case .halfwayBack: return "Halfway"
        case .top: return "Top"
        case .transition: return "Transition"
        case .delivery: return "Delivery"
        case .impact: return "Impact"
        case .finish: return "Finish"
        }
    }

    /// The five checkpoints that get their own jump-to button. The rest are
    /// still detected and reachable from the scrubber.
    static let primary: [SwingPosition] = [.address, .top, .delivery, .impact, .finish]

    var isPrimary: Bool { Self.primary.contains(self) }

    /// Plain-language description of what the checkpoint is, so the labels
    /// explain themselves.
    var explanation: String {
        switch self {
        case .address:
            return "Your setup, just before the club moves. Everything else is measured against this."
        case .takeaway:
            return "The first move back, with the club roughly parallel to the ground."
        case .halfwayBack:
            return "Lead arm parallel to the ground and the wrists fully set — the 'L' position."
        case .top:
            return "The end of the backswing, where the club changes direction."
        case .transition:
            return "The first move down, while the club is still finishing its backswing."
        case .delivery:
            return "Shaft parallel to the ground coming down — where the swing plane shows up most clearly."
        case .impact:
            return "The strike. Hands back to about their address height, moving fastest."
        case .finish:
            return "The end of the swing, balanced on your lead side."
        }
    }
}

/// Every measurement SwingLab knows how to take.
enum MetricKind: String, Codable, CaseIterable, Identifiable {
    case spineTilt = "Spine Angle"
    case postureChange = "Posture Change"
    case shoulderTurn = "Shoulder Turn"
    case hipTurn = "Hip Turn"
    case xFactor = "X-Factor"
    case headDrift = "Head Drift"
    case hipSway = "Hip Sway"
    /// Retired — `ModelProProfile` filters both of these out at read time
    /// (`retiredKinds`), so neither is ever scored, regardless of what a
    /// persisted profile from an earlier build still has seeded. Kept only
    /// so an already-stored `MetricResult` under either kind still decodes;
    /// deleting the case would throw on that whole `SwingAnalysis`.
    case planeDeviation = "Plane Deviation"
    case swingPath = "Swing Path"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .spineTilt, .postureChange, .shoulderTurn, .hipTurn, .xFactor, .swingPath:
            return "°"
        case .headDrift, .hipSway:
            return "in"
        case .planeDeviation:
            return "%"
        }
    }

    /// How wide the ideal window should be when targets are generated from a
    /// hand-posed figure, in this metric's own unit.
    var defaultTolerance: Double {
        switch self {
        case .spineTilt: return 5
        case .postureChange: return 4
        case .shoulderTurn: return 8
        case .hipTurn: return 7
        case .xFactor: return 8
        case .headDrift, .hipSway: return 1.5
        case .planeDeviation: return 6
        case .swingPath: return 4
        }
    }

    /// Metrics that measure an amount of unwanted movement can't go below
    /// zero, so their ideal window starts at 0. Swing path is signed
    /// (over-the-top vs in-to-out), so unlike plane deviation it can't be
    /// clamped this way.
    var isNonNegative: Bool {
        switch self {
        case .headDrift, .hipSway, .postureChange, .planeDeviation: return true
        default: return false
        }
    }

    /// A short cue for what to drag in the pose editor to change this number.
    var editorHint: String {
        switch self {
        case .spineTilt: return "Drag the hips or neck to change how far the body bows forward."
        case .postureChange: return "Shape this position's spine, then compare it with your address spine."
        case .shoulderTurn: return "Drag the shoulders closer together to turn them further away from the camera."
        case .hipTurn: return "Drag the hips closer together to rotate them away from the camera."
        case .xFactor: return "Turn the shoulders more than the hips to build separation."
        case .headDrift: return "Drag the head sideways to set how much movement you'll allow."
        case .hipSway: return "Drag the hip centre sideways to set the allowed slide."
        case .planeDeviation: return "Drag the hands on or off the dashed plane line."
        case .swingPath: return "Drag the hands at delivery and impact to change the angle between them and the plane line."
        }
    }

    var explanation: String {
        switch self {
        case .spineTilt:
            return "Forward tilt of your spine from vertical. Set at address, it should stay stable through the swing."
        case .postureChange:
            return "How much your spine angle changed vs address. Big changes mean early extension or loss of posture."
        case .shoulderTurn:
            return "How far your shoulders rotated away from the ball at the top (estimated from the camera view)."
        case .hipTurn:
            return "How far your hips rotated at the top. Less than shoulders creates coil."
        case .xFactor:
            return "Shoulder turn minus hip turn — the separation that stores power."
        case .headDrift:
            return "How far your head moved sideways from its address position."
        case .hipSway:
            return "Sideways slide of your hips away from or toward the target instead of rotating."
        case .planeDeviation:
            return "How far your hands stray from the swing-plane line drawn from the ball through your shoulder."
        case .swingPath:
            return "Direction your hands travel coming into impact, relative to the plane line. Positive is over-the-top, negative is in-to-out."
        }
    }

    /// Whether this can honestly be measured from a given camera angle.
    ///
    /// This is a safety net for a real bug: a back-view (down-the-line) swing
    /// that got ANALYSED while the app was set to Face-On produced a
    /// "shoulder turn" reading, because nothing stopped it. From behind, the
    /// shoulder line points straight at the camera and its apparent width is
    /// close to meaningless — worse, that metric carries 1.5x weight, so it
    /// dragged a genuinely good swing's score down hard. The real fix is
    /// making the view impossible to get wrong and easy to correct afterwards
    /// (see `SetupSheet` and `SwingRescorer`); this is what stops a stale or
    /// hand-edited profile from reintroducing the same class of bug even if
    /// the view is right.
    ///
    /// Rotation (shoulder turn, hip turn, X-factor) needs the shoulder/hip
    /// line to be broadside to the camera — that's face-on. Down-the-line it
    /// foreshortens to almost nothing. Hip sway is the same story: the motion
    /// it measures is lateral in the image, which only down-the-line's
    /// foreshortened axis would hide.
    ///
    /// Posture change and the swing-plane line need the golfer's forward bend
    /// and the ball-to-shoulder line to read as real angles rather than
    /// near-vertical noise — that's down-the-line. `SwingGeometry.planeLine`
    /// in particular estimates the ball position from the lateral offset
    /// between the hands and the ankles, which is only meaningful when the
    /// camera is looking down that same axis.
    ///
    /// Spine tilt and head drift are genuinely visible from both — spine tilt
    /// reads as forward bend down-the-line and as side-to-side lean face-on
    /// (two different, both real, quantities, which is why the seeded ranges
    /// differ: 0–10° face-on vs 28–42° down-the-line), and head drift is a
    /// simple sideways screen position in either view.
    func isVisible(from view: CameraViewType) -> Bool {
        switch view {
        case .faceOn:
            switch self {
            case .spineTilt, .shoulderTurn, .hipTurn, .xFactor, .headDrift, .hipSway: return true
            case .postureChange, .planeDeviation, .swingPath: return false
            }
        case .downTheLine:
            switch self {
            case .spineTilt, .postureChange, .planeDeviation, .swingPath, .headDrift: return true
            case .shoulderTurn, .hipTurn, .xFactor, .hipSway: return false
            }
        }
    }
}
