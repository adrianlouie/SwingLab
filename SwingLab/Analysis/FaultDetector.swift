import Foundation

/// Turns the measured swing into named faults.
///
/// Two rules keep this honest:
///
///  1. Contact faults (fat, thin) are inferred from body motion, because the
///     app tracks the body and not the clubhead. They are reported as
///     tendencies with reduced confidence and the UI says so.
///  2. The golfer's shot tag re-weights what we already found. It never
///     conjures a fault the pose doesn't support — otherwise the app would just
///     be agreeing with whatever the user typed.
enum FaultDetector {

    struct Context {
        var frames: [PoseFrame]
        var positions: [DetectedPosition]
        var space: PoseSpace
        var handedness: Handedness
        var view: CameraViewType
        var frameRate: Double
        var ballOverride: JointPoint?

        func frame(_ position: SwingPosition) -> PoseFrame? {
            guard let d = positions.first(where: { $0.position == position }),
                  frames.indices.contains(d.frameIndex) else { return nil }
            return frames[d.frameIndex]
        }

        func index(_ position: SwingPosition) -> Int? {
            positions.first { $0.position == position }?.frameIndex
        }

        /// Below 60fps the downswing is only a handful of frames, so anything
        /// measured at a single instant during it is necessarily rough.
        /// Multiplies a detector's base confidence — clamping it instead would
        /// leave high-confidence findings untouched, which defeats the point.
        var instantaneousFactor: Double {
            frameRate >= 60 ? 1.0 : 0.5
        }

        func instantaneous(_ base: Double) -> Double { base * instantaneousFactor }

        /// +1 when the target is toward increasing x on screen.
        var targetSign: Double {
            switch view {
            case .faceOn: return handedness == .right ? 1 : -1
            case .downTheLine: return 0
            }
        }
    }

    // MARK: - Entry point

    static func detect(context: Context) -> [SwingFault] {
        var faults: [SwingFault] = []

        faults.append(contentsOf: [
            sway(context),
            slide(context),
            reversePivot(context),
            hangBack(context),
            earlyExtension(context),
            bodyHeightChange(context),
            casting(context),
            overTheTop(context),
        ].compactMap { $0 })

        faults.append(contentsOf: contactTendencies(context))

        // Belt-and-braces: every detector above already gates itself, but this
        // makes the rule explicit and catches it even if a detector's own
        // guard is ever loosened by mistake.
        faults = faults.filter { $0.kind.isVisible(from: context.view) }

        return faults.sorted {
            ($0.severity, $0.confidence) > ($1.severity, $1.confidence)
        }
    }

    // MARK: - Individual detectors

    /// Hips moving away from the target during the backswing instead of turning.
    static func sway(_ c: Context) -> SwingFault? {
        guard c.targetSign != 0,
              let address = c.frame(.address), let top = c.frame(.top),
              let drift = SwingGeometry.horizontalDriftSignedInches(
                joint: .root, address: address, current: top, space: c.space) else { return nil }
        let awayFromTarget = -drift * c.targetSign
        guard awayFromTarget > 2.5 else { return nil }
        return SwingFault(kind: .sway,
                          severity: awayFromTarget > 4 ? .clear : .slight,
                          confidence: 0.85,
                          evidence: [.init(label: "Hips moved away from target", value: awayFromTarget, unit: "\"")],
                          position: .top)
    }

    /// Hips sliding toward the target through impact rather than rotating.
    static func slide(_ c: Context) -> SwingFault? {
        guard case .fault(let value, let severity, let confidence) = slideContribution(c) else { return nil }
        return SwingFault(kind: .slide,
                          severity: severity,
                          confidence: confidence,
                          evidence: [.init(label: "Hips slid toward target", value: value, unit: "\"")],
                          position: .impact)
    }

    private static func slideContribution(_ c: Context) -> Contribution {
        guard c.targetSign != 0,
              let top = c.frame(.top), let impact = c.frame(.impact),
              let drift = SwingGeometry.horizontalDriftSignedInches(
                joint: .root, address: top, current: impact, space: c.space) else { return .notApplicable }
        let towardTarget = drift * c.targetSign
        guard towardTarget > 3 else { return .clean }

        // Sliding is only a fault when the hips aren't also turning — but
        // that IS a measurement (the hips genuinely didn't slide-without-
        // turning), not an inapplicable one, so it's clean, not n/a.
        var turning = false
        if let turn = impact.turn3D?.hipTurn { turning = turn > 30 }
        guard !turning else { return .clean }

        return .fault(value: towardTarget, severity: towardTarget > 5 ? .clear : .slight, confidence: 0.75)
    }

