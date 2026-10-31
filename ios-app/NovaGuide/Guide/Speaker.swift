import AVFoundation

/// Reads steps aloud with the iOS system voice (HACKATHON.md, Approved Exceptions, 2026-10-27).
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastUtterance: AVSpeechUtterance?
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        // Playback, so the steps are heard even with the ring/silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    /// Reads `text` in `voice`; words marked as printed on the device («warm») are read in `labelVoice`, so a Turkish
    /// voice doesn't mispronounce an English label. Each switch is a separate utterance, with a very short pause.
    /// `onFinish` runs when the last word has been said, not if something else interrupts it.
    func speak(_ text: String, voice: String, labelVoice: String? = nil, onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        lastUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let labelVoice = labelVoice ?? voice
        let parts = labelVoice == voice
            ? [(GuideText.display(text), voice)]
            : GuideText.segments(text).map { ($0.text, $0.isLabel ? labelVoice : voice) }
        for (part, language) in parts where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = Self.bestVoice(for: language) ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92  // a little slower for older listeners
            synthesizer.speak(utterance)
            lastUtterance = utterance
        }
    }

    /// The best voice this iPhone has for a language: Premium, then Enhanced, then the default. Users download the
    /// better ones in iOS Settings; they are still the system's voices (HACKATHON.md, Approved Exceptions).
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language.prefix(2)) && $0.quality != .default
                && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let best = candidates.max { rank($0, language) < rank($1, language) }
        return best ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(language.prefix(2)) }
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice, _ language: String) -> Int {
        voice.quality.rawValue * 2 + (voice.language == language ? 1 : 0)
    }

    /// "Yelda · Enhanced", for Settings.
    static func voiceDescription(for language: String) -> String {
        guard let voice = bestVoice(for: language) else { return "" }
        let quality = switch voice.quality {
        case .premium: String(localized: "Premium", bundle: .ui)
        case .enhanced: String(localized: "Enhanced", bundle: .ui)
        default: String(localized: "Standard", bundle: .ui)
        }
        return "\(voice.name) · \(quality)"
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === lastUtterance else { return }
        let finished = onFinish
        onFinish = nil
        DispatchQueue.main.async { finished?() }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func stop() {
        onFinish = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}
