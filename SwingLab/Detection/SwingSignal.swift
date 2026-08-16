import Foundation

/// The motion signal phase detection reads, built once and shared.
///
/// Everything here is **body-relative and time-based**. The previous version
/// worked in raw image units with frame-count windows, which meant its
/// smoothing spanned 167ms at 30fps but only 21ms at 240fps, and a golfer
/// standing closer to the camera produced larger "speeds" than one standing
/// far away. Normalising by torso length and expressing every threshold in
/// seconds removes both problems.
struct SwingSignal {

    struct Tuning {
        /// Positional smoothing width.
        var smoothingSigma = 0.030
        /// Half-width of the central difference used for velocity.
        var velocityHalfWidth = 0.040
        /// Pose gaps up to this long are interpolated; longer ones stay unknown.
        var maximumGapToFill = 0.15
        /// Minimum wrist confidence for the hands to count as tracked.
        var wristConfidence = 0.3
        static let `default` = Tuning()
    }

    var times: [Double]
    /// Hand position relative to the hips, in torso lengths.
    var hands: [(x: Double, y: Double)?]
    /// Speed of `hands`, torso lengths per second.
    var speed: [Double?]
    /// Velocity of `hands`.
    var velocity: [(x: Double, y: Double)?]
    /// Hand height above the neck, in torso lengths. Positive = above shoulders.
    var lift: [Double?]
    /// Shoulder height relative to the hips, for the shoulder-line crossings.
    var shoulderHeight: [Double?]
    /// 0...1 confidence that this frame's pose is usable.
    var quality: [Double]
    var scale: Double

    var count: Int { times.count }

    /// Peak speed across the whole signal.
    var peakSpeed: Double { speed.compactMap { $0 }.max() ?? 0 }

    func duration(from a: Int, to b: Int) -> Double {
        guard times.indices.contains(a), times.indices.contains(b) else { return 0 }
        return times[b] - times[a]
    }

    // MARK: - Construction

    static func build(frames: [PoseFrame],
                      space: PoseSpace,
                      tuning: Tuning = .default) -> SwingSignal {
        let times = frames.map(\.time)
        let scale = PoseKinematics.medianTorsoScale(frames: frames, space: space)

        var rawHands: [(x: Double, y: Double)?] = []
        var lift: [Double?] = []
        var shoulderHeight: [Double?] = []
        var quality: [Double] = []

        for frame in frames {
            let k = PoseKinematics.frameKinematics(frame: frame, space: space, scale: scale,
                                                    wristConfidence: tuning.wristConfidence)
            rawHands.append(k.handsBody)
            lift.append(k.lift)
            shoulderHeight.append(k.shoulderHeight)
            quality.append(k.quality)
        }

        let filled = fillShortGaps(rawHands, times: times, maximumGap: tuning.maximumGapToFill)
        let smoothed = gaussianSmooth(filled, times: times, sigma: tuning.smoothingSigma)
        let velocity = centralDifference(smoothed, times: times, halfWidth: tuning.velocityHalfWidth)
        let speed = velocity.map { v -> Double? in
            guard let v else { return nil }
            return (v.x * v.x + v.y * v.y).squareRoot()
        }

        return SwingSignal(times: times, hands: smoothed, speed: speed, velocity: velocity,
                           lift: lift, shoulderHeight: shoulderHeight,
                           quality: quality, scale: scale)
    }

    // MARK: - Signal processing

    /// Bridges brief tracking dropouts. Anything longer stays nil, so it can be
    /// excluded rather than silently reading as "not moving" — the old code
    /// wrote zero here, which made dropouts look like the calmest, most
    /// address-like part of the clip.
    static func fillShortGaps(_ values: [(x: Double, y: Double)?],
                              times: [Double],
                              maximumGap: Double) -> [(x: Double, y: Double)?] {
        var out = values
        var i = 0
        while i < out.count {
            guard out[i] == nil else { i += 1; continue }
            let gapStart = i
            var gapEnd = i
            while gapEnd < out.count, out[gapEnd] == nil { gapEnd += 1 }

            let before = gapStart - 1
            let after = gapEnd
            if before >= 0, after < out.count,
               let a = out[before], let b = out[after],
               times[after] - times[before] <= maximumGap {
                let span = times[after] - times[before]
                for j in gapStart..<gapEnd {
                    let t = span > 0 ? (times[j] - times[before]) / span : 0
                    out[j] = (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                }
            }
            i = gapEnd
        }
        return out
    }

    /// Time-weighted smoothing, so behaviour is identical at 30 and 240 fps.
    static func gaussianSmooth(_ values: [(x: Double, y: Double)?],
                               times: [Double],
                               sigma: Double) -> [(x: Double, y: Double)?] {
        guard sigma > 0 else { return values }
        let cutoff = sigma * 3
        var out = values
        for i in values.indices where values[i] != nil {
            var sumX = 0.0, sumY = 0.0, sumW = 0.0
            var j = i
            while j >= 0, times[i] - times[j] <= cutoff {
                if let v = values[j] {
                    let dt = times[i] - times[j]
                    let w = exp(-(dt * dt) / (2 * sigma * sigma))
                    sumX += v.x * w; sumY += v.y * w; sumW += w
                }
                j -= 1
            }
            j = i + 1
            while j < values.count, times[j] - times[i] <= cutoff {
                if let v = values[j] {
                    let dt = times[j] - times[i]
                    let w = exp(-(dt * dt) / (2 * sigma * sigma))
                    sumX += v.x * w; sumY += v.y * w; sumW += w
                }
                j += 1
            }
            if sumW > 0 { out[i] = (sumX / sumW, sumY / sumW) }
        }
        return out
    }

    static func centralDifference(_ values: [(x: Double, y: Double)?],
                                  times: [Double],
                                  halfWidth: Double) -> [(x: Double, y: Double)?] {
        var out: [(x: Double, y: Double)?] = Array(repeating: nil, count: values.count)
        for i in values.indices {
            guard values[i] != nil else { continue }
            var lo = i, hi = i
            while lo > 0, times[i] - times[lo] < halfWidth { lo -= 1 }
            while hi < values.count - 1, times[hi] - times[i] < halfWidth { hi += 1 }
            guard let a = values[lo], let b = values[hi] else { continue }
            let dt = times[hi] - times[lo]
            guard dt > 0 else { continue }
            out[i] = ((b.x - a.x) / dt, (b.y - a.y) / dt)
        }
        return out
    }
}
