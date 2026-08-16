import Foundation

/// Every individual club, each carrying a nominal length in inches — the
/// single physical quantity `ClubAdjustment` uses to shift posture and turn
/// targets. Lengths are typical steel/graphite figures for an average-height
/// golfer, not a precision fitting chart; the point is the *trend* (longer
/// club → taller posture → fuller turn), same spirit as the rest of
/// `ModelProProfile`'s seeded ranges.
enum GolfClub: String, Codable, CaseIterable, Identifiable {
    case driver = "Driver"
    case threeWood = "3 Wood"
    case fiveWood = "5 Wood"
    case sevenWood = "7 Wood"
    case threeHybrid = "3 Hybrid"
    case fourHybrid = "4 Hybrid"
    case fiveHybrid = "5 Hybrid"
    case threeIron = "3 Iron"
    case fourIron = "4 Iron"
    case fiveIron = "5 Iron"
    case sixIron = "6 Iron"
    case sevenIron = "7 Iron"
    case eightIron = "8 Iron"
    case nineIron = "9 Iron"
    case pitchingWedge = "Pitching Wedge"
    case gapWedge = "Gap Wedge"
    case sandWedge = "Sand Wedge"
    case lobWedge = "Lob Wedge"
    case putter = "Putter"

    var id: String { rawValue }

    /// Nominal club length in inches.
    var length: Double {
        switch self {
        case .driver: return 46.0
        case .threeWood: return 43.5
        case .fiveWood: return 42.5
        case .sevenWood: return 41.5
        case .threeHybrid: return 40.5
        case .fourHybrid: return 40.0
        case .fiveHybrid: return 39.5
        case .threeIron: return 39.0
        case .fourIron: return 38.5
        case .fiveIron: return 38.0
        case .sixIron: return 37.5
        case .sevenIron: return 37.0
        case .eightIron: return 36.5
        case .nineIron: return 36.0
        case .pitchingWedge: return 35.75
        case .gapWedge: return 35.5
        case .sandWedge: return 35.0
        case .lobWedge: return 34.5
        case .putter: return 35.0
        }
    }
}
