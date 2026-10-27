import AVFoundation

/// Reads steps aloud with the iOS system voice (HACKATHON.md, Approved Exceptions, 2026-10-27).
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        // Playback, so the steps are heard even with the ring/silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func speak(_ text: String, voice: String) {
        synthesizer.stopSpeaking(at: .immediate)
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voice)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92  // a little slower for older listeners
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
