import Foundation

/// Watches a live stream of `PoseFrame`s (from `LivePracticeSession`'s
/// throttled live pose sampling) and reports when a swing has just
/// finished, so Practice mode can hand the covering footage to the same
/// `AnalysisPipeline` used for imported clips.
///
/// Deliberately **not** a reimplementation of `SwingWindowScanner`'s
/// algorithm. Its `findCandidates(signal:tuning:)` already does exactly what
/// a live detector needs — find a genuine top (a lift peak immediately
/// followed by a downswing burst, not a finish) and grow outward until
/// quiet is found on both sides — the only thing it can't do unmodified is
/// normalize against a *whole clip's* peak energy, because a live buffer
/// has no "whole clip."
///
/// The fix here isn't a separate calibration phase: this actor keeps a
/// bounded rolling buffer (a live clip is never more than `bufferDuration`
/// seconds old) and simply re-runs the existing, untouched batch algorithm
/// against *that* buffer on every frame. Because the buffer only ever spans
/// a swing's own recent history, its "clip-wide peak energy" is naturally
/// the swing's own burst — an adaptive floor for free, with zero new
/// threshold logic to get wrong, and zero risk of drifting out of sync with
/// the offline scanner the way two independent implementations would.
///
/// One live-specific wrinkle: offline, "ran out of signal" and "found
/// genuine quiet" can't be confused, because the whole clip is already
/// there — `growForwards` returning a window whose end sits at the buffer's
/// very last frame looks, from timing alone, identical to a window that
/// genuinely confirmed quiet just before running out of frames (a real
/// swing's own trailing padding can be under 0.1s, so a timing-gap
/// heuristic can't tell them apart). `SwingCandidate.endConfirmedQuiet`
/// removes the ambiguity directly — it's `true` only when `growForwards`
/// actually found sustained quiet, `false` when it merely hit its search
/// boundary — so this only ever fires on the former.
actor StreamingSwingDetector {

    enum SwingDetectionEvent: Equatable {
        /// Watching, nothing swing-like detected yet.
        case watching
        /// A swing was detected and has genuinely finished (confirmed
        /// quiet after the burst, not just "ran out of buffered frames").
        case swingCompleted(window: ClosedRange<Double>, topTime: Double)
    }

    private let space: PoseSpace
    private let tuning: SwingWindowScanner.Tuning
    private let bufferDuration: Double

    private var buffer: [PoseFrame] = []
    private var continuation: AsyncStream<SwingDetectionEvent>.Continuation?

    init(space: PoseSpace,
        bufferDuration: Double = 20.0,
        tuning: SwingWindowScanner.Tuning = .default) {
        self.space = space
        self.bufferDuration = bufferDuration
        self.tuning = tuning
    }

    /// Call once per session. A second call would orphan the first
    /// continuation, so `LivePracticeSession` owns exactly one of these.
    func events() -> AsyncStream<SwingDetectionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Feed one live-sampled pose frame. Cheap enough to call on every
    /// throttled sample (the buffer never holds more than `bufferDuration`
    /// seconds — a few hundred frames at most — so re-running the batch
    /// scanner against it is a small, bounded scan, not a growing cost).
    func ingest(_ frame: PoseFrame) {
        buffer.append(frame)
        while let first = buffer.first, frame.time - first.time > bufferDuration {
            buffer.removeFirst()
        }
        guard buffer.count >= 8 else { return }
        scan()
    }

    /// Clears all buffered history — call when Practice mode stops or
    /// restarts, so a stale swing from a previous session can't leak into
    /// a new one.
    func reset() {
        buffer.removeAll()
    }

    private func scan() {
        let signal = SwingWindowScanner.buildSignal(frames: buffer, space: space)
        let candidates = SwingWindowScanner.findCandidates(signal: signal, tuning: tuning)

        guard let best = candidates.max(by: { a, b in
            a.score == b.score ? a.topTime < b.topTime : a.score < b.score
        }), best.endConfirmedQuiet else {
            continuation?.yield(.watching)
            return
        }

        continuation?.yield(.swingCompleted(window: best.range, topTime: best.topTime))

        // Drop everything through this swing so it can't be found again on
        // the next scan (no separate "already emitted" bookkeeping needed —
        // once its frames are gone, `findCandidates` simply can't
        // reconstruct the same candidate), and so this swing's
        // follow-through energy can't confuse the next swing's
        // address-quiet detection.
        buffer.removeAll { $0.time <= best.end }
    }
}
