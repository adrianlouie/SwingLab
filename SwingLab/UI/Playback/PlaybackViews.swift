import SwiftUI

/// Draws the skeleton for whichever frame is currently playing. This reads
/// `controller.currentFrameIndex` in its own `body` — a genuine `View` type,
/// not a helper method — so the ~30–60Hz updates during playback invalidate
/// only this subview instead of the whole results screen.
struct LivePoseOverlay: View {
    let controller: SwingPlayerController
    let analysis: SwingAnalysis
    let selectedPosition: SwingPosition
    let viewType: CameraViewType
    let handedness: Handedness
    let headDriftLimit: Double
    let frameAspect: CGFloat
    let zoom: CGFloat
    let panOffset: CGSize
    let size: CGSize
    var faults: [SwingFault] = []
    var frameRate: Double = 30
    var includeLowerConfidenceFaults: Bool = true
    var onTapFaultBadge: ((SwingFault) -> Void)?

    private var frame: PoseFrame? {
        if let idx = controller.currentFrameIndex, analysis.frames.indices.contains(idx) {
            return analysis.frames[idx]
        }
        return analysis.frame(for: selectedPosition)
    }

    /// Address...finish, for the swing-path trace — not the whole extracted
    /// window, which carries some standing-around padding on both ends that
    /// would make the drawn curve start/end in a meaningless tangle.
    private var pathFrames: [PoseFrame] {
        guard let addressIdx = analysis.positions.first(where: { $0.position == .address })?.frameIndex,
              let finishIdx = analysis.positions.first(where: { $0.position == .finish })?.frameIndex,
              addressIdx <= finishIdx, finishIdx < analysis.frames.count else {
            return []
        }
        return Array(analysis.frames[addressIdx...finishIdx])
    }

    var body: some View {
        if let frame {
            let geometry = FrameGeometry(container: size, aspect: frameAspect, zoom: zoom, offset: panOffset)
            ZStack {
                OverlayCanvas(frame: frame,
                              addressFrame: analysis.frame(for: .address),
                              position: selectedPosition,
                              viewType: viewType,
                              handedness: handedness,
                              space: analysis.space,
                              headDriftLimitInches: headDriftLimit,
                              faults: faults,
                              frameRate: frameRate,
                              includeLowerConfidenceFaults: includeLowerConfidenceFaults,
                              pathFrames: pathFrames,
                              imageAspect: frameAspect,
                              zoom: zoom,
                              panOffset: panOffset)

                if let onTapFaultBadge {
                    FaultBadgeOverlay(frame: frame, position: selectedPosition, handedness: handedness,
                                      faults: faults, frameRate: frameRate,
                                      includeLowerConfidenceFaults: includeLowerConfidenceFaults,
                                      geometry: geometry, size: size, onTap: onTapFaultBadge)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Amber card shown when playback auto-pauses on a detected fault — what it
/// is and what to feel, so stopping there means something instead of just
/// going quiet. Its own `View` so reading `controller.activeStop` doesn't
/// tie its (rare) updates to anything else on screen.
struct ProblemStopOverlay: View {
    let controller: SwingPlayerController

    var body: some View {
        if let stop = controller.activeStop {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(stop.position.rawValue): \(stop.faults.map { $0.kind.title }.joined(separator: ", "))")
                        .font(.caption.bold())
                    Spacer()
                    // Distinct from "Tap to continue" below: a quick way to
                    // clear the card and let the swing keep playing without
                    // reading through what it says.
                    Button {
                        controller.dismissActiveStop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .accessibilityIdentifier("dismissProblemStop")
                }
                ForEach(stop.faults) { fault in
                    Text(fault.kind.feel)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Button {
                    controller.dismissActiveStop()
                } label: {
                    Text("Tap to continue")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(Theme.amber.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
            .accessibilityIdentifier("problemStopCard")
        }
    }
}

/// Play/pause, speed, loop, stop-at-problems toggle, and a scrubber confined
/// to the swing itself (`controller.range`), not the whole clip. Its own
/// `View` so the continuous `currentTime` updates while playing invalidate
/// only this bar.
struct PlaybackControlsBar: View {
    let controller: SwingPlayerController

    /// Seek coalescing: while dragging, only the slider's own knob position
    /// moves; the controller isn't told to seek until the drag ends, so a
    /// scrub doesn't flood AVPlayer with seeks mid-gesture.
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : controller.currentTime },
                    set: { scrubTime = $0 }
                ),
                in: controller.range,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { controller.seek(to: scrubTime) }
                }
            )
            .accessibilityIdentifier("playbackScrubber")

            HStack(spacing: 14) {
                Button {
                    Haptics.impact()
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityIdentifier("playPauseButton")

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
                .accessibilityIdentifier("loopToggle")

                if controller.hasStops {
                    Toggle(isOn: Binding(get: { controller.stopsEnabled }, set: { controller.stopsEnabled = $0 })) {
                        Image(systemName: "exclamationmark.octagon")
                    }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("stopsEnabledToggle")
                }
            }
            .font(.subheadline)
        }
    }
}