    /// Leaning toward the target at the top instead of loading into the trail side.
    ///
    /// Measured as the *change* from address, not the absolute lean. A camera
    /// that isn't perfectly square to the golfer projects their forward bend
    /// over the ball into apparent sideways lean — on real test clips that read
    /// as a 35° reverse pivot on a perfectly good top position. Differencing
    /// against address cancels that offset out.
    static func reversePivot(_ c: Context) -> SwingFault? {
        guard c.targetSign != 0,
              let top = c.frame(.top), let address = c.frame(.address),
              let topLean = SwingGeometry.spineLeanSigned(frame: top, space: c.space),
              let addressLean = SwingGeometry.spineLeanSigned(frame: address, space: c.space)
        else { return nil }
        let towardTarget = (topLean - addressLean) * c.targetSign
        guard towardTarget > 4 else { return nil }
        return SwingFault(kind: .reversePivot,
                          severity: towardTarget > 9 ? .clear : .slight,
                          confidence: 0.7,
                          evidence: [.init(label: "Spine leaning toward target at the top",
                                           value: towardTarget, unit: "°")],
                          position: .top)
    }

    /// Weight still behind the ball at impact.
    static func hangBack(_ c: Context) -> SwingFault? {
        guard case .fault(let value, let severity, let confidence) = hangBackContribution(c) else { return nil }
        return SwingFault(kind: .hangBack,
                          severity: severity,
                          confidence: confidence,
                          evidence: [.init(label: "Hips still behind address at impact", value: value, unit: "\"")],
                          position: .impact)
    }

    private static func hangBackContribution(_ c: Context) -> Contribution {
        guard c.targetSign != 0,
              let address = c.frame(.address), let impact = c.frame(.impact),
              let drift = SwingGeometry.horizontalDriftSignedInches(
                joint: .root, address: address, current: impact, space: c.space) else { return .notApplicable }
        let behind = -drift * c.targetSign
        guard behind > 1.0 else { return .clean }
        return .fault(value: behind, severity: behind > 2.5 ? .clear : .slight, confidence: c.instantaneous(0.8))
    }

    /// Spine angle standing up between the top and impact.
    static func earlyExtension(_ c: Context) -> SwingFault? {
        guard case .fault(let value, let severity, let confidence) = earlyExtensionContribution(c) else { return nil }
        return SwingFault(kind: .earlyExtension,
                          severity: severity,
                          confidence: confidence,
                          evidence: [.init(label: "Spine stood up from address", value: value, unit: "°")],
                          position: .impact)
    }

    private static func earlyExtensionContribution(_ c: Context) -> Contribution {
        guard let address = c.frame(.address), let impact = c.frame(.impact),
              let addressTilt = SwingGeometry.spineTilt(frame: address, space: c.space),
              let impactTilt = SwingGeometry.spineTilt(frame: impact, space: c.space) else { return .notApplicable }
        let stoodUp = addressTilt - impactTilt
        guard stoodUp > 6 else { return .clean }
        let severity: FaultSeverity = stoodUp > 15 ? .severe : (stoodUp > 10 ? .clear : .slight)
        return .fault(value: stoodUp, severity: severity, confidence: 0.85)
    }

    /// Whether the whole body dips or lifts through the strike, which moves the
    /// low point behind or ahead of the ball.
    static func bodyHeightChange(_ c: Context) -> SwingFault? {
        if case .fault(let value, let severity, let confidence) = bodyDropContribution(c) {
            return SwingFault(kind: .bodyDrop,
                              severity: severity,
                              confidence: confidence,
                              evidence: [.init(label: "Body lower than address at impact", value: value, unit: "% of torso")],
                              position: .impact)
        }
        if case .fault(let value, let severity, let confidence) = bodyRiseContribution(c) {
            return SwingFault(kind: .bodyRise,
                              severity: severity,
                              confidence: confidence,
                              evidence: [.init(label: "Body higher than address at impact", value: value, unit: "% of torso")],
                              position: .impact)
        }
        return nil
    }

