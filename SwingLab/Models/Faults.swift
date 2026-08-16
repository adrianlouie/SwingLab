import Foundation

/// What actually happened to the shot. The golfer knows this; the camera
/// doesn't. Tagging it lets coaching connect a real miss to what the body did.
enum ShotResult: String, Codable, CaseIterable, Identifiable {
    case unknown = "Not set"
    case flushed = "Flushed"
    case fat = "Fat / chunked"
    case thin = "Thin"
    case topped = "Topped"
    case slice = "Slice"
    case hook = "Hook"
    case pull = "Pull"
    case push = "Push"
    case shank = "Shank"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .unknown: return "questionmark"
        case .flushed: return "star.fill"
        case .fat: return "arrow.down.to.line"
        case .thin, .topped: return "arrow.up.to.line"
        case .slice: return "arrow.turn.up.right"
        case .hook: return "arrow.turn.up.left"
        case .pull: return "arrow.left"
        case .push: return "arrow.right"
        case .shank: return "arrow.uturn.right"
        }
    }

    /// Faults this miss tends to come from — used to re-rank, never to invent.
    var associatedFaults: [SwingFaultKind] {
        switch self {
        case .fat: return [.hangBack, .casting, .bodyDrop]
        case .thin, .topped: return [.earlyExtension, .bodyRise]
        case .slice, .pull: return [.overTheTop]
        case .hook, .push: return [.slide]
        case .shank: return [.earlyExtension, .overTheTop]
        case .flushed, .unknown: return []
        }
    }
}

