import SwiftUI
import SwiftData
import PhotosUI
import Charts

/// Home screen: the swing library, a score sparkline, and the record/import
/// entry points.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SwingRecord.date, order: .reverse) private var swings: [SwingRecord]

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @State private var coordinator = ImportCoordinator()
    @State private var showRecorder = false
    @State private var newlyAnalyzed: SwingRecord?
    @State private var showOnboarding = false

    var body: some View {
        NavigationStack {
            Group {
                if swings.isEmpty {
                    emptyState
                } else {
                    libraryList
                }
            }
            .navigationTitle("SwingLab")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOnboarding = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationDestination(item: $newlyAnalyzed) { record in
                ResultsView(record: record)
            }
            // Attached inside the stack, not alongside the import sheet, so
            // two sheet modifiers never share one view.
            .sheet(isPresented: $showOnboarding) {
                OnboardingView()
            }
        }
        // The recorder is full-screen and only reachable when nothing else is
        // presented, so it can't collide with the sheet below.
        .fullScreenCover(isPresented: $showRecorder, onDismiss: {
            coordinator.consumeRecordedVideo()
        }) {
            RecordView { url in
                coordinator.stageRecordedVideo(url)
            }
        }
        // Exactly ONE sheet-class modifier drives the import flow, and the
        // navigation push happens after dismissal completes rather than during
        // it. Those two things together are what make repeat imports work.
        .sheet(item: $coordinator.step, onDismiss: {
            coordinator.consumePickedVideo()
            coordinator.consumePendingPush { newlyAnalyzed = $0 }
        }) { step in
            switch step {
            case .picking:
                VideoPicker { result in
                    coordinator.stagePickedVideo(result)
                }
                .ignoresSafeArea()
            case .setup(let url):
                SetupSheet(videoURL: url,
                           onFinished: { coordinator.finish(record: $0) },
                           onCancel: { coordinator.cancel() })
            case .failed(let message):
                ImportFailedView(message: message) { coordinator.cancel() }
            }
        }
        .onAppear {
            if !hasSeenOnboarding {
                hasSeenOnboarding = true
                showOnboarding = true
            }
        }
    }

    // MARK: - Sections

    private var libraryList: some View {
        List {
            if swings.count >= 2 {
                Section {
                    sparkline
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

            Section("Swings") {
                ForEach(swings) { swing in
                    NavigationLink {
                        ResultsView(record: swing)
                    } label: {
                        SwingRow(swing: swing)
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent Scores")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(Int(swings.first?.overallScore ?? 0))")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(Theme.scoreColor(swings.first?.overallScore ?? 0))
            }
            Chart(Array(swings.prefix(12).reversed())) { swing in
                LineMark(x: .value("Date", swing.date),
                         y: .value("Score", swing.overallScore))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.fairway)
                PointMark(x: .value("Date", swing.date),
                          y: .value("Score", swing.overallScore))
                .foregroundStyle(Theme.lime)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .frame(height: 70)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No swings yet", systemImage: "figure.golf")
        } description: {
            Text("Record a swing in slow motion or import one from your library, and SwingLab will break it down position by position.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.impact()
                showRecorder = true
            } label: {
                Label("Record", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.fairway)
            .controlSize(.large)

            Button {
                Haptics.impact()
                coordinator.startPicking()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(coordinator.isPresenting)
            .accessibilityIdentifier("importButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func delete(at offsets: IndexSet) {
        // Collect first: deleting while indexing into a live @Query is asking
        // for an out-of-range crash.
        let doomed = offsets.compactMap { swings.indices.contains($0) ? swings[$0] : nil }
        for swing in doomed {
            VideoStore.delete(fileName: swing.videoFileName)
            context.delete(swing)
        }
        try? context.save()
    }
}

/// Shown in place of the setup sheet when a clip can't be loaded, so the
/// failure lives in the same single presentation as everything else rather
/// than needing its own alert modifier.
struct ImportFailedView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.amber)
                Text("Couldn't open that video")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct SwingRow: View {
    let swing: SwingRecord

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let data = swing.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Theme.fairway.opacity(0.2))
                        .overlay { Image(systemName: "figure.golf").foregroundStyle(Theme.fairway) }
                }
            }
            .frame(width: 54, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(swing.shotType.rawValue)
                        .font(.subheadline.bold())
                    if swing.isReference {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.amber)
                    }
                }
                Text(swing.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagView(text: swing.viewType.rawValue)
            }

            Spacer()

            Text("\(Int(swing.overallScore))")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(Theme.scoreColor(swing.overallScore))
        }
        .padding(.vertical, 4)
    }
}