    /// Shared by `bodyDropContribution`/`bodyRiseContribution` so the two can
    /// never disagree about when the measurement itself isn't possible.
    private static func bodyHeightChangeAmount(_ c: Context) -> Double? {
        guard let address = c.frame(.address), let impact = c.frame(.impact),
              let addressNeck = address[.neck], let impactNeck = impact[.neck],
              addressNeck.confidence > 0.3, impactNeck.confidence > 0.3,
              let torso = SwingGeometry.torsoLength(frame: address, space: c.space), torso > 0.0001
        else { return nil }
        return (impactNeck.y - addressNeck.y) / torso
    }

    private static func bodyDropContribution(_ c: Context) -> Contribution {
        guard let change = bodyHeightChangeAmount(c) else { return .notApplicable }
        guard change < -0.05 else { return .clean }
        return .fault(value: abs(change) * 100, severity: change < -0.10 ? .clear : .slight,
                     confidence: c.instantaneous(0.8))
    }

    private static func bodyRiseContribution(_ c: Context) -> Contribution {
        guard let change = bodyHeightChangeAmount(c) else { return .notApplicable }
        guard change > 0.04 else { return .clean }
        return .fault(value: change * 100, severity: change > 0.09 ? .clear : .slight,
                     confidence: c.instantaneous(0.8))
    }

    /// Loss of lag, detected by *when* hand speed peaks.
    ///
    /// In a well-sequenced swing the hands peak partway down and then slow as
    /// energy transfers to the clubhead. In a cast, they are still accelerating
    /// at the ball. This is precisely why impact must not be defined as the
    /// fastest frame — doing so would make this signal identically zero.
    static func casting(_ c: Context) -> SwingFault? {
        guard case .fault(let value, let severity, let confidence) = castingContribution(c) else { return nil }
        return SwingFault(kind: .casting,
                          severity: severity,
                          confidence: confidence,
                          evidence: [.init(label: "Hands still accelerating at impact",
                                           value: value, unit: "% of downswing left")],
                          position: .delivery)
    }

    private static func castingContribution(_ c: Context) -> Contribution {
        guard c.frameRate >= 60 else { return .notApplicable }   // 30fps can't resolve this
        guard let topIndex = c.index(.top), let impactIndex = c.index(.impact),
              impactIndex > topIndex + 2 else { return .notApplicable }

        let signal = SwingSignal.build(frames: c.frames, space: c.space)
        var peakIndex = topIndex
        var peakSpeed = -Double.infinity
        for i in topIndex...impactIndex {
            guard let s = signal.speed[i] else { continue }
            if s > peakSpeed { peakSpeed = s; peakIndex = i }
        }
        let total = signal.times[impactIndex] - signal.times[topIndex]
        guard total > 0 else { return .notApplicable }
        let lagIndex = (signal.times[impactIndex] - signal.times[peakIndex]) / total
        guard lagIndex <= 0.15 else { return .clean }

        return .fault(value: lagIndex * 100, severity: lagIndex <= 0.05 ? .clear : .slight, confidence: 0.65)
    }

    /// Hands outside the ideal plane coming down. Needs the *signed* deviation:
    /// the unsigned version cannot tell over-the-top from under-plane at all.
    static func overTheTop(_ c: Context) -> SwingFault? {
        guard c.view == .downTheLine,
              let address = c.frame(.address), let delivery = c.frame(.delivery),
              let plane = SwingGeometry.planeLine(address: address, handedness: c.handedness,
                                                  space: c.space, ballOverride: c.ballOverride),
              let hands = delivery.handsCenter else { return nil }

        let signed = SwingGeometry.planeDeviationSigned(point: hands, ball: plane.ball,
                                                        shoulder: plane.shoulder, space: c.space)
        // Positive cross product means left of the ball→shoulder direction;
        // for a right-hander filmed down the line that is the outside.
        let outside = signed * (c.handedness == .right ? 1 : -1)
        guard outside > 8 else { return nil }
        let severity: FaultSeverity = outside > 22 ? .severe : (outside > 14 ? .clear : .slight)
        return SwingFault(kind: .overTheTop,
                          severity: severity,
                          confidence: c.ballOverride == nil ? 0.55 : 0.8,
                          evidence: [.init(label: "Hands outside the plane line", value: outside, unit: "%")],
                          position: .delivery)
    }

    // insideOut (the mirror of overTheTop, based on hand-travel direction
    // rather than delivery position) was retired: per-user feedback it was
    // penalizing swings that weren't actually wrong. `SwingFaultKind.insideOut`
    // stays defined (its `isVisible` returns false unconditionally) purely
    // so an already-stored analysis from before this decodes without error —
    // see the comment there.

    // MARK: - Contact tendencies

