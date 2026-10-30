import AVFoundation

/// Short sounds for what doesn't need words: the microphone opening, a correct check, a finished task. The tones are made
/// here, so there are no sound files or licenses to follow.
final class SoundEffects {
    enum Effect: CaseIterable {
        case micOn, micOff, ready, question, correct, wrong, moved, done, notSolved

        /// (frequency in Hz, start, length), in seconds.
        var notes: [(Double, Double, Double)] {
            switch self {
            case .micOn: [(660, 0, 0.09), (990, 0.08, 0.12)]
            case .micOff: [(880, 0, 0.09), (587, 0.08, 0.13)]
            case .ready: [(1175, 0, 0.18)]
            case .question: [(784, 0, 0.12), (1047, 0.11, 0.18)]
            case .correct: [(880, 0, 0.1), (1319, 0.09, 0.22)]
            case .wrong: [(233, 0, 0.14), (196, 0.15, 0.22)]
            case .moved: [(1568, 0, 0.05)]
            case .done: [(659, 0, 0.12), (784, 0.11, 0.12), (1047, 0.22, 0.32)]
            case .notSolved: [(392, 0, 0.2), (330, 0.2, 0.32)]
            }
        }
    }

    /// A WAV of the effect's notes, each with a quick fade in and out.
    static func wav(_ effect: Effect) -> Data {
        let rate = 24_000.0
        let length = effect.notes.map { $0.1 + $0.2 }.max() ?? 0
        var samples = [Double](repeating: 0, count: Int(length * rate) + 1)
        for (frequency, start, duration) in effect.notes {
            for i in 0..<Int(duration * rate) {
                let time = Double(i) / rate
                let envelope = min(time / 0.01, 1) * pow(max(1 - time / duration, 0), 2)
                samples[Int(start * rate) + i] += sin(2 * .pi * frequency * time) * envelope * 0.3
            }
        }
        return VoiceRecorder.wav(samples: samples.map { Int16(max(min($0, 1), -1) * 32_000) }, sampleRate: Int(rate))
    }

    private var player: AVAudioPlayer?

    func play(_ effect: Effect) {
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: Self.wav(effect))
        player?.play()
    }
}
