import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Produces plain-language coaching from the measured metrics.
///
/// On iPhones with Apple Intelligence (15 Pro / 16 and later on iOS 26) this
/// uses the on-device Foundation Models LLM — free, offline, private. On any
/// other device it falls back to the deterministic rules engine, so the app
/// always produces coaching.
enum Coach {

    static func coaching(for metrics: [MetricResult],
                         faults: [SwingFault] = [],
                         shotResult: ShotResult = .unknown,
                         shotType: ShotType,
                         view: CameraViewType,
                         overallScore: Double,
                         frameRate: Double = 60) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                if let text = await llmCoaching(metrics: metrics, faults: faults,
                                                shotResult: shotResult, shotType: shotType,
                                                view: view, overallScore: overallScore) {
                    return text
                }
            default:
                break
            }
        }
        #endif
        return RulesCoach.coaching(for: metrics, faults: faults, shotResult: shotResult,
                                   shotType: shotType, overallScore: overallScore, frameRate: frameRate)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func llmCoaching(metrics: [MetricResult],
                                    faults: [SwingFault],
                                    shotResult: ShotResult,
                                    shotType: ShotType,
                                    view: CameraViewType,
                                    overallScore: Double) async -> String? {
        let outOfRange = metrics.filter { $0.status == .needsWork }
        let strengths = metrics.filter { $0.status == .good }

        var summary = "Shot type: \(shotType.rawValue). Camera: \(view.rawValue). Overall score: \(Int(overallScore))/100.\n"

        // Faults first: they are the diagnosis the coaching should lead with.
        if shotResult != .unknown {
            summary += "Ball flight reported by the golfer: \(shotResult.rawValue).\n"
        }
        // Only firm findings reach the coach — a low-confidence read isn't
        // reliable enough to state as advice, independent of the Settings
        // toggle that only controls what shows in the on-screen list.
        let firmFaults = faults.filter { FaultDisplay.isFirm($0) }
        if !firmFaults.isEmpty {
            summary += "Diagnosed faults, most confident first:\n"
            for fault in firmFaults.prefix(4) {
                let hedge = fault.kind.isTendency ? " (inferred from body motion, not measured at the strike)" : ""
                let evidence = fault.evidence.map(\.formatted).joined(separator: "; ")
                summary += "- \(fault.kind.title) [\(fault.severity.label), confidence \(String(format: "%.2f", fault.confidence))]\(hedge): \(evidence)\n"
            }
        }

        summary += "Measurements (metric @ position: measured vs ideal range):\n"
        for m in metrics {
            let flag = m.status == .good ? "GOOD" : "NEEDS WORK"
            summary += "- \(m.kind.rawValue) @ \(m.position.rawValue): \(m.measured)\(m.kind.unit) vs \(m.idealLow)–\(m.idealHigh)\(m.kind.unit) [\(flag)]\n"
        }
        summary += "\(outOfRange.count) measurements out of range, \(strengths.count) in range."

        let instructions = """
        You are a friendly, expert golf coach using the position-by-position \
        model-pro methodology. Write short, specific, encouraging coaching. \
        Start with one sentence on what's working. Then give the 2-3 most \
        important fixes, each with a concrete feel or drill (e.g. "feel like you \
        rotate around your lead hip instead of sliding"). Keep it under 160 \
        words. No headings, plain golfer language.

        The diagnosed faults are the diagnosis; the measurements are supporting \
        evidence, so lead with the faults. If a ball flight is reported, explain \
        how the named fault produces that specific miss. Never assert a fault \
        that is not in the list, and never state a tendency marked as inferred \
        as though it were measured at the strike.
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: summary)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
    #endif
}
