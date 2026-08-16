import SwiftUI
import SwiftData

/// Side-by-side comparison: the current swing vs one of the user's own
/// reference swings, synced position-by-position — and, since Phase 5,
/// synced continuously through actual video playback via
/// `SyncedComparisonController` rather than one still frame per tap.
struct ComparisonView: View {
    let record: SwingRecord

    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<SwingRecord> { $0.isReference == true },
           sort: \SwingRecord.date, order: .reverse)
    private var referenceSwings: [SwingRecord]

    @State private var selectedPosition: SwingPosition = .address
    @State private var selectedReference: SwingRecord?

    @State private var syncController: SyncedComparisonController?

    // Decoded once per clip purely to learn its pixel aspect ratio — same
    // one-shot-decode pattern `ResultsView.frameAspectValue` uses, so the
    // video pane doesn't have to guess a box size before playback starts.
    @StateObject private var myLoader: FrameLoader
    @State private var referenceLoader: FrameLoader?
    @State private var myAspect: CGFloat = 9.0 / 16.0
    @State private var referenceAspect: CGFloat = 9.0 / 16.0

    init(record: SwingRecord) {
        self.record = record
        _myLoader = StateObject(wrappedValue: FrameLoader(videoURL: record.videoURL))
    }

    private var positions: [SwingPosition] {
        guard let detected = record.analysis?.positions else { return [] }
        let present = Set(detected.map(\.position))
        return SwingPosition.allCases.filter { present.contains($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                referencePicker

                PositionIconScrubber(positions: positions, selected: $selectedPosition)

                comparisonBody

                if let syncController {
                    SyncedPlaybackControlsBar(controller: syncController)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let first = positions.first { selectedPosition = first }
                if selectedReference == nil {
                    selectedReference = referenceSwings.first { $0.persistentModelID != record.persistentModelID }
                }
            }
            .task { await setUpPrimary() }
            .onChange(of: selectedReference) { _, newValue in
                Task { await setUpSecondary(newValue) }
            }
            .onChange(of: selectedPosition) { _, newValue in jump(to: newValue) }
            .onDisappear { syncController?.teardown() }
        }
    }

    // MARK: - Subviews

    private var referencePicker: some View {
        Group {
            let candidates = referenceSwings.filter { $0.persistentModelID != record.persistentModelID }
            if candidates.isEmpty {
                Text("No reference swings yet — mark a good swing as a reference from its results screen (⋯ menu).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Reference", selection: $selectedReference) {
                    ForEach(candidates) { swing in
                        Text("\(swing.date.formatted(date: .abbreviated, time: .omitted)) · \(Int(swing.overallScore))")
                            .tag(Optional(swing))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var comparisonBody: some View {
        HStack(spacing: 10) {
            if let syncController, let analysis = record.analysis {
                videoPane(lane: syncController.primary, analysis: analysis, record: record,
                          aspect: myAspect, title: "This Swing", progress: syncController.progress)
            } else {
                placeholderPane(text: "Loading…")
            }

            if let ref = selectedReference {
                if let syncController, let secondary = syncController.secondary, let analysis = ref.analysis {
                    videoPane(lane: secondary, analysis: analysis, record: ref,
                              aspect: referenceAspect, title: "Reference", progress: syncController.progress)
                } else {
                    placeholderPane(text: "Loading…")
                }
            } else {
                placeholderPane(text: "Pick a reference")
            }
        }
    }

    /// One pane: the clip's own `AVPlayer` layer plus a pose overlay for
    /// whichever frame `progress` currently lands on *in this lane's own,
    /// independently-scaled range* — the same "video and overlay share one
    /// `FrameGeometry`" discipline `LivePoseOverlay` uses for single-swing
    /// playback, just with two lanes instead of one.
    private func videoPane(lane: SyncedComparisonController.Lane, analysis: SwingAnalysis,
                           record: SwingRecord, aspect: CGFloat, title: String,
                           progress: Double) -> some View {
        let time = lane.range.lowerBound + progress * lane.duration
        let frame = nearestFrame(in: analysis, at: time)
        return VStack(spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let geometry = FrameGeometry(container: geo.size, aspect: aspect)
                ZStack {
                    PlayerLayerView(player: lane.player)
                        .frame(width: geometry.contentRect.width, height: geometry.contentRect.height)
                        .position(x: geometry.contentRect.midX, y: geometry.contentRect.midY)

                    if let frame {
                        OverlayCanvas(frame: frame,
                                      addressFrame: analysis.frame(for: .address),
                                      position: selectedPosition,
                                      viewType: record.viewType,
                                      handedness: record.handedness,
                                      space: analysis.space,
                                      imageAspect: aspect)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func placeholderPane(text: String) -> some View {
        VStack(spacing: 6) {
            Text(" ").font(.caption.bold())
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Setup

    /// Finds the frame nearest `time` without keeping any persistent cursor
    /// state across renders — `PoseTimeline`'s O(1)-amortized walk only pays
    /// off across a run of monotonically-increasing lookups on one array, and
    /// juggling two such cursors (one per pane) across SwiftUI re-renders is
    /// more state than the win is worth here; a fresh binary search per call
    /// is cheap enough at this scale.
    private func nearestFrame(in analysis: SwingAnalysis, at time: Double) -> PoseFrame? {
        var timeline = PoseTimeline(times: analysis.frames.map(\.time))
        guard let idx = timeline.index(at: time), analysis.frames.indices.contains(idx) else { return nil }
        return analysis.frames[idx]
    }

    /// address...finish, the same "swing itself" span used for playback
    /// range in single-swing view (`analysis.playbackRange`) — comparison
    /// deliberately doesn't include the standing-around padding on either
    /// side, since phase-normalizing that padding along with the swing would
    /// stretch two different amounts of dead time to look like part of the
    /// motion.
    private func swingRange(_ analysis: SwingAnalysis) -> ClosedRange<Double>? {
        guard let addressTime = analysis.detected(for: .address)?.time,
              let finishTime = analysis.detected(for: .finish)?.time,
              addressTime < finishTime else { return nil }
        return addressTime...finishTime
    }

    private func setUpPrimary() async {
        guard let analysis = record.analysis, let range = swingRange(analysis) else { return }
        syncController = SyncedComparisonController(primaryURL: record.videoURL, primaryRange: range)

        if let address = analysis.detected(for: .address),
           let image = await myLoader.image(at: address.time, cacheKey: address.frameIndex) {
            myAspect = image.size.width / max(image.size.height, 1)
        }

        await setUpSecondary(selectedReference)
        jump(to: selectedPosition)
    }

    private func setUpSecondary(_ ref: SwingRecord?) async {
        guard let syncController else { return }
        guard let ref, let analysis = ref.analysis, let range = swingRange(analysis) else {
            syncController.clearSecondary()
            referenceLoader = nil
            return
        }

        syncController.setSecondary(url: ref.videoURL, range: range)

        let loader = FrameLoader(videoURL: ref.videoURL)
        referenceLoader = loader
        if let address = analysis.detected(for: .address),
           let image = await loader.image(at: address.time, cacheKey: address.frameIndex) {
            referenceAspect = image.size.width / max(image.size.height, 1)
        }

        jump(to: selectedPosition)
    }

    /// Resolves a named position independently per lane — real per-clip
    /// alignment ("both swings at Top"), not an approximation through shared
    /// phase progress, which two different swings' own Top moments won't
    /// generally sit at the same fraction of their own address...finish span.
    private func jump(to position: SwingPosition) {
        syncController?.seekToPosition(primaryTime: record.analysis?.detected(for: position)?.time,
                                       secondaryTime: selectedReference?.analysis?.detected(for: position)?.time)
    }
}

/// Play/pause, speed, and loop for both lanes at once — a smaller sibling of
/// `PlaybackControlsBar`, built for `SyncedComparisonController` instead of
/// `SwingPlayerController`. No problem-stop toggle: comparison doesn't
/// auto-pause on faults the way single-swing playback does.
private struct SyncedPlaybackControlsBar: View {
    let controller: SyncedComparisonController

    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubProgress : controller.progress },
                    set: { scrubProgress = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { controller.seek(to: scrubProgress) }
                }
            )
            .accessibilityIdentifier("comparisonPlaybackScrubber")

            HStack(spacing: 14) {
                Button {
                    Haptics.impact()
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityIdentifier("comparisonPlayPauseButton")

                Picker("Speed", selection: Binding(
                    get: { controller.rate },
                    set: { controller.rate = $0 }
                )) {
                    ForEach(PlaybackRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Spacer()

                Toggle(isOn: Binding(get: { controller.isLooping }, set: { controller.isLooping = $0 })) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("comparisonLoopToggle")
            }
            .font(.subheadline)
        }
    }
}
