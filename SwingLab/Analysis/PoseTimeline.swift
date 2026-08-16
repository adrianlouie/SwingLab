import Foundation

/// Maps a player's current time to the nearest `PoseFrame` index, cheaply.
///
/// Playback is monotonic almost all the time, so the common case is a cursor
/// walking forward one step per call — O(1) amortized. A seek (backward jump,
/// or a forward jump bigger than a handful of frames) falls back to a binary
/// search instead of walking the whole gap one frame at a time.
struct PoseTimeline {
    /// Must be sorted ascending. `PoseFrame.time` already is (presentation
    /// timestamps), so callers pass that straight through.
    let times: [Double]
    private var cursor: Int = 0

    init(times: [Double]) {
        self.times = times
    }

    /// The frame index nearest `t`, or nil when `t` falls outside the covered
    /// span — the overlay draws nothing rather than pinning a stale skeleton
    /// onto a moving body.
    mutating func index(at t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        let epsilon = 0.02
        guard t >= times[0] - epsilon, t <= times[times.count - 1] + epsilon else { return nil }

        cursor = min(max(cursor, 0), times.count - 1)

        // A big gap between where we were and where we're asked to be means a
        // seek happened; walking there one frame at a time would be wasteful
        // (and, worse, `O(n)` per call during a scrub).
        if abs(times[cursor] - t) > 0.5 {
            cursor = binarySearchNearest(t)
            return cursor
        }

        while cursor < times.count - 1, times[cursor + 1] <= t {
            cursor += 1
        }
        while cursor > 0, times[cursor] > t {
            cursor -= 1
        }

        // Landed one frame short is common (times[cursor] <= t < times[cursor+1]);
        // pick whichever neighbour is actually closer.
        if cursor < times.count - 1, abs(times[cursor + 1] - t) < abs(times[cursor] - t) {
            cursor += 1
        }
        return cursor
    }

    /// Current cursor without moving it — for tests and diagnostics.
    var currentIndex: Int { cursor }

    private func binarySearchNearest(_ t: Double) -> Int {
        var lo = 0
        var hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // `lo` is the first index with times[lo] >= t; compare against its
        // left neighbour to find the truly nearest one.
        if lo > 0, abs(times[lo - 1] - t) <= abs(times[lo] - t) {
            return lo - 1
        }
        return lo
    }
}
