import Foundation

/// Deterministic coaching engine — always available, fully offline.
/// Mirrors what the LLM coach produces: one strength, then the biggest
/// faults with a concrete feel/drill each.
enum RulesCoach {

    static func coaching(for metrics: [MetricResult],
                         faults: [SwingFault] = [],
                         shotResult: ShotResult = .unknown,
                         shotType: ShotType,
                         overallScore: Double,
                         frameRate: Double = 60) -> String {
        guard !metrics.isEmpty || !faults.isEmpty else {
            return "Not enough of your body was visible to coach this swing. Try filming again from 10–15 feet with your whole body in frame."
        }

        var lines: [String] = []

        // Lead with a strength.
        if let best = metrics.filter({ $0.status == .good }).max(by: { $0.weight < $1.weight }) {
            lines.append(strengthLine(for: best))
        } else {
            lines.append("Score of \(Int(overallScore)) — plenty to build on. Let's tackle the big rocks first.")
        }

        // Named faults come before raw measurements: a fault is the diagnosis,
        // a metric is only the evidence behind it. Only firm findings reach
        // coaching — a low-confidence read isn't reliable enough to state as
        // advice, independent of whether the golfer has chosen to see it in
        // the on-screen "Lower-Confidence Reads" list.
        let ranked = FaultDetector.reconcile(faults: faults, with: shotResult)
            .filter { FaultDisplay.isFirm($0) }
            .prefix(2)
        for fault in ranked {
            lines.append(faultAdvice(fault, shotResult: shotResult))
        }

        // Top up with metric tips only if the faults didn't fill the space.
        let remaining = max(0, 3 - ranked.count)
        if remaining > 0 {
            let worst = metrics.filter { $0.status == .needsWork }
                .sorted { abs($0.delta) * $0.weight > abs($1.delta) * $1.weight }
                .prefix(remaining)
            for metric in worst {
                lines.append(tip(for: metric))
            }
            if ranked.isEmpty && worst.isEmpty {
                lines.append("This one's inside the model-pro windows across the board — great swing. Save it as a reference and try to repeat it.")
            }
        }

        return lines.joined(separator: "\n\n")
    }

    /// One fault, explained and turned into something to feel.
    static func faultAdvice(_ fault: SwingFault, shotResult: ShotResult) -> String {
        var text = "\(fault.kind.title) (\(fault.severity.label.lowercased()))"
        if fault.kind.isTendency {
            text += " — inferred from your body, not the strike itself"
        }
        text += ". \(fault.kind.plainExplanation) \(fault.kind.feel)"

        // Tie it to the miss the golfer actually reported.
        if shotResult != .unknown, shotResult != .flushed,
           shotResult.associatedFaults.contains(fault.kind) {
            text += " That's the usual cause of the \(shotResult.rawValue.lowercased()) you logged."
        }
        return text
    }

    private static func strengthLine(for m: MetricResult) -> String {
        switch m.kind {
        case .spineTilt: return "Nice setup — your spine angle of \(m.measured)° is right in the model-pro window."
        case .postureChange: return "You're keeping your posture beautifully — only \(m.measured)° of change from address."
        case .shoulderTurn: return "Great coil — \(m.measured)° of shoulder turn is right where the pros live."
        case .hipTurn: return "Your hip turn of \(m.measured)° is spot on."
        case .xFactor: return "Excellent separation — \(m.measured)° of X-factor stores real power."
        case .headDrift: return "Your head is rock steady — only \(m.measured)\" of drift."
        case .hipSway: return "You're rotating, not sliding — hip sway is just \(m.measured)\"."
        case .planeDeviation: return "Your hands are tracking the swing plane nicely on the way down."
        case .swingPath: return "Your path into impact is neutral — right along the plane line, neither in-to-out nor over the top."
        }
    }

    private static func tip(for m: MetricResult) -> String {
        let over = m.delta > 0
        switch m.kind {
        case .spineTilt:
            return over
            ? "You're tilted over \(m.measured)° at \(m.position.rawValue) — a touch too bent (ideal \(Int(m.idealLow))–\(Int(m.idealHigh))°). Stand a hair taller and let your arms hang under your shoulders."
            : "You're standing a bit too tall at \(m.position.rawValue) (\(m.measured)° vs \(Int(m.idealLow))–\(Int(m.idealHigh))°). Bow forward from the hips, not the waist, until your arms hang freely."
        case .postureChange:
            return "Your spine angle changed \(m.measured)° from address at \(m.position.rawValue) — that's early extension territory (keep it under \(Int(m.idealHigh))°). Drill: practice with your rear end brushing a wall or chair through the strike."
        case .shoulderTurn:
            return over
            ? "You're over-turning — \(m.measured)° of shoulder turn (ideal \(Int(m.idealLow))–\(Int(m.idealHigh))°). Feel like the backswing stops when your lead shoulder reaches your chin."
            : "Your shoulder turn is \(m.measured)° — a little short of the \(Int(m.idealLow))–\(Int(m.idealHigh))° window. Feel like your back faces the target at the top; let your lead heel ease up if you need the room."
        case .hipTurn:
            return over
            ? "Your hips are turning \(m.measured)° — too much (ideal \(Int(m.idealLow))–\(Int(m.idealHigh))°), which drains your coil. Feel your trail knee stay flexed and quiet going back."
            : "Your hips only turned \(m.measured)° (ideal \(Int(m.idealLow))–\(Int(m.idealHigh))°). Let your trail hip work behind you going back so the shoulders don't have to do all the work."
        case .xFactor:
            return over
            ? "Your X-factor of \(m.measured)° is beyond the \(Int(m.idealLow))–\(Int(m.idealHigh))° window — that's a lot of strain. Let your hips turn a touch more with the shoulders."
            : "Your X-factor is \(m.measured)° — less separation than the \(Int(m.idealLow))–\(Int(m.idealHigh))° ideal. Feel your shoulders keep turning after your hips stop; that stretch is free speed."
        case .headDrift:
            return "Your head drifted about \(m.measured)\" at \(m.position.rawValue) (keep it under \(m.idealHigh)\"). Pick a spot on the ball and keep your nose pointed at it — turn around your spine, don't slide along it."
        case .hipSway:
            return "Your hips slid about \(m.measured)\" sideways at \(m.position.rawValue) instead of rotating (ideal under \(m.idealHigh)\"). Feel like you rotate around your lead hip — a wall or alignment stick just outside your trail hip is a great drill."
        case .planeDeviation:
            return "Your hands are \(m.measured)% off the swing-plane line in the delivery zone. Rehearse slow-motion downswings feeling the hands drop to the plane line before you rotate through."
        case .swingPath:
            return over
            ? "Your hands are moving \(m.measured)° toward the outside of the plane coming into impact (ideal \(Int(m.idealLow))–\(Int(m.idealHigh))°) — an over-the-top path. Feel the club drop straight down as your first move from the top."
            : "Your hands are moving \(m.measured)° toward the inside of the plane coming into impact (ideal \(Int(m.idealLow))–\(Int(m.idealHigh))°) — an in-to-out path. Feel your trail elbow stay closer to your side as you start down."
        }
    }
}
