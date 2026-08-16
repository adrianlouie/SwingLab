import SwiftUI
import SwiftData

/// Full results for one analyzed swing: score, per-position frame viewer
/// with overlays, metric scores vs ideal ranges, coaching, comparison, and
/// frame-nudging.
struct ResultsView: View {
    @Bindable var record: SwingRecord
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var profileStore: ProfileStore

    @StateObject private var frameLoader: FrameLoader
    @State private var selectedPosition: SwingPosition = .address
    @State private var showAdjustSheet = false
    @State private var showComparison = false
    /// Set when an on-video fault badge is tapped; presents the same
    /// `FaultCard` detail the list below the video already shows — never a
    /// second copy of that content.
    @State private var badgeDetailFault: SwingFault?

    // Declaring this via @AppStorage (rather than reading
    // `FaultDisplay.includeLowerConfidence`'s live UserDefaults getter
    // directly inside `faultsSection`) is what makes SwiftUI redraw this
    // view the instant the Settings toggle changes — a plain UserDefaults
    // read inside a view's body isn't a tracked dependency, so without this
    // the "Lower-Confidence Reads" section only picked up a flipped toggle
    // on some unrelated re-render, which read as the toggle doing nothing.
    @AppStorage(FaultDisplay.includeLowerConfidenceKey) private var includeLowerConfidenceFaults = true

    // Playback. One AVPlayer drives both the paused per-position frame and
    // full-swing playback — see `SwingPlayerController`. `frameAspectValue`
    // is loaded once from a single decoded frame purely for `FrameGeometry`
    // sizing; it is never displayed itself.
    @State private var playerController: SwingPlayerController?
    @State private var frameAspectValue: CGFloat?

    // Zoom/pan on the frame viewer. Plain @State rather than anything
    // persisted: it's view state, not swing data, and a magnify gesture
    // writes at display rate — but @State DOES survive switching between
    // positions and while (future) playback runs, since neither remounts
    // this view, which is what "remembered per swing" actually requires.
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var committedPanOffset: CGSize = .zero

    private var isZoomed: Bool { zoom > 1.01 }

    /// User-drawn lines/circles — keyed per position (same reasoning as the
    /// rest of the overlay being position-specific: a mark drawn against the
    /// Address pose has no obvious meaning once the body's moved to Top).
    /// Ephemeral `@State`, same as `zoom`/`panOffset` above — not saved with
    /// the swing.
    @State private var annotationsByPosition: [SwingPosition: [OverlayAnnotation]] = [:]

    private var currentAnnotations: Binding<[OverlayAnnotation]> {
        Binding(
            get: { annotationsByPosition[selectedPosition] ?? [] },
            set: { annotationsByPosition[selectedPosition] = $0 }
        )
    }

    init(record: SwingRecord) {
        self.record = record
        _frameLoader = StateObject(wrappedValue: FrameLoader(videoURL: record.videoURL))
    }

    private var analysis: SwingAnalysis? { record.analysis }

