import AVFoundation

/// Reads steps aloud with the iOS system voice (HACKATHON.md, Approved Exceptions, 2026-10-27).
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        // Playback, so the steps are heard even with the ring/silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    /// Reads `text` in `voice`; words marked as printed on the device («warm») are read in `labelVoice`, so a Turkish
    /// voice doesn't mispronounce an English label. Each switch is a separate utterance, with a very short pause.
    func speak(_ text: String, voice: String, labelVoice: String? = nil) {
        synthesizer.stopSpeaking(at: .immediate)
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let labelVoice = labelVoice ?? voice
        let parts = labelVoice == voice
            ? [(GuideText.display(text), voice)]
            : GuideText.segments(text).map { ($0.text, $0.isLabel ? labelVoice : voice) }
        for (part, language) in parts where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92  // a little slower for older listeners
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
