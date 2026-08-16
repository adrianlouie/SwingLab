import AVFoundation

/// Speaks one short callout after each detected swing during Practice mode.
/// Deliberately thin: it builds a sentence from the *existing*
/// `SwingFaultKind.title`, the same words `ResultsView`'s fault cards and
/// `RulesCoach`'s prose already use, rather than inventing a second
/// vocabulary that could drift from what the results screen says about the
/// same swing.
@MainActor
final class PracticeAnnouncer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    /// Picks the single firmest fault (never a lower-confidence one — same
    /// bar `RulesCoach`/`Coach` hold coaching text to, via `FaultDisplay.isFirm`)
    /// and speaks its name and where it happened. Says something reassuring
    /// when nothing firm was found, rather than staying silent — silence
    /// after a swing reads as "didn't hear it," not "looked good."
    func announce(faults: [SwingFault]?, overallScore: Double) {
        let firm = (faults ?? []).filter(FaultDisplay.isFirm)
        let worst = firm.max { a, b in
            // Severity first, confidence to break ties — mirrors how
            // `ResultsView.faultsSection` orders the same list.
            if a.severity != b.severity { return a.severity < b.severity }
            return a.confidence < b.confidence
        }

        let sentence: String
        if let worst {
            if let position = worst.position {
                sentence = "\(worst.kind.title) at \(position.rawValue)."
            } else {
                sentence = worst.kind.title + "."
            }
        } else {
            sentence = "Good swing — nothing firm to flag."
        }
        speak(sentence)
    }

    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}
