import Foundation

/// Shifts a `MetricTarget`'s ideal window to account for club length. A
/// longer club is swung standing further from the ball, so address posture
/// reads more upright (less spine tilt) and the arc is wider (fuller turn).
///
/// Applied at lookup time only, never stored: `ModelProProfile` is decoded
/// with `try?`, so a new required field on `MetricTarget` would silently
/// wipe every saved calibration. This is a pure function instead — the
/// club-adjusted window ends up baked into the `MetricResult` produced at
/// scoring time, which is what the results UI already reads.
enum ClubAdjustment {
    /// The seeded ranges in `ModelProProfile` read as 7-iron values, so it's
    /// the reference length — `club == .sevenIron` produces zero shift.
    static let referenceLength = GolfClub.sevenIron.length

    /// Degrees (or inches, for the drift metrics) of shift per inch of club
    /// length above the reference. `nil` means length-independent: posture
    /// change and swing plane are measured relative to the golfer's own
    /// address position, not to an absolute angle that moves with stance.
    private static func ratePerInch(for kind: MetricKind) -> Double? {
        switch kind {
        case .spineTilt: return -1.0
        case .shoulderTurn: return 0.7
        case .hipTurn: return 0.3
        case .xFactor: return 0.4
        case .headDrift: return 0.10
        case .hipSway: return 0.12
        // Length-independent: each measures a shape or direction relative
        // to the golfer's own address/plane, not an absolute angle that
        // shifts with stance width or ball position.
        case .postureChange, .planeDeviation, .swingPath: return nil
        }
    }

    /// Drift metrics have a physical floor at zero — you can't measure a
    /// negative amount of sway. Shifting must move the ceiling, never push
    /// the floor negative.
    private static func flooredAtZero(_ kind: MetricKind) -> Bool {
        switch kind {
        case .headDrift, .hipSway: return true
        default: return false
        }
    }

    /// Extra half-width added to EACH bound — the window genuinely widens,
    /// not just shifts — per inch the club differs from the reference.
    /// Spine tilt only: body proportions vary enough (a tall golfer and a
    /// short golfer swinging the same club don't share one true angle) that
    /// a fixed-width window gets less trustworthy the further a club sits
    /// from the 7-iron this was calibrated against, on top of whatever the
    /// shift already accounts for.
    private static func toleranceGrowthPerInch(for kind: MetricKind) -> Double {
        switch kind {
        case .spineTilt: return 0.3
        default: return 0
        }
    }

    /// The club-adjusted ideal window. `club` nil means unspecified — the
    /// window comes back byte-identical to what was passed in, which is
    /// what lets records saved before this feature existed re-score
    /// identically with no migration.
    static func adjusted(low: Double, high: Double, kind: MetricKind, club: GolfClub?) -> (low: Double, high: Double) {
        guard let club, let rate = ratePerInch(for: kind) else { return (low, high) }
        let delta = club.length - referenceLength
        let shift = rate * delta
        let growth = toleranceGrowthPerInch(for: kind) * abs(delta)

        if flooredAtZero(kind) {
            return (low, max(low, high + shift + growth))
        }
        return (low + shift - growth, high + shift + growth)
    }
}