enum SwingFaultKind: String, Codable, CaseIterable, Identifiable {
    case overTheTop
    /// Retired — never detected or shown (see `isVisible(from:)`). Kept only
    /// so a `SwingFault` stored under this kind before the retirement still
    /// decodes; deleting the case would throw on that whole `SwingAnalysis`.
    case insideOut
    case earlyExtension
    case casting
    case sway
    case slide
    case reversePivot
    case hangBack
    case bodyDrop
    case bodyRise
    case fatTendency
    case thinTendency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overTheTop: return "Over the top"
        case .insideOut: return "Inside-out path"
        case .earlyExtension: return "Early extension"
        case .casting: return "Casting"
        case .sway: return "Swaying off the ball"
        case .slide: return "Sliding through impact"
        case .reversePivot: return "Reverse pivot"
        case .hangBack: return "Hanging back"
        case .bodyDrop: return "Dropping into the ball"
        case .bodyRise: return "Standing up through impact"
        case .fatTendency: return "Pattern that hits it fat"
        case .thinTendency: return "Pattern that hits it thin"
        }
    }

    var plainExplanation: String {
        switch self {
        case .overTheTop:
            return "Your hands start down outside the ideal path, so the club comes across the ball instead of down the line."
        case .insideOut:
            return "Your hands drop well inside the ideal path coming down, so the club approaches from too far behind you — the mirror image of over the top."
        case .earlyExtension:
            return "Your hips push toward the ball and your body stands up before impact, so you run out of room for your arms."
        case .casting:
            return "The angle between your wrists and the club releases early, so the fastest part of the swing happens before the ball."
        case .sway:
            return "Your hips slide away from the target going back instead of turning, which makes finding the ball again a timing job."
        case .slide:
            return "Your hips slide toward the target through impact rather than rotating, so the low point moves ahead of the ball."
        case .reversePivot:
            return "Your weight leans toward the target at the top instead of loading into your trail side."
        case .hangBack:
            return "Your weight is still on your back foot at impact, so the club bottoms out behind the ball."
        case .bodyDrop:
            return "You dip down into the ball, which drops the low point behind it."
        case .bodyRise:
            return "You lift up through the strike, which raises the low point and catches the ball thin."
        case .fatTendency:
            return "Your body pattern is the one that produces heavy contact — weight back and the low point behind the ball."
        case .thinTendency:
            return "Your body pattern is the one that produces thin contact — standing up and the low point ahead of the ball."
        }
    }

    var feel: String {
        switch self {
        case .overTheTop:
            return "Feel the club drop straight down as your first move from the top, before you turn through."
        case .insideOut:
            return "Feel your chest keep turning through impact instead of your arms flipping the club out in front of you."
        case .earlyExtension:
            return "Feel your rear end stay against an imaginary wall behind you all the way through the strike."
        case .casting:
            return "Feel like you keep the angle in your wrists until your lead arm is past your trail hip."
        case .sway:
            return "Feel like you turn into your trail hip rather than moving over it."
        case .slide:
            return "Feel your lead hip clear behind you rather than pushing toward the target."
        case .reversePivot:
            return "Feel your weight press into your trail heel as you reach the top."
        case .hangBack:
            return "Feel your weight move into your lead foot before the club reaches the ball."
        case .bodyDrop:
            return "Feel your head stay at the height it started, right through the ball."
        case .bodyRise:
            return "Feel like you stay down and let the club, not your body, do the rising."
        case .fatTendency:
            return "Get your weight forward earlier: feel your shirt buttons ahead of the ball at impact."
        case .thinTendency:
            return "Keep your chest covering the ball and your posture held through the strike."
        }
    }

    var drill: String {
        switch self {
        case .overTheTop:
            return "Put a headcover just outside the ball and swing without hitting it."
        case .insideOut:
            return "Put a headcover just inside and behind the ball, and swing without your club brushing it on the way down."
        case .earlyExtension:
            return "Set up with your rear end touching a chair back and keep it there through the swing."
        case .casting:
            return "Make slow half-swings, pausing where your lead arm is parallel, checking the wrist angle is still there."
        case .sway:
            return "Put an alignment stick just outside your trail hip and turn without touching it."
        case .slide:
            return "Same stick outside your lead hip on the way through."
        case .reversePivot:
            return "Make backswings with your lead foot lifted, so you have to load into the trail side."
        case .hangBack:
            return "Step-through drill: start feet together, step toward the target as you start down."
        case .bodyDrop, .bodyRise:
            return "Film face-on and watch the head circle: it should stay inside its starting position."
        case .fatTendency:
            return "Put a tee an inch ahead of the ball and try to clip that tee after the ball."
        case .thinTendency:
            return "Place a towel a few inches behind the ball and swing without hitting it, staying down."
        }
    }

    /// Contact patterns are inferences from the body, not measurements of the
    /// strike, and the UI has to say so.
    var isTendency: Bool {
        self == .fatTendency || self == .thinTendency
    }

    /// Whether this fault's underlying signal is honestly visible from a given
    /// camera angle. Mirrors `MetricKind.isVisible(from:)`.
    ///
    /// The individual detectors in `FaultDetector` already gate correctly —
    /// sway/slide/reversePivot/hangBack read `Context.targetSign`, which is
    /// zero down-the-line, and `overTheTop` checks the view explicitly. This
    /// exists so that fact is stated in one declared place instead of
    /// scattered across five ad-hoc conditions, and so `detect(context:)` can
    /// apply it as an explicit, testable safety net the same way
    /// `SwingAnalyzer` does for metrics.
    func isVisible(from view: CameraViewType) -> Bool {
        switch self {
        case .sway, .slide, .reversePivot, .hangBack:
            // Motion along the target line only reads as left-right screen
            // motion face-on; down-the-line that axis points at the camera.
            return view == .faceOn
        case .overTheTop:
            // Needs the ball-to-shoulder plane line, which only means
            // something when the camera looks down that same axis.
            return view == .downTheLine
        case .insideOut:
            // Retired: penalized swings it shouldn't have. The case stays
            // defined only so a `SwingFault` already stored under this kind
            // from before still decodes — never visible, from either view,
            // so it can never surface again regardless of what's stored.
            return false
        case .earlyExtension, .bodyDrop, .bodyRise, .casting, .fatTendency, .thinTendency:
            // Vertical body height and hand-speed timing aren't foreshortened
            // by either camera orientation.
            return true
        }
    }

    /// Where an on-video badge for this fault should point — the joint (or
    /// derived point) that best shows what actually went wrong, not just an
    /// arbitrary corner of the frame. `nil` for a fault that's never visible
    /// anyway (`insideOut`), so `OverlayCanvas` never has to special-case it.
    func anchor(handedness: Handedness) -> FaultAnchor? {
        switch self {
        case .insideOut:
            return nil
        case .overTheTop, .casting:
            // Both are about the club/hands' path, not a body landmark.
            return .handsCenter
        case .sway, .slide, .hangBack, .reversePivot, .fatTendency, .thinTendency:
            // All about where the hips/weight ended up.
            return .joint(.root)
        case .earlyExtension, .bodyDrop, .bodyRise:
            // Body-height faults read most clearly at the neck, the same
            // landmark the head-drift/spine overlays already anchor to.
            return .joint(.neck)
        }
    }
}

