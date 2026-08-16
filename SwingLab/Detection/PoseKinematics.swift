import Foundation

/// Per-frame hand/lift kinematics shared by every signal built over a swing
/// window — the coarse window-finding scan (`SwingWindowScanner`), the
/// full-rate position detector (`SwingSignal`), and the live streaming
/// detector (`StreamingSwingDetector`).
///
/// Extracted because this exact formula — hand position relative to the
/// hip-root, scaled by torso length, plus hand height above the neck — used
/// to be copy-pasted between `SwingWindowScanner.buildSignal` and
/// `SwingSignal.build`. That's exactly how the peak-grouping-order bug this
/// session found happened: two "almost the same" implementations drifting
/// apart. Downstream processing (smoothing, differencing, gap-filling) stays
/// separate on purpose — the coarse scan wants a raw, responsive signal at
/// 12Hz, while full-rate detection wants Vision's noise/dropouts smoothed
/// out — only the raw per-frame extraction is shared.
enum PoseKinematics {
    struct FrameKinematics {
        /// Hand position relative to the hip-root, scaled by torso length.
        var handsBody: (x: Double, y: Double)?
        /// Hand height above the neck, in torso lengths. Positive means the
        /// hands are higher than the shoulders — a backswing.
        var lift: Double?
        /// Shoulder height relative to the hips, in torso lengths.
        var shoulderHeight: Double?
        /// 0...1 confidence that this frame's pose is usable.
        var quality: Double
    }

    /// Median torso length across the frames — a robust, clip-wide body
    /// scale beats per-frame measurement, which jitters as joints flicker.
    static func medianTorsoScale(frames: [PoseFrame], space: PoseSpace) -> Double {
        let torsos = frames.compactMap { SwingGeometry.torsoLength(frame: $0, space: space) }
            .filter { $0 > 0.0001 }
        guard !torsos.isEmpty else { return 0.1 }
        let sorted = torsos.sorted()
        return sorted[sorted.count / 2]
    }

    /// Hand-relative-to-root position, lift, shoulder height, and quality
    /// for one frame, given an already-computed clip-wide `scale`.
    static func frameKinematics(frame: PoseFrame, space: PoseSpace, scale: Double,
                                wristConfidence: Double = 0.3) -> FrameKinematics {
        let joints = frame.joints.filter { $0.value.confidence > 0.3 }
        let quality = min(1.0, Double(joints.count) / 12.0)

        guard let hands = frame.handsCenter(minConfidence: wristConfidence),
              let root = frame[.root], root.confidence > 0.3 else {
            return FrameKinematics(handsBody: nil, lift: nil, shoulderHeight: nil, quality: quality)
        }
        let hx = space.isoX(hands.x - root.x) / scale
        let hy = (hands.y - root.y) / scale

        guard let neck = frame[.neck], neck.confidence > 0.3 else {
            return FrameKinematics(handsBody: (hx, hy), lift: nil, shoulderHeight: nil, quality: quality)
        }
        let lift = (hands.y - neck.y) / scale
        let shoulderHeight = (neck.y - root.y) / scale
        return FrameKinematics(handsBody: (hx, hy), lift: lift, shoulderHeight: shoulderHeight, quality: quality)
    }
}