    /// Canonical swing order (address...finish), not whatever order
    /// `analysis.positions` happens to have been detected/appended in —
    /// the scrubber should always read left-to-right through the swing.
    private var availablePositions: [SwingPosition] {
        guard let analysis else { return [] }
        let detected = Set(analysis.positions.map(\.position))
        return SwingPosition.allCases.filter { detected.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Disabled while zoomed so a pan drag on the frame viewer can
                // never be stolen by the page scroll — see `frameViewer`.
                scoreHeader

                if let analysis {
                    PositionIconScrubber(positions: availablePositions, selected: $selectedPosition)
                    uncertaintyNotice(analysis: analysis)
                    frameViewer(analysis: analysis)
                    AnnotationToolbar(annotations: currentAnnotations)
                    if let playerController {
                        PlaybackControlsBar(controller: playerController)
                    }
                    shotResultPicker
                    faultsSection
                    MetricChecklistView(metrics: analysis.metrics)
                    metricsSection(analysis: analysis)
                    coachingSection
                } else {
                    ContentUnavailableView("No analysis data",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("This swing has no stored analysis."))
                }
            }
            .padding()
        }
        .scrollDisabled(isZoomed)
        .popover(item: $badgeDetailFault) { fault in
            FaultCard(fault: fault) {
                if let position = fault.position {
                    withAnimation { selectedPosition = position }
                }
                badgeDetailFault = nil
            }
            .padding()
            .frame(minWidth: 280, idealWidth: 320)
            .presentationCompactAdaptation(.sheet)
        }
        .navigationTitle(record.shotType.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showComparison = true
                } label: {
                    Label("Compare", systemImage: "person.2")
                }
                Menu {
                    Button {
                        showAdjustSheet = true
                    } label: {
                        Label("Adjust Frames", systemImage: "slider.horizontal.below.rectangle")
                    }
                    Button {
                        record.isReference.toggle()
                        try? context.save()
                    } label: {
                        Label(record.isReference ? "Unmark Reference" : "Mark as Reference",
                              systemImage: record.isReference ? "star.slash" : "star")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAdjustSheet) {
            if let analysis {
                AdjustFramesSheet(record: record, analysis: analysis, frameLoader: frameLoader)
                    .environmentObject(profileStore)
            }
        }
        .sheet(isPresented: $showComparison) {
            ComparisonView(record: record)
        }
        .task(id: analysisKey) {
            if let analysis { await setUpPlayback(analysis: analysis) }
        }
        .onChange(of: selectedPosition) {
            guard let controller = playerController, controller.isPlaying == false,
                  let detected = analysis?.detected(for: selectedPosition) else { return }
            controller.seek(to: detected.time)
        }
        .onAppear {
            if let first = availablePositions.first { selectedPosition = first }
        }
        .onDisappear {
            playerController?.teardown()
        }
    }

    private var analysisKey: Int { record.analysisData?.count ?? 0 }

    /// The head-drift ceiling the overlay colours against — read straight off
    /// the stored metric, not re-derived from the live profile. Re-deriving
    /// it could disagree with what the swing was actually scored against:
    /// the profile is the *current* calibration, but a club-adjusted metric
    /// was scored against a shifted window that only the stored result
    /// still remembers.
    private var headDriftLimit: Double {
        analysis?.metrics.first { $0.kind == .headDrift && $0.position == selectedPosition }?.idealHigh ?? 3
    }

    /// Rebuilds the player whenever the stored analysis changes (rescoring
    /// replaces faults/positions, so stale problem stops or a stale window
    /// would otherwise linger). Cheap to call — `SwingPlayerController` only
    /// opens the asset once here, not per position change.
    private func setUpPlayback(analysis: SwingAnalysis) async {
        playerController?.teardown()

        if frameAspectValue == nil, let address = analysis.detected(for: .address),
           let image = await frameLoader.image(at: address.time, cacheKey: address.frameIndex) {
            frameAspectValue = image.size.width / max(image.size.height, 1)
        }

        let visibleFaults = record.faults.filter {
            FaultDisplay.isVisible($0, frameRate: analysis.frameRate, includeLowerConfidence: includeLowerConfidenceFaults)
        }
        let stops = ProblemStop.stops(faults: visibleFaults, analysis: analysis)
        let controller = SwingPlayerController(url: record.videoURL,
                                               range: analysis.playbackRange,
                                               frameTimes: analysis.frames.map(\.time),
                                               stops: stops)
        if let detected = analysis.detected(for: selectedPosition) {
            controller.seek(to: detected.time)
        }
        playerController = controller
    }

    // MARK: - Sections

