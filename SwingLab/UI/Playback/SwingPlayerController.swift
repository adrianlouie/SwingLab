import AVFoundation
import Observation

/// Playback speed. Deliberately not a free `Double` — `playImmediately`
/// needs an exact rate, and a slider inviting arbitrary values would let
/// someone land on a rate the muted-audio trick doesn't cover.
enum PlaybackRate: Double, CaseIterable, Identifiable {
    case quarter = 0.25
    case half = 0.5
    case full = 1.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .quarter: return "¼×"
        case .half: return "½×"
        case .full: return "1×"
        }
    }
}

/// A point in the swing where a fault was found, worth pausing on. At most
/// one per position that actually produced a visible fault — in practice
/// top, delivery and impact are the only positions faults ever attach to.
struct ProblemStop: Identifiable {
    var position: SwingPosition
    var time: Double
    var faults: [SwingFault]

    var id: String { position.rawValue }
}

extension ProblemStop {
    /// Groups the record's currently-visible faults by position and resolves
    /// each to its frame time — the input `SwingPlayerController` needs to
    /// know where to stop. Faults without a position (nothing to seek to)
    /// are dropped.
    static func stops(faults: [SwingFault], analysis: SwingAnalysis) -> [ProblemStop] {
        var byPosition: [SwingPosition: [SwingFault]] = [:]
        for fault in faults {
            guard let position = fault.position else { continue }
            byPosition[position, default: []].append(fault)
        }
        return byPosition.compactMap { position, faults -> ProblemStop? in
            guard let time = analysis.detected(for: position)?.time else { return nil }
            return ProblemStop(position: position, time: time, faults: faults)
        }.sorted { $0.time < $1.time }
    }
}

/// Drives one `AVPlayer` for both the paused per-position frame and full
/// swing playback — see the plan doc for why a single player beats
/// frame-stepping `FrameLoader`. Overlay sync publishes the pose *frame
/// index*, snapped via `PoseTimeline`, never an interpolated pose: at ¼
/// speed an interpolated skeleton would float ahead of a frame held for
/// 133ms.
@MainActor
@Observable
final class SwingPlayerController {
    private(set) var isPlaying = false
    private(set) var currentFrameIndex: Int?
    private(set) var currentTime: Double
    private(set) var activeStop: ProblemStop?

    var rate: PlaybackRate = .full {
        didSet {
            guard isPlaying, rate != oldValue else { return }
            player.playImmediately(atRate: Float(rate.rawValue))
        }
    }
    var isLooping = true
    var stopsEnabled = true

    let range: ClosedRange<Double>
    let player: AVPlayer
    var hasStops: Bool { !stops.isEmpty }

    private var timeline: PoseTimeline
    // `nonisolated(unsafe)`: touched from `deinit`, which cannot be
    // MainActor-isolated, and `@Observable`'s macro rejects a plain
    // `nonisolated` on a mutable stored property. This is only a fallback
    // for `teardown()` not having run.
    nonisolated(unsafe) private var timeObserver: Any?
    private let stops: [ProblemStop]
    /// Stops still eligible to fire. A stop is removed once crossed forward
    /// through and re-added when a seek lands at or before it — "seeking
    /// backwards re-arms stops ahead" from the plan.
    private var armedStopTimes: Set<Double>
    private var lastObservedTime: Double

    init(url: URL, range: ClosedRange<Double>, frameTimes: [Double], stops: [ProblemStop]) {
        self.range = range
        self.player = AVPlayer(url: url)
        self.player.isMuted = true
        self.timeline = PoseTimeline(times: frameTimes)
        self.stops = stops
        self.armedStopTimes = Set(stops.map(\.time))
        self.currentTime = range.lowerBound
        self.lastObservedTime = range.lowerBound

        player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        currentFrameIndex = timeline.index(at: range.lowerBound)

        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // `queue: .main` guarantees this runs on the main thread, so
            // this is a real, not assumed, MainActor context.
            MainActor.assumeIsolated {
                self?.handleTick(CMTimeGetSeconds(time))
            }
        }
    }

    func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// The one place that decides, every tick, whether we're at the end of
    /// the swing, crossing a problem stop, or just advancing — a periodic
    /// observer rather than boundary observers, which re-fire the moment
    /// playback resumes from exactly the boundary they're watching.
    private func handleTick(_ time: Double) {
        guard isPlaying else { return }

        if time >= range.upperBound {
            if isLooping {
                armedStopTimes = Set(stops.map(\.time))
                seek(to: range.lowerBound)
            } else {
                pause()
                seek(to: range.upperBound)
            }
            return
        }

        if stopsEnabled,
           let crossed = stops.first(where: {
               armedStopTimes.contains($0.time) && lastObservedTime < $0.time && time >= $0.time
           }) {
            armedStopTimes.remove(crossed.time)
            pause()
            seek(to: crossed.time)
            activeStop = crossed
            return
        }

        currentTime = time
        lastObservedTime = time
        let idx = timeline.index(at: time)
        if idx != currentFrameIndex {
            currentFrameIndex = idx
        }
    }

    func play() {
        guard !isPlaying else { return }
        if currentTime >= range.upperBound - 0.01 {
            seek(to: range.lowerBound)
        }
        activeStop = nil
        isPlaying = true
        player.playImmediately(atRate: Float(rate.rawValue))
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Tapped on the problem-stop card: acknowledge and resume.
    func dismissActiveStop() {
        activeStop = nil
        play()
    }

    /// Scrubbing, and the initial/looped seek. Any stop at or after the
    /// landing point is (re)armed — the user may be about to play through
    /// one they already saw.
    func seek(to time: Double) {
        let clamped = min(max(time, range.lowerBound), range.upperBound)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        lastObservedTime = clamped
        currentFrameIndex = timeline.index(at: clamped)
        activeStop = nil
        for stop in stops where stop.time >= clamped {
            armedStopTimes.insert(stop.time)
        }
    }
}