/// Where a fault badge should be anchored on screen. Not always a single
/// `Joint` — "the hands" is a derived midpoint between both wrists, which
/// `PoseFrame.handsCenter` already computes, so this stays a small enum
/// rather than forcing every fault onto one literal joint.
enum FaultAnchor: Equatable {
    case joint(Joint)
    case handsCenter
}

enum FaultSeverity: String, Codable, Comparable {
    case slight, clear, severe

    private var rank: Int {
        switch self {
        case .slight: return 0
        case .clear: return 1
        case .severe: return 2
        }
    }

    static func < (a: FaultSeverity, b: FaultSeverity) -> Bool { a.rank < b.rank }

    var label: String {
        switch self {
        case .slight: return "Slight"
        case .clear: return "Clear"
        case .severe: return "Strong"
        }
    }
}

/// The one place that decides which faults are worth showing.
///
/// Below 60fps every impact-instant detector in `FaultDetector` halves its own
/// confidence (`Context.instantaneousFactor`), because a fast-moving position
/// like impact is genuinely harder to pin to one frame at 30fps. A single fixed
/// cutoff calibrated for 60fps+ then silently hides everything the 30fps path
/// produces — which is exactly what was happening before this existed, and it
/// was duplicated in two files with no way to keep them in sync. Every
/// confidence check in the app should go through here instead of writing its
/// own number.
enum FaultDisplay {
    /// User preference: whether lower-confidence reads are shown in the
    /// UI's second section at all, or excluded entirely, as if that data was
    /// never collected. Never affects coaching — see `isFirm` and its
    /// callers in `Coach`/`RulesCoach` — a low-confidence read isn't
    /// reliable enough to state as advice regardless of whether the golfer
    /// wants it in the on-screen list. Off by default is wrong here: hiding
    /// a feature the user hasn't chosen to turn off would be a silent
    /// regression, so this defaults to "on" (today's behavior) until they
    /// explicitly opt out in Settings.
    static let includeLowerConfidenceKey = "includeLowerConfidenceFaults"

    static var includeLowerConfidence: Bool {
        guard UserDefaults.standard.object(forKey: includeLowerConfidenceKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: includeLowerConfidenceKey)
    }

    /// Findings at or above this confidence are worth showing at all.
    static func threshold(frameRate: Double) -> Double {
        frameRate >= 60 ? 0.40 : 0.22
    }

    /// Findings at or above this confidence are firm enough to lead the
    /// coaching and the "What's going wrong" section, rather than the
    /// lower-confidence one.
    static let firmThreshold = 0.45

    /// The single gate every UI fault list filters through.
    ///
    /// `includeLowerConfidence` defaults to a live UserDefaults read, which
    /// is right for non-SwiftUI callers (tests, background work), but a
    /// view that needs to redraw the instant the Settings toggle changes
    /// must pass its own `@AppStorage`-observed value explicitly — reading
    /// UserDefaults directly inside a view's body isn't a tracked SwiftUI
    /// dependency, so an already-on-screen view would only pick up the
    /// change on some unrelated re-render, not immediately. This is exactly
    /// the bug that made the toggle look broken from `ResultsView`.
    static func isVisible(_ fault: SwingFault, frameRate: Double,
                          includeLowerConfidence: Bool = FaultDisplay.includeLowerConfidence) -> Bool {
        guard fault.confidence >= threshold(frameRate: frameRate) else { return false }
        return includeLowerConfidence || isFirm(fault)
    }

    static func isFirm(_ fault: SwingFault) -> Bool {
        fault.confidence >= firmThreshold
    }
}

/// A diagnosis, as opposed to a measurement. Metrics say "hip sway 4.2 inches";
/// a fault says "you're swaying, here's why it matters and what to feel".
struct SwingFault: Codable, Identifiable {
    struct Evidence: Codable {
        var label: String
        var value: Double
        var unit: String

        var formatted: String {
            let rounded = (value * 10).rounded() / 10
            return "\(label): \(rounded)\(unit)"
        }
    }

    var kind: SwingFaultKind
    var severity: FaultSeverity
    /// 0...1. Reduced when pose quality is poor or the frame rate is too low to
    /// resolve the moment being measured.
    var confidence: Double
    var evidence: [Evidence]
    /// The position that shows it best, for deep-linking.
    var position: SwingPosition?

    var id: String { kind.rawValue }

    var isConfident: Bool { confidence >= 0.6 }
}
