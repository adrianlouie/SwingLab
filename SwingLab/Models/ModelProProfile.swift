import Foundation
import Combine

/// One ideal-range target: "for this shot type, camera view, position and
/// metric, the model-pro value falls between low and high."
///
/// PERSONAL-USE NOTE: the seeded defaults below are calibration starting
/// points in the spirit of the ModelPro position-by-position targets from
/// *Swing Like a Pro*. Every value is editable in Settings.
struct MetricTarget: Codable, Identifiable, Equatable {
    var shotType: ShotType
    var view: CameraViewType
    var position: SwingPosition
    var kind: MetricKind
    var low: Double
    var high: Double
    var weight: Double = 1.0

    var id: String {
        "\(shotType.rawValue)|\(view.rawValue)|\(position.rawValue)|\(kind.rawValue)"
    }

    /// Reverses `id` back into its parts — Custom mode's `enabledTargetIDs`
    /// can name a (shotType, view, position, kind) combination that was
    /// never actually seeded, and this is how `ModelProProfile` recovers
    /// enough to synthesize a starting target for it on the fly.
    static func parse(id: String) -> (shotType: ShotType, view: CameraViewType,
                                      position: SwingPosition, kind: MetricKind)? {
        let parts = id.components(separatedBy: "|")
        guard parts.count == 4,
              let shotType = ShotType(rawValue: parts[0]),
              let view = CameraViewType(rawValue: parts[1]),
              let position = SwingPosition(rawValue: parts[2]),
              let kind = MetricKind(rawValue: parts[3]) else { return nil }
        return (shotType, view, position, kind)
    }
}

/// Whether a profile's target set is exactly what's seeded (`.standard`,
/// the only behavior that existed before this), or has been individually
/// enabled/disabled per (metric, position) via `MetricCustomConfigView`.
enum ProfileConfigMode: String, Codable {
    case standard, custom
}

/// The complete editable set of ideal ranges.
struct ModelProProfile: Codable, Equatable {
    var targets: [MetricTarget]

    /// `nil` (or `.standard`) means every seeded target is active exactly
    /// as before this field existed — an already-persisted profile from an
    /// older build decodes with this `nil` and behaves byte-identically,
    /// no migration needed. Only `MetricCustomConfigView` ever writes
    /// `.custom`.
    var configModeRaw: ProfileConfigMode?
    /// Only consulted when `configModeRaw == .custom`. `nil` means "nothing
    /// has been customized yet" (same as Standard); a non-nil, possibly
    /// *empty* set is the user's explicit choice and is honored as-is —
    /// unchecking everything really does mean "measure nothing," not a bug
    /// to silently correct. Keyed by `MetricTarget.id`, which is why
    /// disabling a pair never has to delete its row: it just drops out of
    /// this set, and its calibration sits untouched in `targets` ready to
    /// come back if re-enabled.
    var enabledTargetIDs: Set<String>?

    var configMode: ProfileConfigMode { configModeRaw ?? .standard }

    /// Metric kinds no longer scored, even if a target for one is sitting in
    /// `targets` — e.g. loaded from a UserDefaults profile saved by an
    /// earlier build that still seeded them. Filtering here, at every read,
    /// means retiring a metric never needs a migration or a "Reset to
    /// Defaults": stale rows go inert immediately regardless of when they
    /// were persisted. `planeDeviation` and `swingPath` were retired because
    /// they doubled up on `overTheTop`'s job while being harder to trust.
    private static let retiredKinds: Set<MetricKind> = [.planeDeviation, .swingPath]

    func target(shotType: ShotType, view: CameraViewType,
                position: SwingPosition, kind: MetricKind) -> MetricTarget? {
        guard !Self.retiredKinds.contains(kind) else { return nil }
        return targets(shotType: shotType, view: view).first { $0.position == position && $0.kind == kind }
    }

    /// All targets that apply to a given shot type + camera view. In
    /// Standard mode (the only mode that existed before Custom config), this
    /// is exactly the seeded rows, unchanged. In Custom mode, filtered (and
    /// possibly extended with synthesized starting points — see
    /// `syntheticTarget`) through `enabledTargetIDs`. This is the ONE place
    /// that distinction is applied — `SwingAnalyzer.analyze` reads only
    /// this, so Custom config changes what's actually scored, not just
    /// what's displayed.
    func targets(shotType: ShotType, view: CameraViewType) -> [MetricTarget] {
        let seeded = targets.filter {
            $0.shotType == shotType && $0.view == view && !Self.retiredKinds.contains($0.kind)
        }
        guard configMode == .custom, let enabled = enabledTargetIDs else { return seeded }

        var byID = Dictionary(uniqueKeysWithValues: seeded.map { ($0.id, $0) })
        var result: [MetricTarget] = []
        for id in enabled {
            guard let parsed = MetricTarget.parse(id: id),
                  parsed.shotType == shotType, parsed.view == view,
                  !Self.retiredKinds.contains(parsed.kind) else { continue }
            if let existing = byID.removeValue(forKey: id) {
                result.append(existing)
            } else {
                result.append(Self.syntheticTarget(shotType: parsed.shotType, view: parsed.view,
                                                   position: parsed.position, kind: parsed.kind))
            }
        }
        return result
    }

