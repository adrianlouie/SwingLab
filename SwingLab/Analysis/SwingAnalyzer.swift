import Foundation

/// Computes every applicable metric for a swing and scores it against the
/// editable ModelPro profile.
enum SwingAnalyzer {

    /// Full pipeline step: frames + detected positions → scored metrics.
    static func analyze(frames: [PoseFrame],
                        positions: [DetectedPosition],
                        profile: ModelProProfile,
                        shotType: ShotType,
                        view: CameraViewType,
                        handedness: Handedness,
                        space: PoseSpace = .square,
                        club: GolfClub? = nil,
                        ballOverride: JointPoint? = nil) -> (metrics: [MetricResult], overall: Double) {

        var metrics: [MetricResult] = []
        let targets = profile.targets(shotType: shotType, view: view)

        func frame(_ position: SwingPosition) -> PoseFrame? {
            guard let d = positions.first(where: { $0.position == position }),
                  frames.indices.contains(d.frameIndex) else { return nil }
            return frames[d.frameIndex]
        }

        guard let address = frame(.address) else { return ([], 0) }
        let addressShoulderWidth = SwingGeometry.shoulderWidth(frame: address, space: space)
        let addressHipWidth = SwingGeometry.hipWidth(frame: address, space: space)
        let addressSpine = SwingGeometry.spineTilt(frame: address, space: space)

        for target in targets {
            // Enforced here, not just at seeding: a stale or hand-edited
            // profile must never be able to reintroduce a metric the camera
            // angle can't honestly see — that's exactly what let a back-view
            // clip produce a meaningless, heavily-weighted "shoulder turn"
            // reading when it was analysed under the wrong view.
            guard target.kind.isVisible(from: view) else { continue }
            guard let current = frame(target.position) else { continue }
            var measured: Double?

            switch target.kind {
            case .spineTilt:
                measured = current.turn3D?.spineTilt
                    ?? SwingGeometry.spineTilt(frame: current, space: space)

            case .postureChange:
                if let now = SwingGeometry.spineTilt(frame: current, space: space), let base = addressSpine {
                    measured = abs(now - base)
                }

            case .shoulderTurn:
                if let measured3D = current.turn3D?.shoulderTurn {
                    measured = measured3D
                } else if let base = addressShoulderWidth,
                          let now = SwingGeometry.shoulderWidth(frame: current, space: space) {
                    measured = SwingGeometry.rotationEstimate(addressWidth: base, currentWidth: now)
                }

            case .hipTurn:
                if let measured3D = current.turn3D?.reliableHipTurn {
                    measured = measured3D
                } else if let base = addressHipWidth,
                          let now = SwingGeometry.hipWidth(frame: current, space: space) {
                    measured = SwingGeometry.rotationEstimate(addressWidth: base, currentWidth: now)
                }

            case .xFactor:
                if let turn = current.turn3D, let hip = turn.reliableHipTurn {
                    measured = turn.shoulderTurn - hip
                } else if let sBase = addressShoulderWidth,
                          let sNow = SwingGeometry.shoulderWidth(frame: current, space: space),
                          let hBase = addressHipWidth,
                          let hNow = SwingGeometry.hipWidth(frame: current, space: space),
                          let shoulder = SwingGeometry.rotationEstimate(addressWidth: sBase, currentWidth: sNow),
                          let hip = SwingGeometry.rotationEstimate(addressWidth: hBase, currentWidth: hNow) {
                    measured = shoulder - hip
                }

            case .headDrift:
                if let head = SwingGeometry.headJoint(in: address) {
                    measured = SwingGeometry.horizontalDriftInches(joint: head, address: address,
                                                                   current: current, space: space)
                }

            case .hipSway:
                measured = SwingGeometry.horizontalDriftInches(joint: .root, address: address,
                                                               current: current, space: space)

            case .planeDeviation, .swingPath:
                // Retired — `ModelProProfile.targets(shotType:view:)` never
                // hands back a target for either kind, so this is
                // unreachable in practice. The cases stay only because the
                // switch is exhaustive over `MetricKind`, which itself
                // keeps both cases for decode safety (see `ModelProProfile`
                // and `MetricKind`'s `retiredKinds`/doc comments).
                break
            }

            if let value = measured {
                let window = ClubAdjustment.adjusted(low: target.low, high: target.high,
                                                     kind: target.kind, club: club)
                metrics.append(MetricResult(kind: target.kind,
                                            position: target.position,
                                            measured: (value * 10).rounded() / 10,
                                            idealLow: window.low,
                                            idealHigh: window.high,
                                            weight: target.weight))
            }
        }

        let overall = overallScore(metrics: metrics)
        return (metrics, overall)
    }

    /// Weighted mean of all metric scores, 0–100.
    static func overallScore(metrics: [MetricResult]) -> Double {
        let totalWeight = metrics.map(\.weight).reduce(0, +)
        guard totalWeight > 0 else { return 0 }
        let weighted = metrics.map { $0.score * $0.weight }.reduce(0, +)
        return (weighted / totalWeight).rounded()
    }
}
