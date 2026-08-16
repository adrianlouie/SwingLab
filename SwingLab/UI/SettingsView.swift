import SwiftUI

/// Lets the user calibrate every ideal range in the ModelPro profile.
struct SettingsView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var shotType: ShotType = .fullSwing
    @State private var view: CameraViewType = .faceOn
    @State private var previewClub: GolfClub = .sevenIron
    @State private var showResetConfirm = false
    @AppStorage(FaultDisplay.includeLowerConfidenceKey) private var includeLowerConfidenceFaults = true

    /// Targets grouped into one section per metric category, in category
    /// order — replaces the old per-position grouping so Standard mode's
    /// display matches how Custom mode's config screen (and the results
    /// checklist) organize the same metrics.
    private var groupedByCategory: [(category: MetricCategory, targets: [MetricTarget])] {
        let all = profileStore.profile.targets(shotType: shotType, view: view)
        return MetricCategory.allCases.compactMap { category in
            let matching = all.filter { $0.kind.category == category }
                .sorted { a, b in
                    a.kind != b.kind ? a.kind.rawValue < b.kind.rawValue : a.position.rawValue < b.position.rawValue
                }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    /// Positions a category actually measures, right now, for the selected
    /// shot type/view — stated in plain language under its section header,
    /// e.g. "Measured at Top, Impact."
    private func measuredPositionsCaption(_ targets: [MetricTarget]) -> String {
        let positions = targets.map(\.position.rawValue)
        let unique = Array(NSOrderedSet(array: positions)) as? [String] ?? positions
        return "Measured at \(unique.joined(separator: ", "))."
    }

    private var configModeBinding: Binding<ProfileConfigMode> {
        Binding(
            get: { profileStore.profile.configMode },
            set: { newMode in
                if newMode == .custom, profileStore.profile.enabledTargetIDs == nil {
                    // Start from "everything currently seeded is on" — the
                    // same set Standard mode already measures — so flipping
                    // into Custom is a neutral first step, not a surprise
                    // "everything just turned off."
                    profileStore.profile.enabledTargetIDs = Set(profileStore.profile.targets.map(\.id))
                }
                profileStore.profile.configModeRaw = newMode
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Shot Type", selection: $shotType) {
                        ForEach(ShotType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Camera View", selection: $view) {
                        ForEach(CameraViewType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Preview Club", selection: $previewClub) {
                        ForEach(GolfClub.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Ideal Ranges")
                } footer: {
                    Text("These are your personal calibration targets, seeded with model-pro values (7-iron). Adjust them as you learn what's realistic for your swing — every other club shifts automatically from whatever you set here.")
                }

                Section {
                    Picker("Feedback", selection: configModeBinding) {
                        Text("Standard").tag(ProfileConfigMode.standard)
                        Text("Custom").tag(ProfileConfigMode.custom)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("feedbackModePicker")

                    if profileStore.profile.configMode == .custom {
                        NavigationLink {
                            MetricCustomConfigView(shotType: shotType, view: view)
                        } label: {
                            Label("Choose What to Measure", systemImage: "checklist")
                        }
                    }
                } footer: {
                    Text(profileStore.profile.configMode == .standard
                         ? "Every metric below is measured at its default positions."
                         : "Only the metrics and positions you've turned on are measured and scored — everything else is skipped, in scoring and in coaching.")
                }

                ForEach(groupedByCategory, id: \.category) { group in
                    Section {
                        ForEach(group.targets) { target in
                            TargetEditor(target: target, previewClub: previewClub)
                        }
                    } header: {
                        Text(group.category.rawValue)
                    } footer: {
                        Text("\(group.category.summary) \(measuredPositionsCaption(group.targets))")
                    }
                }

                Section {
                    Toggle("Show Lower-Confidence Reads", isOn: $includeLowerConfidenceFaults)
                        .accessibilityIdentifier("includeLowerConfidenceToggle")
                } header: {
                    Text("Faults")
                } footer: {
                    Text(includeLowerConfidenceFaults
                         ? "Weaker patterns — usually from a 30fps clip, or a read the swing only partly supports — show in their own \"Lower-Confidence Reads\" section and get mentioned in coaching."
                         : "Weaker patterns are left out entirely, as if that data was never collected. Only firm findings show up, in the UI and in coaching.")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        showResetConfirm = true
                    }
                }

                Section("About") {
                    LabeledContent("Analysis", value: "100% on-device")
                    LabeledContent("Coaching", value: coachAvailability)
                    LabeledContent("Version", value: "1.0")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset all ideal ranges to their defaults?",
                                isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    profileStore.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var coachAvailability: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return "Apple Intelligence or rules"
        }
        #endif
        return "Built-in rules coach"
    }
}

/// One editable low/high pair.
private struct TargetEditor: View {
    @EnvironmentObject private var profileStore: ProfileStore
    let target: MetricTarget
    let previewClub: GolfClub

    /// What this range actually becomes for the selected preview club —
    /// nil when there's nothing to show, either because it's already the
    /// reference club or the metric doesn't shift with length at all.
    private var adjustedPreview: (low: Double, high: Double)? {
        guard previewClub != .sevenIron else { return nil }
        let adjusted = ClubAdjustment.adjusted(low: target.low, high: target.high,
                                               kind: target.kind, club: previewClub)
        guard adjusted != (target.low, target.high) else { return nil }
        return adjusted
    }

    private var binding: Binding<MetricTarget>? {
        guard let index = profileStore.profile.targets.firstIndex(where: { $0.id == target.id }) else { return nil }
        return Binding(
            get: { profileStore.profile.targets[index] },
            set: { profileStore.profile.targets[index] = $0 }
        )
    }

    var body: some View {
        if let binding {
            VStack(alignment: .leading, spacing: 8) {
                Text(target.kind.rawValue)
                    .font(.subheadline.bold())
                Text(target.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Low")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Low", value: binding.low, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text(target.kind.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("High")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("High", value: binding.high, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text(target.kind.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let preview = adjustedPreview {
                    Text("For \(previewClub.rawValue): \(preview.low, format: .number.precision(.fractionLength(0...1)))–\(preview.high, format: .number.precision(.fractionLength(0...1)))\(target.kind.unit)")
                        .font(.caption2)
                        .foregroundStyle(Theme.fairway)
                }
                HStack {
                    Text("Weight")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: binding.weight, in: 0.5...2, step: 0.1)
                    Text(binding.wrappedValue.weight, format: .number.precision(.fractionLength(1)))
                        .font(.caption.monospacedDigit())
                        .frame(width: 30)
                }
                Text("How heavily this counts toward your overall swing score.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}