    /// A reasonable, fully-editable starting point for a (metric, position)
    /// pair the user turned on in Custom mode that was never developer-
    /// seeded — enabling something new has to do *something*, not silently
    /// no-op, but there's no real calibration data behind it yet. Centers
    /// on 0 (non-negative metrics: `[0, tolerance]`) rather than claiming to
    /// know what "ideal" looks like at a position nobody's calibrated —
    /// Settings' existing low/high editor is exactly how a user narrows
    /// this down to something real.
    static func syntheticTarget(shotType: ShotType, view: CameraViewType,
                                position: SwingPosition, kind: MetricKind) -> MetricTarget {
        let tolerance = kind.defaultTolerance
        let low = kind.isNonNegative ? 0 : -tolerance
        let high = tolerance
        return MetricTarget(shotType: shotType, view: view, position: position, kind: kind,
                           low: low, high: high, weight: 1.0)
    }

    static let `default` = ModelProProfile(targets: defaultTargets)

    // MARK: - Seeded defaults

    private static var defaultTargets: [MetricTarget] {
        var t: [MetricTarget] = []

        // ---- Full swing, Face-On ----
        t += [
            // Spine tilt gets a wide window and a light weight everywhere it
            // appears below: body proportions (a tall golfer vs a short one)
            // shift what a genuinely correct tilt looks like more than a
            // single narrow number can honestly capture, so a deviation here
            // shouldn't swing the overall score hard the way a real
            // technique fault should.
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .address, kind: .spineTilt, low: 0, high: 16, weight: 0.6),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .top, kind: .shoulderTurn, low: 85, high: 100, weight: 1.5),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .top, kind: .hipTurn, low: 40, high: 55),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .top, kind: .xFactor, low: 35, high: 55, weight: 1.5),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .top, kind: .headDrift, low: 0, high: 3, weight: 1.2),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .top, kind: .hipSway, low: 0, high: 2.5),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .impact, kind: .headDrift, low: 0, high: 4),
            MetricTarget(shotType: .fullSwing, view: .faceOn, position: .impact, kind: .hipSway, low: 0, high: 4),
        ]

        // ---- Full swing, Down-the-Line ----
        t += [
            MetricTarget(shotType: .fullSwing, view: .downTheLine, position: .address, kind: .spineTilt, low: 20, high: 50, weight: 0.7),
            MetricTarget(shotType: .fullSwing, view: .downTheLine, position: .top, kind: .postureChange, low: 0, high: 5, weight: 1.5),
            MetricTarget(shotType: .fullSwing, view: .downTheLine, position: .impact, kind: .postureChange, low: 0, high: 6, weight: 1.5),
            MetricTarget(shotType: .fullSwing, view: .downTheLine, position: .top, kind: .headDrift, low: 0, high: 3),
        ]

        // ---- Pitch ----
        t += [
            MetricTarget(shotType: .pitch, view: .faceOn, position: .top, kind: .shoulderTurn, low: 55, high: 80),
            MetricTarget(shotType: .pitch, view: .faceOn, position: .top, kind: .hipTurn, low: 25, high: 45),
            MetricTarget(shotType: .pitch, view: .faceOn, position: .top, kind: .headDrift, low: 0, high: 2),
            MetricTarget(shotType: .pitch, view: .faceOn, position: .impact, kind: .hipSway, low: 0, high: 3),
            MetricTarget(shotType: .pitch, view: .downTheLine, position: .address, kind: .spineTilt, low: 20, high: 50, weight: 0.6),
            MetricTarget(shotType: .pitch, view: .downTheLine, position: .impact, kind: .postureChange, low: 0, high: 5),
        ]

        // ---- Chip ----
        t += [
            MetricTarget(shotType: .chip, view: .faceOn, position: .top, kind: .shoulderTurn, low: 25, high: 50),
            MetricTarget(shotType: .chip, view: .faceOn, position: .top, kind: .headDrift, low: 0, high: 1.5),
            MetricTarget(shotType: .chip, view: .faceOn, position: .impact, kind: .hipSway, low: 0, high: 2),
            MetricTarget(shotType: .chip, view: .downTheLine, position: .address, kind: .spineTilt, low: 17, high: 48, weight: 0.6),
            MetricTarget(shotType: .chip, view: .downTheLine, position: .impact, kind: .postureChange, low: 0, high: 4),
        ]

        // ---- Putt ----
        t += [
            MetricTarget(shotType: .putt, view: .faceOn, position: .top, kind: .shoulderTurn, low: 10, high: 30),
            MetricTarget(shotType: .putt, view: .faceOn, position: .top, kind: .headDrift, low: 0, high: 1),
            MetricTarget(shotType: .putt, view: .faceOn, position: .impact, kind: .headDrift, low: 0, high: 1),
            MetricTarget(shotType: .putt, view: .faceOn, position: .impact, kind: .hipSway, low: 0, high: 1),
            MetricTarget(shotType: .putt, view: .downTheLine, position: .address, kind: .spineTilt, low: 22, high: 53, weight: 0.6),
            MetricTarget(shotType: .putt, view: .downTheLine, position: .impact, kind: .postureChange, low: 0, high: 3),
        ]

        return t
    }
}

/// Loads and saves the (single) editable profile. Stored as JSON in
/// UserDefaults — small, simple, and survives reinstalls via iCloud backup.
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    private static let key = "modelProProfile.v1"

    @Published var profile: ModelProProfile {
        didSet { save() }
    }

    private init() {
        // UI tests launch with a clean slate so saved calibration from an
        // earlier run can't make a later run pass or fail spuriously.
        if CommandLine.arguments.contains("-uiTesting") {
            for key in [Self.key, "hasSeenOnboarding",
                        "defaultView", "defaultHandedness", "defaultShotType", "defaultClub",
                        FaultDisplay.includeLowerConfidenceKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(ModelProProfile.self, from: data) {
            profile = decoded
        } else {
            profile = .default
        }
    }



    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }


    func resetToDefaults() {
        profile = .default
    }
}