    /// One contributor's outcome, tri-state rather than optional: an
    /// optional can't tell "this camera view/frame rate can't measure this
    /// at all" apart from "measured it, swing was clean" — and those two
    /// have to be treated differently by `renormalizedScore` below, or a
    /// down-the-line clip (where hang-back and slide are unmeasurable, since
    /// they need lateral motion toward a target the camera is looking down)
    /// silently scores as if it had been measured and found spotless.
    private enum Contribution {
        case notApplicable
        case clean
        case fault(value: Double, severity: FaultSeverity, confidence: Double)

        var appliesToRenormalization: Bool {
            if case .notApplicable = self { return false }
            return true
        }

        var strength: Double {
            guard case .fault(_, let severity, _) = self else { return 0 }
            switch severity {
            case .slight: return 0.5
            case .clear: return 0.8
            case .severe: return 1.0
            }
        }
    }

    /// Weighted mean over only the contributors that were actually
    /// evaluable. Excluding not-applicable contributors from BOTH the
    /// numerator and the denominator — rather than counting them as zero,
    /// which is what the fixed weights used to do — is what makes fat
    /// detection possible at all on a down-the-line clip: two of its three
    /// inputs (hang-back, needs a target direction; casting, needs 60fps)
    /// can be simultaneously unmeasurable there, and the old fixed weights
    /// capped the maximum possible score under the firing threshold no
    /// matter how strong the one remaining input was.
    private static func renormalizedScore(_ contributors: [(Contribution, weight: Double)]) -> Double? {
        let applicable = contributors.filter { $0.0.appliesToRenormalization }
        let totalWeight = applicable.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let weighted = applicable.reduce(0.0) { $0 + $1.0.strength * $1.weight }
        return weighted / totalWeight
    }

    /// Fat and thin come from where the club bottoms out, which we can't see.
    /// What we can see is the body pattern that produces each, so these are
    /// reported as tendencies at reduced confidence.
    static func contactTendencies(_ c: Context) -> [SwingFault] {
        var out: [SwingFault] = []

        let fatContributors: [(Contribution, weight: Double)] = [
            (hangBackContribution(c), 0.40),
            (bodyDropContribution(c), 0.35),
            (castingContribution(c), 0.25),
        ]
        if let fatScore = renormalizedScore(fatContributors), fatScore >= 0.5 {
            out.append(SwingFault(kind: .fatTendency,
                                  severity: fatScore > 0.75 ? .clear : .slight,
                                  confidence: c.instantaneous(0.6),
                                  evidence: [.init(label: "Pattern strength", value: fatScore * 100, unit: "%")],
                                  position: .impact))
        }

        let thinContributors: [(Contribution, weight: Double)] = [
            (bodyRiseContribution(c), 0.45),
            (earlyExtensionContribution(c), 0.40),
            (slideContribution(c), 0.15),
        ]
        if let thinScore = renormalizedScore(thinContributors), thinScore >= 0.5 {
            out.append(SwingFault(kind: .thinTendency,
                                  severity: thinScore > 0.75 ? .clear : .slight,
                                  confidence: c.instantaneous(0.6),
                                  evidence: [.init(label: "Pattern strength", value: thinScore * 100, unit: "%")],
                                  position: .impact))
        }
        return out
    }

    // MARK: - Reconciling with what actually happened

    /// Raises the confidence of faults that explain the reported miss and
    /// lowers ones that contradict it, then re-ranks. Never adds a fault that
    /// wasn't detected — a diagnosis has to come from the swing, not the tag.
    static func reconcile(faults: [SwingFault], with result: ShotResult) -> [SwingFault] {
        guard result != .unknown, result != .flushed else { return faults }
        let supporting = Set(result.associatedFaults)
        let contradicting: Set<SwingFaultKind> = {
            switch result {
            case .fat: return [.thinTendency, .bodyRise]
            case .thin, .topped: return [.fatTendency, .bodyDrop]
            default: return []
            }
        }()

        return faults.map { fault in
            var adjusted = fault
            if supporting.contains(fault.kind) || (result.associatedFaults.contains { $0 == fault.kind }) {
                adjusted.confidence = min(0.95, fault.confidence * 1.4)
            } else if contradicting.contains(fault.kind) {
                adjusted.confidence = fault.confidence * 0.5
            }
            return adjusted
        }
        .filter { $0.confidence >= 0.25 }
        .sorted { ($0.confidence, $0.severity) > ($1.confidence, $1.severity) }
    }
}