    private var scoreHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: record.overallScore / 100)
                    .stroke(Theme.scoreColor(record.overallScore),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(record.overallScore))")
                    .font(.title.bold().monospacedDigit())
            }
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 4) {
                Text("Swing Score")
                    .font(.headline)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TagView(text: record.viewType.rawValue)
                    TagView(text: record.handedness.rawValue)
                    if record.isReference {
                        TagView(text: "★ Reference", color: Theme.amber)
                    }
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The detector says when it isn't sure, rather than quietly presenting a
    /// guess as fact.
    @ViewBuilder
    private func uncertaintyNotice(analysis: SwingAnalysis) -> some View {
        if let detected = analysis.detected(for: selectedPosition), detected.isUncertain {
            Button {
                showAdjustSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(selectedPosition.rawValue) is uncertain — tap to nudge it")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .padding(10)
                .background(Theme.amber.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Theme.amber)
            }
            .accessibilityIdentifier("uncertaintyNotice")
        }
    }

    /// width / height of the video — loaded once from a single decoded
    /// frame; a portrait placeholder until then so the box doesn't jump size.
    private var frameAspect: CGFloat { frameAspectValue ?? 9.0 / 16.0 }

    /// Pinch to zoom, drag to pan once zoomed. The video and `OverlayCanvas`
    /// both read the same `FrameGeometry`, built from this same container
    /// size — the reason the lines cannot drift off the body under zoom is
    /// that there is only one place computing where the video sits, and both
    /// consumers ask it rather than laying themselves out independently.
    private func frameViewer(analysis: SwingAnalysis) -> some View {
        GeometryReader { geo in
            let geometry = FrameGeometry(container: geo.size, aspect: frameAspect,
                                         zoom: zoom, offset: panOffset)
            ZStack {
                if let controller = playerController {
                    PlayerLayerView(player: controller.player)
                        .frame(width: geometry.contentRect.width, height: geometry.contentRect.height)
                        .position(x: geometry.contentRect.midX, y: geometry.contentRect.midY)

                    // Its own `View` type, reading `controller.currentFrameIndex`
                    // in its own `body` — the ~30–60Hz updates during playback
                    // invalidate only this subview, never the whole screen.
                    LivePoseOverlay(controller: controller,
                                    analysis: analysis,
                                    selectedPosition: selectedPosition,
                                    viewType: record.viewType,
                                    handedness: record.handedness,
                                    headDriftLimit: headDriftLimit,
                                    frameAspect: frameAspect,
                                    zoom: zoom,
                                    panOffset: panOffset,
                                    size: geo.size,
                                    faults: analysis.faults,
                                    frameRate: analysis.frameRate,
                                    includeLowerConfidenceFaults: includeLowerConfidenceFaults,
                                    onTapFaultBadge: { badgeDetailFault = $0 })

                    // Real SwiftUI shapes with real drag gestures — never
                    // inside `OverlayCanvas`'s `Canvas`, which can't host
                    // gestures at all. Sits above everything else so a
                    // handle is always grabbable, never covered by a
                    // fault-badge tap target or the video itself.
                    AnnotationOverlay(annotations: currentAnnotations, size: geo.size)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if let controller = playerController {
                    ProblemStopOverlay(controller: controller)
                }
            }
            // Two-finger pinch never conflicts with the page scroll, so it's
            // always live.
            .simultaneousGesture(magnifyGesture(baseRect: geometry.baseRect, container: geo.size))
            // `including: .subviews` on a view with no subviews means "never
            // recognized on this view" — i.e. the drag falls through to the
            // ScrollView untouched below 1x, with no conditional gesture type
            // to juggle. Above 1x it's live and `.scrollDisabled(isZoomed)`
            // on the page keeps the two from fighting over the same drag.
            .gesture(panGesture(baseRect: geometry.baseRect, container: geo.size),
                    including: isZoomed ? .all : .subviews)
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
            }
        }
        .aspectRatio(frameAspect, contentMode: .fit)
        .frame(maxHeight: 500)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if isZoomed {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
                } label: {
                    Text("1×")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(8)
                .accessibilityIdentifier("resetZoom")
            }
        }
    }

    private func magnifyGesture(baseRect: CGRect, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let proposed = max(1, min(6, committedZoom * value.magnification))
                zoom = proposed
                panOffset = FrameGeometry.clampedOffset(panOffset, zoom: proposed,
                                                        baseRect: baseRect, container: container)
            }
            .onEnded { _ in
                committedZoom = zoom
                committedPanOffset = panOffset
            }
    }

    private func panGesture(baseRect: CGRect, container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(width: committedPanOffset.width + value.translation.width,
                                      height: committedPanOffset.height + value.translation.height)
                panOffset = FrameGeometry.clampedOffset(proposed, zoom: zoom,
                                                        baseRect: baseRect, container: container)
            }
            .onEnded { _ in
                committedPanOffset = panOffset
            }
    }

    private func resetZoom() {
        zoom = 1
        committedZoom = 1
        panOffset = .zero
        committedPanOffset = .zero
    }

    private func metricsSection(analysis: SwingAnalysis) -> some View {
        let metricsHere = analysis.metrics.filter { $0.position == selectedPosition }
        return VStack(alignment: .leading, spacing: 10) {
            if !metricsHere.isEmpty {
                Text("\(selectedPosition.rawValue) Checkpoints")
                    .font(.headline)
                ForEach(metricsHere) { metric in
                    MetricCard(metric: metric)
                }
            }

            let otherMetrics = analysis.metrics.filter { $0.position != selectedPosition }
            if !otherMetrics.isEmpty {
                Text("All Measurements")
                    .font(.headline)
                    .padding(.top, 6)
                ForEach(otherMetrics) { metric in
                    MetricCard(metric: metric, compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The camera can't see the strike, so the golfer tells us. This re-ranks
    /// the diagnoses rather than adding to them.
    private var shotResultPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How did it come off?")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ShotResult.allCases) { result in
                        Button {
                            Haptics.impact()
                            record.shotResult = record.shotResult == result ? .unknown : result
                            try? context.save()
                            refreshCoaching()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: result.symbol).font(.caption2)
                                Text(result.rawValue).font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(record.shotResult == result ? Theme.fairway : Color(.secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(record.shotResult == result ? .white : .primary)
                        }
                        .accessibilityIdentifier("shotResult.\(result.rawValue)")
                    }
                }
                .padding(.horizontal, 1)
            }
            Text("Tagging the miss lets the coaching connect it to what your body did. It re-ranks what was found — it never invents a fault.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Split so a weak reading never sits next to a firm one with equal
    /// visual weight — a 0.28-confidence tendency and a 0.85-confidence
    /// early extension used to read as equally certain.
    @ViewBuilder
    private var faultsSection: some View {
        let frameRate = record.analysis?.frameRate ?? 60
        let visible = record.faults.filter {
            FaultDisplay.isVisible($0, frameRate: frameRate, includeLowerConfidence: includeLowerConfidenceFaults)
        }
        let firm = visible.filter { FaultDisplay.isFirm($0) }
        let lowerConfidence = visible.filter { !FaultDisplay.isFirm($0) }

        if !firm.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's going wrong")
                    .font(.headline)
                ForEach(firm) { fault in
                    FaultCard(fault: fault) {
                        if let position = fault.position {
                            withAnimation { selectedPosition = position }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !lowerConfidence.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lower-Confidence Reads")
                    .font(.headline)
                ForEach(lowerConfidence) { fault in
                    VStack(alignment: .leading, spacing: 4) {
                        FaultCard(fault: fault) {
                            if let position = fault.position {
                                withAnimation { selectedPosition = position }
                            }
                        }
                        Text("\(Int(fault.confidence * 100))% confidence")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(frameRate < 60
                     ? "Filmed at \(Int(frameRate))fps — anything measured at the instant of impact is inherently rougher below 60fps. Filming at 120fps gives a firmer answer."
                     : "These patterns showed up but weren't strong or consistent enough to call with confidence.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("lowerConfidenceFaults")
        }
    }

    /// Re-runs coaching after the shot tag changes. Faults are pure maths over
    /// frames we already have, so this is instant — no re-extraction.
    private func refreshCoaching() {
        guard let analysis = record.analysis else { return }
        let metrics = analysis.metrics
        let faults = analysis.faults
        let result = record.shotResult
        let shot = record.shotType
        let view = record.viewType
        let score = record.overallScore
        let frameRate = analysis.frameRate
        Task {
            let text = await Coach.coaching(for: metrics, faults: faults, shotResult: result,
                                            shotType: shot, view: view, overallScore: score,
                                            frameRate: frameRate)
            await MainActor.run {
                record.coachingText = text
                try? context.save()
            }
        }
    }

    private var coachingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Coach's Notes", systemImage: "figure.golf")
                .font(.headline)
            Text(record.coachingText.isEmpty ? "No coaching available for this swing." : record.coachingText)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Theme.fairway.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Components

/// One named fault: what it is, why it matters, what to feel, and a drill.
struct FaultCard: View {
    let fault: SwingFault
    let onTapPosition: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(severityColor)
                    .frame(width: 10, height: 10)
                Text(fault.kind.title)
                    .font(.subheadline.bold())
                Spacer()
                Text(fault.severity.label)
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(severityColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(severityColor)
            }

            if fault.kind.isTendency {
                Label("Read from your body, not the strike itself — your ball flight is the real answer.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(fault.kind.plainExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Label(fault.kind.feel, systemImage: "figure.golf")
                        .font(.caption)
                    Label(fault.kind.drill, systemImage: "target")
                        .font(.caption)
                    ForEach(fault.evidence, id: \.label) { evidence in
                        Text(evidence.formatted)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let position = fault.position {
                        Button {
                            onTapPosition()
                        } label: {
                            Label("Show me at \(position.rawValue)", systemImage: "arrow.right.circle")
                                .font(.caption)
                        }
                    }
                }
                .padding(.top, 2)
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Text(expanded ? "Less" : "How to fix it")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.fairway)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var severityColor: Color {
        switch fault.severity {
        case .slight: return Theme.amber
        case .clear: return .orange
        case .severe: return .red
        }
    }
}

struct TagView: View {
    let text: String
    var color: Color = Theme.fairway

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MetricCard: View {
    let metric: MetricResult
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(metric.status == .good ? Theme.good : Theme.amber)
                    .frame(width: 10, height: 10)
                Text(compact ? "\(metric.kind.rawValue) · \(metric.position.shortLabel)" : metric.kind.rawValue)
                    .font(compact ? .subheadline : .subheadline.bold())
                Spacer()
                Text("\(metric.measured, format: .number.precision(.fractionLength(0...1)))\(metric.kind.unit)")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(metric.status == .good ? Theme.good : Theme.amber)
                Text("ideal \(metric.idealLow, format: .number.precision(.fractionLength(0...1)))–\(metric.idealHigh, format: .number.precision(.fractionLength(0...1)))\(metric.kind.unit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !compact {
                GaugeBar(metric: metric)
                Text(metric.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A horizontal bar showing the ideal window and where the measured value
/// landed relative to it.
struct GaugeBar: View {
    let metric: MetricResult

    /// Display span: the ideal range padded by one range-width per side, so a
    /// value one full width outside the window sits at the very edge.
    private var displayRange: (low: Double, span: Double) {
        let rangeWidth = max(metric.idealHigh - metric.idealLow, 0.001)
        let low = metric.idealLow - rangeWidth
        let high = metric.idealHigh + rangeWidth
        return (low, high - low)
    }

    private func offset(for value: Double, width: CGFloat) -> CGFloat {
        let (low, span) = displayRange
        let clamped = max(low, min(low + span, value))
        return CGFloat((clamped - low) / span) * width
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let lowX = offset(for: metric.idealLow, width: width)
            let highX = offset(for: metric.idealHigh, width: width)
            let measuredX = offset(for: metric.measured, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                Capsule()
                    .fill(Theme.good.opacity(0.35))
                    .frame(width: highX - lowX, height: 6)
                    .offset(x: lowX)
                Circle()
                    .fill(metric.status == .good ? Theme.good : Theme.amber)
                    .frame(width: 12, height: 12)
                    .offset(x: measuredX - 6)
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Frame adjustment

/// Lets the user nudge any auto-detected position along a scrubbable
/// timeline, then re-scores the swing.
struct AdjustFramesSheet: View {
    @Bindable var record: SwingRecord
    @State var analysis: SwingAnalysis
    let frameLoader: FrameLoader

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var selectedPosition: SwingPosition = .address
    @State private var frameIndex: Double = 0
    @State private var previewImage: UIImage?
    @State private var editedView: CameraViewType
    @State private var editedShotType: ShotType
    @State private var editedClub: GolfClub
    @State private var isRescoring = false

    // Swing-window re-detection: collapsed by default, since auto-detection
    // gets the window right most of the time and this sheet's main job is
    // nudging a single position — this is the "something is wrong" escape
    // hatch, not something every visit here needs.
    @StateObject private var reextractPipeline = AnalysisPipeline()
    @State private var showWindowAdjust = false
    @State private var windowStart: Double = 0
    @State private var windowEnd: Double = 0
    @State private var windowStartThumbnail: UIImage?
    @State private var windowEndThumbnail: UIImage?
    @State private var windowThumbnailTask: Task<Void, Never>?
    @State private var reextractTask: Task<Void, Never>?

    init(record: SwingRecord, analysis: SwingAnalysis, frameLoader: FrameLoader) {
        self.record = record
        _analysis = State(initialValue: analysis)
        self.frameLoader = frameLoader
        _editedView = State(initialValue: record.viewType)
        _editedShotType = State(initialValue: record.shotType)
        _editedClub = State(initialValue: record.club ?? .sevenIron)
        let range = analysis.window ?? (0...max(analysis.sourceDuration ?? analysis.duration, 0.2))
        _windowStart = State(initialValue: range.lowerBound)
        _windowEnd = State(initialValue: range.upperBound)
    }

    /// A back-view clip mis-analysed as face-on is exactly the bug that
    /// started this: the camera view and shot type have to be fixable here,
    /// not just at import, or the only way out is deleting and re-importing.
    /// Club lives here too — it's the same "correct after the fact" need,
    /// just for posture targets instead of visibility.
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera View & Shot")
                .font(.subheadline.bold())
            Picker("Camera View", selection: $editedView) {
                ForEach(CameraViewType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Shot Type", selection: $editedShotType) {
                ForEach(ShotType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Club", selection: $editedClub) {
                ForEach(GolfClub.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            if editedView != record.viewType {
                Text("Changing the view updates which measurements apply and re-scores the swing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if editedClub != (record.club ?? .sevenIron) {
                Text("A longer club shifts posture and turn targets — you stand taller and turn fuller.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    /// Collapsed by default: auto-detection gets the swing window right
    /// most of the time, and this sheet's main job is nudging a single
    /// position, not re-detecting the whole range. This is the "something
    /// is wrong" escape hatch, surfaced but out of the way.
    ///
    /// Trim boundaries are timestamps against the ORIGINAL clip
    /// (`sourceDuration`), not the already-extracted window — the whole
    /// point is reaching frames that were never extracted in the first
    /// place, which the position slider below can't do.
    @ViewBuilder
    private var windowAdjustSection: some View {
        DisclosureGroup("Swing window looks wrong?", isExpanded: $showWindowAdjust) {
            VStack(alignment: .leading, spacing: 10) {
                Text("If the swing was cut short or starts too late, drag either handle and re-detect. This re-runs analysis on the new range and can take a moment.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    windowThumbnail(windowStartThumbnail, label: String(format: "%.2fs", windowStart))
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    windowThumbnail(windowEndThumbnail, label: String(format: "%.2fs", windowEnd))
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { windowStart },
                        set: { windowStart = min($0, windowEnd - 0.2); refreshWindowThumbnails() }
                    ), in: 0...clipDuration)
                    .accessibilityIdentifier("windowAdjustStart")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("End").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { windowEnd },
                        set: { windowEnd = max($0, windowStart + 0.2); refreshWindowThumbnails() }
                    ), in: 0...clipDuration)
                    .accessibilityIdentifier("windowAdjustEnd")
                }

                if isReextracting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(reextractStageDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Button {
                        reextractTask = Task { await reextractWindow() }
                    } label: {
                        Text("Re-detect This Window")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRescoring)
                    .accessibilityIdentifier("reextractWindow")
                }
            }
            .padding(.top, 6)
        }
        .font(.subheadline.bold())
        .onChange(of: showWindowAdjust) {
            if showWindowAdjust { refreshWindowThumbnails() }
        }
    }

    private var clipDuration: Double {
        max(analysis.sourceDuration ?? analysis.duration, windowEnd, 0.2)
    }

    private var isReextracting: Bool {
        switch reextractPipeline.stage {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    private var reextractStageDescription: String {
        switch reextractPipeline.stage {
        case .extractingPoses(let fraction): return "Tracking your body… \(Int(fraction * 100))%"
        case .detectingPositions: return "Finding key swing positions…"
        case .measuringRotation: return "Measuring rotation…"
        case .scoring: return "Measuring lines and angles…"
        case .coaching: return "Writing your coaching notes…"
        default: return "Working…"
        }
    }

    private func windowThumbnail(_ image: UIImage?, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                    ProgressView()
                }
            }
            .frame(width: 70, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Debounced so dragging a slider doesn't fire a decode per pixel — only
    /// the position 200ms after the drag settles gets a real preview.
    /// Synthetic negative cache keys keep these out of the way of the real
    /// frame-index keys the position slider below uses on the same loader.
    private func refreshWindowThumbnails() {
        windowThumbnailTask?.cancel()
        let start = windowStart
        let end = windowEnd
        windowThumbnailTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            async let startImage = frameLoader.image(at: start, cacheKey: -1_000_000 - Int(start * 100))
            async let endImage = frameLoader.image(at: end, cacheKey: -1_000_000 - Int(end * 100))
            let (s, e) = await (startImage, endImage)
            guard !Task.isCancelled else { return }
            windowStartThumbnail = s
            windowEndThumbnail = e
        }
    }

    /// Re-runs extraction on the new range and, on success, dismisses —
    /// `AnalysisPipeline.reextract` already persisted the fresh analysis
    /// through `SwingRescorer` by the time this returns, so there's nothing
    /// further to save.
    private func reextractWindow() async {
        await reextractPipeline.reextract(record: record,
                                          window: windowStart...windowEnd,
                                          sourceDuration: analysis.sourceDuration ?? analysis.duration,
                                          view: editedView,
                                          shotType: editedShotType,
                                          club: editedClub,
                                          profile: profileStore.profile,
                                          context: context)
        guard case .done = reextractPipeline.stage else { return }
        Haptics.success()
        dismiss()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                setupSection

                windowAdjustSection

                Divider()

                Picker("Position", selection: $selectedPosition) {
                    ForEach(analysis.positions.map(\.position)) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if let image = previewImage {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.black.opacity(0.85))
                            .aspectRatio(9 / 16, contentMode: .fit)
                            .overlay { ProgressView().tint(.white) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 4) {
                    Slider(value: $frameIndex,
                           in: 0...Double(max(analysis.frames.count - 1, 1)),
                           step: 1)
                    Text("Frame \(Int(frameIndex) + 1) of \(analysis.frames.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationTitle("Adjust Frames")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isReextracting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isReextracting {
                            reextractTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRescoring {
                        ProgressView()
                    } else {
                        Button("Save & Re-score") {
                            Task { await saveAndRescore() }
                        }
                        .bold()
                        .disabled(isReextracting)
                    }
                }
            }
            .onChange(of: selectedPosition) {
                if let d = analysis.detected(for: selectedPosition) {
                    frameIndex = Double(d.frameIndex)
                }
            }
            .onChange(of: frameIndex) {
                applyFrameChange()
            }
            .task(id: frameIndex) {
                let idx = Int(frameIndex)
                guard analysis.frames.indices.contains(idx) else { return }
                previewImage = await frameLoader.image(at: analysis.frames[idx].time, cacheKey: idx)
            }
            .onAppear {
                if let first = analysis.positions.first {
                    selectedPosition = first.position
                    frameIndex = Double(first.frameIndex)
                }
            }
        }
    }

    private func applyFrameChange() {
        let idx = Int(frameIndex)
        guard analysis.frames.indices.contains(idx),
              let posIdx = analysis.positions.firstIndex(where: { $0.position == selectedPosition }) else { return }
        analysis.positions[posIdx].frameIndex = idx
        analysis.positions[posIdx].time = analysis.frames[idx].time
    }

    /// Routes through `SwingRescorer` — the only path that re-scores a stored
    /// swing — so a frame nudge and a camera-view correction can never drift
    /// into two different, silently-wrong re-scoring implementations again.
    private func saveAndRescore() async {
        isRescoring = true
        await SwingRescorer.rescore(record: record,
                                    analysis: analysis,
                                    view: editedView,
                                    shotType: editedShotType,
                                    club: editedClub,
                                    profile: profileStore.profile,
                                    context: context)
        isRescoring = false
        Haptics.success()
        dismiss()
    }
}
