import AVFoundation
import Observation

/// Drives two `AVPlayer`s in lockstep for `ComparisonView`'s synchronized
/// playback. **Phase-normalized, not wall-clock synced** — two real swings
/// are essentially never the same duration, so "5 seconds into swing A"
/// means something completely different from "5 seconds into swing B."
/// Instead both lanes are driven from one shared `progress` (0...1 through
/// each swing's own address...finish range): the primary lane's own
/// playback clock is the source of truth (via a periodic time observer,
/// same pattern `SwingPlayerController` uses), translated into `progress`,
/// which is then translated again into the secondary lane's own
/// differently-scaled range.
///
/// Deliberately NOT built on `SwingPlayerController` — that type's
/// problem-stop/pose-frame-snapping machinery is real complexity
/// comparison doesn't need (there's no per-fault auto-pause here), and
/// bolting "drive a second player in lockstep" onto a type designed around
/// owning exactly one player would be a worse fit than this small,
/// purpose-built coordinator.
@MainActor
@Observable
final class SyncedComparisonController {
    struct Lane {
        let player: AVPlayer
        let range: ClosedRange<Double>
        var duration: Double { max(range.upperBound - range.lowerBound, 0.001) }
    }

    private(set) var isPlaying = false
    /// 0...1 through the swing — the one value both lanes are actually
    /// driven from, and what a shared scrubber binds to instead of a raw
    /// seconds value that wouldn't mean the same thing in both lanes.
    private(set) var progress: Double = 0

    var rate: PlaybackRate = .full {
        didSet {
            guard isPlaying, rate != oldValue else { return }
            primary.player.playImmediately(atRate: Float(rate.rawValue))
            secondary?.player.playImmediately(atRate: Float(rate.rawValue))
        }
    }
    var isLooping = true

    // `let`, not `var`: `primary` is set once in `init` and never
    // reassigned (unlike `secondary`, which does change via
    // `setSecondary`). That's what makes direct property access from
    // `deinit` legal despite the class being `@MainActor` — Swift allows
    // touching an isolated *constant* stored property from `deinit` since
    // there's no possible concurrent access once the object is being torn
    // down, but doesn't extend that guarantee to a `var`.
    let primary: Lane
    private(set) var secondary: Lane?

    /// How far the follower is allowed to drift from where shared
    /// `progress` says it should be before getting a corrective seek —
    /// different clips' own native frame rates mean their playback clocks
    /// don't stay in lockstep for free even at the same `rate`. Small
    /// enough to stay visually synced, large enough not to fight the
    /// player with a seek almost every tick.
    private let driftTolerance = 0.08

    // `nonisolated(unsafe)`, not plain `nonisolated`: needed from `deinit`,
    // which can't be MainActor-isolated, but `@Observable`'s macro-generated
    // `ObservationTracked` storage rejects a plain `nonisolated` on a
    // mutable property with a hard compiler error — the same tradeoff
    // `SwingPlayerController.timeObserver` already accepts. The compiler's
    // own "consider using nonisolated" warning here is a false lead; do not
    // follow it, it doesn't compile.
    nonisolated(unsafe) private var timeObserver: Any?

    init(primaryURL: URL, primaryRange: ClosedRange<Double>) {
        let player = AVPlayer(url: primaryURL)
        player.isMuted = true
        self.primary = Lane(player: player, range: primaryRange)
        seekLane(primary, to: 0)

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTick(CMTimeGetSeconds(time))
            }
        }
    }

    /// The reference lane can change after init (`ComparisonView`'s
    /// reference `Picker`), so this is a method, not just an init param.
    func setSecondary(url: URL, range: ClosedRange<Double>) {
        secondary?.player.pause()
        let player = AVPlayer(url: url)
        player.isMuted = true
        let lane = Lane(player: player, range: range)
        secondary = lane
        seekLane(lane, to: progress)
    }

    func clearSecondary() {
        secondary?.player.pause()
        secondary = nil
    }

    private func handleTick(_ time: Double) {
        guard isPlaying else { return }
        let p = min(1, max(0, (time - primary.range.lowerBound) / primary.duration))

        if p >= 0.999 {
            if isLooping {
                seek(to: 0)
                play()
            } else {
                pause()
                seek(to: 1)
            }
            return
        }

        progress = p
        if let secondary {
            let target = secondary.range.lowerBound + p * secondary.duration
            let current = CMTimeGetSeconds(secondary.player.currentTime())
            if abs(current - target) > driftTolerance {
                seekLane(secondary, to: p)
            }
        }
    }

    func play() {
        guard !isPlaying else { return }
        if progress >= 0.999 { seek(to: 0) }
        isPlaying = true
        primary.player.playImmediately(atRate: Float(rate.rawValue))
        secondary?.player.playImmediately(atRate: Float(rate.rawValue))
    }

    func pause() {
        isPlaying = false
        primary.player.pause()
        secondary?.player.pause()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    /// `progress` (0...1 through the swing), not a raw seconds value — the
    /// scrubber and the position scrubber both drive playback through this,
    /// never a lane's own player time directly.
    func seek(to newProgress: Double) {
        let clamped = min(1, max(0, newProgress))
        progress = clamped
        seekLane(primary, to: clamped)
        if let secondary { seekLane(secondary, to: clamped) }
    }

    /// Jump to a *named* position, resolved independently per lane (real
    /// alignment — "both swings at Top" — rather than approximated through
    /// shared phase progress, which two different swings' own Top moments
    /// won't sit at the exact same fraction of). Falls back to whichever
    /// lane(s) actually detected the position; does nothing for a lane that
    /// didn't.
    func seekToPosition(primaryTime: Double?, secondaryTime: Double?) {
        if let primaryTime {
            let p = min(1, max(0, (primaryTime - primary.range.lowerBound) / primary.duration))
            progress = p
            seekLane(primary, to: p)
        }
        if let secondary, let secondaryTime {
            let p = min(1, max(0, (secondaryTime - secondary.range.lowerBound) / secondary.duration))
            seekLane(secondary, to: p)
        }
    }

    private func seekLane(_ lane: Lane, to progress: Double) {
        let time = lane.range.lowerBound + progress * lane.duration
        lane.player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        if let timeObserver {
            primary.player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        primary.player.pause()
        secondary?.player.pause()
    }

    deinit {
        if let timeObserver {
            primary.player.removeTimeObserver(timeObserver)
        }
    }
}
