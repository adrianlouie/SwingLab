import SwiftUI
import SwiftData

/// Shown after a video is captured/imported: pick camera view, handedness
/// and shot type, then run the on-device analysis with live progress.
struct SetupSheet: View {
    let videoURL: URL
    let onFinished: (SwingRecord) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var pipeline = AnalysisPipeline()

    @AppStorage("defaultView") private var defaultView = CameraViewType.faceOn.rawValue
    @AppStorage("defaultHandedness") private var defaultHandedness = Handedness.right.rawValue
    @AppStorage("defaultShotType") private var defaultShotType = ShotType.fullSwing.rawValue
    @AppStorage("defaultClub") private var defaultClub = GolfClub.sevenIron.rawValue

    @State private var view: CameraViewType = .faceOn
    @State private var handedness: Handedness = .right
    @State private var shotType: ShotType = .fullSwing
    @State private var club: GolfClub = .sevenIron
    @State private var analysisTask: Task<Void, Never>?

    // Preflight (a cheap clip-duration read, nothing Vision-related) kicks
    // off the moment this sheet appears, while the golfer is still picking
    // camera view and club, instead of only starting once "Analyze" is
    // tapped. Tapping Analyze early just awaits this same task rather than
    // reading the duration a second time.
    @State private var preflightTask: Task<AnalysisPipeline.Preflight?, Never>?

    private var isRunning: Bool {
        switch pipeline.stage {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isRunning {
                    progressBody
                } else if case .failed(let message) = pipeline.stage {
                    failureBody(message: message)
                } else {
                    setupForm
                }
            }
            .navigationTitle(isRunning ? "Analyzing" : "Swing Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        analysisTask?.cancel()
                        analysisTask = nil
                        onCancel()
                    }
                }
            }
            .interactiveDismissDisabled(isRunning)
        }
        .onAppear {
            view = CameraViewType(rawValue: defaultView) ?? .faceOn
            handedness = Handedness(rawValue: defaultHandedness) ?? .right
            shotType = ShotType(rawValue: defaultShotType) ?? .fullSwing
            club = GolfClub(rawValue: defaultClub) ?? .sevenIron
        }
        .task {
            await runPreflight()
        }
        .onChange(of: pipeline.stage) {
            // Hand the record to the coordinator, which closes this sheet and
            // defers the navigation push until dismissal has finished. Doing
            // both in one tick is what used to break every import after the
            // first.
            if case .done = pipeline.stage, let record = pipeline.finishedRecord {
                pipeline.finishedRecord = nil
                onFinished(record)
            }
        }
    }

    // MARK: - Bodies

    private var setupForm: some View {
        Form {
            Section {
                cameraViewPicker
            } header: {
                Text("Camera View")
            } footer: {
                Text("Choose whichever one matches how this clip was actually filmed — the wrong choice measures the wrong things.")
            }

            Section {
                Picker("Handedness", selection: $handedness) {
                    ForEach(Handedness.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Shot Type", selection: $shotType) {
                    ForEach(ShotType.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Club", selection: $club) {
                    ForEach(GolfClub.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Golfer")
            } footer: {
                Text("A longer club is swung standing further away — posture and turn targets shift to match.")
            }

            Section {
                Button {
                    startAnalysis()
                } label: {
                    Label("Analyze Swing", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.fairway)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Everything runs on this iPhone — nothing is uploaded.")
            }
        }
    }

    /// Two large cards rather than a segmented control, because the wrong
    /// choice here is what produced a meaningless, heavily-weighted
    /// "shoulder turn" reading on a down-the-line clip that got analysed as
    /// face-on. Stating in plain language what each option will and won't
    /// measure — right where the choice is made — is what stops that from
    /// happening quietly again. The lists are generated from
    /// `MetricKind.isVisible`, the same rule the analyzer itself enforces, so
    /// this can never drift out of sync with what actually gets scored.
    private var cameraViewPicker: some View {
        VStack(spacing: 10) {
            ForEach(CameraViewType.allCases) { option in
                Button {
                    Haptics.impact()
                    withAnimation(.easeOut(duration: 0.15)) { view = option }
                } label: {
                    cameraViewCard(for: option, selected: view == option)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cameraView.\(option.rawValue)")
            }
        }
        .padding(.vertical, 4)
    }

    private func cameraViewCard(for option: CameraViewType, selected: Bool) -> some View {
        let measured = MetricKind.allCases.filter { $0.isVisible(from: option) }
        let hidden = MetricKind.allCases.filter { !$0.isVisible(from: option) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: option == .faceOn ? "figure.stand" : "figure.golf")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.fairway : .secondary)
                Text(option.rawValue)
                    .font(.subheadline.bold())
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.fairway)
                }
            }

            Text(option.filmingTip)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Label(measured.map(\.rawValue).joined(separator: ", "), systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(Theme.good)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Can't see: " + hidden.map(\.rawValue).joined(separator: ", "), systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(selected ? Theme.fairway.opacity(0.10) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Theme.fairway : .clear, lineWidth: 1.5)
        )
    }

    private var progressBody: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(Theme.fairway)
                .padding(.horizontal, 40)
            Text(stageDescription)
                .font(.headline)
            Text("On-device analysis — this can take a moment for long or high-frame-rate clips.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private func failureBody(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Theme.amber)
            Text("Couldn't analyze this swing")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                pipeline.stage = .idle
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    private var progressValue: Double {
        switch pipeline.stage {
        case .preparing: return 0.05
        case .extractingPoses(let fraction): return fraction * 0.75
        case .detectingPositions: return 0.80
        case .scoring: return 0.88
        case .coaching: return 0.95
        case .done: return 1
        default: return 0
        }
    }

    private var stageDescription: String {
        switch pipeline.stage {
        case .preparing: return "Getting ready…"
        case .extractingPoses(let fraction): return "Tracking your body… \(Int(fraction * 100))%"
        case .detectingPositions: return "Finding key swing positions…"
        case .scoring: return "Measuring lines and angles…"
        case .coaching: return "Writing your coaching notes…"
        case .done: return "Done"
        default: return ""
        }
    }

    /// Kicked off from `.task` as soon as the sheet appears. Doesn't drive
    /// `stage` — see the comment on `AnalysisPipeline.preflight` — so the
    /// setup form stays visible the whole time this runs in the background.
    /// Cheap now (just a duration read), but still worth doing early rather
    /// than blocking the "Analyze" tap on it.
    private func runPreflight() async {
        let task = Task<AnalysisPipeline.Preflight?, Never> {
            try? await pipeline.preflight(videoURL: videoURL)
        }
        preflightTask = task
        _ = await task.value
    }

    private func startAnalysis() {
        defaultView = view.rawValue
        defaultHandedness = handedness.rawValue
        defaultShotType = shotType.rawValue
        defaultClub = club.rawValue
        Haptics.impact()

        // Never blocked on the button tap itself: if preflight is still
        // running, this awaits the very same task rather than reading the
        // clip duration a second time.
        pipeline.stage = .preparing
        analysisTask = Task {
            var result = await preflightTask?.value
            if result == nil {
                result = try? await pipeline.preflight(videoURL: videoURL)
            }
            guard let result else {
                pipeline.stage = .failed("Couldn't read this video. Try importing it again.")
                return
            }
            // Always the whole clip — see `AnalysisPipeline.run`'s doc
            // comment. No window to pick here anymore.
            await pipeline.run(videoURL: videoURL,
                               preflight: result,
                               shotType: shotType,
                               view: view,
                               handedness: handedness,
                               club: club,
                               profile: profileStore.profile,
                               context: context)
        }
    }
}
