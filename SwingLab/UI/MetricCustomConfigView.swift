import SwiftUI

/// Custom mode's checkbox grid: for the given shot type + camera view, one
/// section per `MetricCategory`, each metric expandable to a checkbox per
/// `SwingPosition`. Only metrics `isVisible(from: view)` are shown at all —
/// offering a toggle for a combination that could never actually be scored
/// (shoulder turn down-the-line, say) would just be confusing, since
/// `SwingAnalyzer.analyze` gates on that same rule regardless of what's
/// enabled here.
struct MetricCustomConfigView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    let shotType: ShotType
    let view: CameraViewType

    private var liveKinds: [MetricKind] {
        MetricKind.allCases.filter { $0.isVisible(from: view) && $0 != .planeDeviation && $0 != .swingPath }
    }

    private func targetID(_ kind: MetricKind, _ position: SwingPosition) -> String {
        MetricTarget(shotType: shotType, view: view, position: position, kind: kind, low: 0, high: 0).id
    }

    private func isEnabled(_ kind: MetricKind, _ position: SwingPosition) -> Bool {
        guard let enabled = profileStore.profile.enabledTargetIDs else { return true }
        return enabled.contains(targetID(kind, position))
    }

    private func setEnabled(_ isOn: Bool, _ kind: MetricKind, _ position: SwingPosition) {
        // First edit in a fresh Custom session: seed from "everything
        // currently seeded was on," matching how switching into Custom
        // mode itself behaves — a lone toggle shouldn't retroactively turn
        // off every other metric that was never touched.
        if profileStore.profile.enabledTargetIDs == nil {
            profileStore.profile.enabledTargetIDs = Set(profileStore.profile.targets.map(\.id))
        }
        let id = targetID(kind, position)
        if isOn {
            profileStore.profile.enabledTargetIDs?.insert(id)
        } else {
            profileStore.profile.enabledTargetIDs?.remove(id)
        }
    }

    var body: some View {
        Form {
            ForEach(MetricCategory.allCases) { category in
                let kinds = liveKinds.filter { $0.category == category }
                if !kinds.isEmpty {
                    Section {
                        ForEach(kinds) { kind in
                            DisclosureGroup(kind.rawValue) {
                                ForEach(SwingPosition.allCases) { position in
                                    Toggle(position.shortLabel, isOn: Binding(
                                        get: { isEnabled(kind, position) },
                                        set: { setEnabled($0, kind, position) }
                                    ))
                                    .accessibilityIdentifier("customToggle.\(kind.rawValue).\(position.rawValue)")
                                }
                            }
                        }
                    } header: {
                        Text(category.rawValue)
                    } footer: {
                        Text(category.summary)
                    }
                }
            }
        }
        .navigationTitle("Choose What to Measure")
        .navigationBarTitleDisplayMode(.inline)
    }
}
