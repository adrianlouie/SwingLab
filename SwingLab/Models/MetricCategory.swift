import Foundation

/// Groups `MetricKind`s for the Settings "Feedback" screen and the results
/// checklist — built from what SwingLab actually measures, not copied from
/// any reference app's category names. There is deliberately no "Hand
/// Path"/"Hip Depth"/"Flying Elbow" category: those describe measurements
/// this app doesn't compute today. Expanding the actual metric set to match
/// some other vocabulary is a separate, larger project (new geometry, new
/// `MetricKind` cases, new fault correlations) — this is the architecture
/// for configuring what already exists, not a promise of parity with
/// anything else.
enum MetricCategory: String, CaseIterable, Identifiable {
    case setupPosture = "Setup Posture"
    case bodyRotation = "Body Rotation"
    case headStability = "Head Stability"
    case hipStability = "Hip Stability"
    case postureChange = "Posture Change"

    var id: String { rawValue }

    /// One line of plain language for what this category is about — shown
    /// above its metrics in both Settings and the results checklist.
    var summary: String {
        switch self {
        case .setupPosture: return "How you're set up at address."
        case .bodyRotation: return "How far your shoulders and hips turn."
        case .headStability: return "How much your head moves during the swing."
        case .hipStability: return "How much your hips slide instead of turning."
        case .postureChange: return "How much your spine angle changes through the swing."
        }
    }
}

extension MetricKind {
    var category: MetricCategory {
        switch self {
        case .spineTilt: return .setupPosture
        case .shoulderTurn, .hipTurn, .xFactor: return .bodyRotation
        case .headDrift: return .headStability
        case .hipSway: return .hipStability
        case .postureChange: return .postureChange
        // Retired, never surfaced anywhere a category would be read from —
        // exhaustive only so this switch can't silently miss a future case.
        case .planeDeviation, .swingPath: return .postureChange
        }
    }
}
