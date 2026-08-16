import Foundation
import AVFoundation
import Vision
import simd

/// Measures body rotation with Apple's 3D body pose.
///
/// Shoulder and hip turn were previously *inferred* from how much the shoulder
/// line foreshortens on a flat image — consistent enough to track over time,
/// but not a real angle. `VNDetectHumanBodyPose3DRequest` returns joints with
/// depth, so the rotation can be measured directly.
///
/// The 3D request is far heavier than the 2D one, so it runs only on the
/// detected key frames — a handful per swing rather than hundreds. Everything
/// falls back to the 2D estimate when 3D is unavailable, and each number is
/// labelled with where it came from so nothing is silently mixed.
struct Pose3DExtractor {

    struct Measurement {
        var time: Double
        var shoulderAxis: SIMD2<Double>   // horizontal direction of the shoulder line
        var hipAxis: SIMD2<Double>
        var spineTilt: Double             // degrees off vertical
    }

    /// True when this device can run 3D body pose at all.
    static var isSupported: Bool {
        if #available(iOS 17.0, macOS 14.0, *) { return true }
        return false
    }

    /// Measures the given times. Returns only the frames that succeeded, so a
    /// partial result is still useful.
    func measure(url: URL, at times: [Double]) async -> [Measurement] {
        guard Self.isSupported, !times.isEmpty else { return [] }
        guard #available(iOS 17.0, macOS 14.0, *) else { return [] }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

        var results: [Measurement] = []
        for time in times {
            guard let cgImage = try? await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }

            let request = VNDetectHumanBodyPose3DRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first else { continue }
            guard let measurement = Self.measurement(from: observation, time: time) else { continue }
            results.append(measurement)
        }
        return results
    }

    @available(iOS 17.0, macOS 14.0, *)
    static func measurement(from observation: VNHumanBodyPose3DObservation,
                            time: Double) -> Measurement? {
        func position(_ joint: VNHumanBodyPose3DObservation.JointName) -> SIMD3<Double>? {
            guard let point = try? observation.recognizedPoint(joint) else { return nil }
            let m = point.position
            return SIMD3(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z))
        }

        guard let leftShoulder = position(.leftShoulder),
              let rightShoulder = position(.rightShoulder),
              let leftHip = position(.leftHip),
              let rightHip = position(.rightHip) else { return nil }

        // Rotation lives in the horizontal plane, so drop the vertical axis.
        let shoulderAxis = horizontalAxis(from: leftShoulder, to: rightShoulder)
        let hipAxis = horizontalAxis(from: leftHip, to: rightHip)

        // Spine tilt straight from 3D, no foreshortening to correct for.
        let shoulderCentre = (leftShoulder + rightShoulder) / 2
        let hipCentre = (leftHip + rightHip) / 2
        let spine = shoulderCentre - hipCentre
        let horizontal = (spine.x * spine.x + spine.z * spine.z).squareRoot()
        let tilt = atan2(horizontal, abs(spine.y)) * 180 / .pi

        return Measurement(time: time, shoulderAxis: shoulderAxis, hipAxis: hipAxis, spineTilt: tilt)
    }

    private static func horizontalAxis(from a: SIMD3<Double>, to b: SIMD3<Double>) -> SIMD2<Double> {
        let v = SIMD2(b.x - a.x, b.z - a.z)
        let length = (v.x * v.x + v.y * v.y).squareRoot()
        guard length > 1e-6 else { return SIMD2(1, 0) }
        return v / length
    }

    /// Turn of one axis relative to its address orientation, 0...180 degrees.
    static func turnAngle(address: SIMD2<Double>, current: SIMD2<Double>) -> Double {
        let dot = max(-1, min(1, address.x * current.x + address.y * current.y))
        return acos(dot) * 180 / .pi
    }

    /// Converts a set of measurements into per-position turn values, all
    /// relative to the address measurement.
    static func turns(from measurements: [Measurement]) -> [Double: BodyTurn3D] {
        guard let address = measurements.min(by: { $0.time < $1.time }) else { return [:] }
        var out: [Double: BodyTurn3D] = [:]
        for m in measurements {
            out[m.time] = BodyTurn3D(
                shoulderTurn: turnAngle(address: address.shoulderAxis, current: m.shoulderAxis),
                hipTurn: turnAngle(address: address.hipAxis, current: m.hipAxis),
                spineTilt: m.spineTilt)
        }
        return out
    }
}
