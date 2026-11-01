import AVFoundation

/// Records one utterance after the user taps the microphone: 24 kHz mono WAV, in memory only. It stops when the user
/// taps again, after a short silence once speech was heard, or at a time limit. The microphone is never open
/// otherwise (project rules, design rule 6).
final class VoiceRecorder: ObservableObject {
    static let sampleRate = 24_000.0  // what Meta's realtime endpoint takes
    static let maxSeconds = 20.0
    static let silenceSeconds = 1.5
    /// With live transcription Meta finds the end of the turn; this is only the backstop.
    static let liveSilenceSeconds = 3.0
    static let noSpeechSeconds = 6.0
    static let speechLevel: Float = 0.04  // RMS of normalized samples that counts as speech

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0  // 0-1, for the waveform

    /// Called on the main queue with the WAV, or nil when no speech was heard.
    var onFinish: ((Data?) -> Void)?
    /// Called on the audio thread with each chunk of 16-bit PCM, for live transcription.
    var onPCM: ((Data) -> Void)?
    var silenceSeconds = VoiceRecorder.silenceSeconds

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var startedAt = Date()
    private var lastSpeechAt: Date?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: target) else { throw RecorderError.format }
        lock.withLock { samples = [] }
        startedAt = Date()
        lastSpeechAt = nil
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and hands the recording to `onFinish`.
    func finish() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        let recorded = lock.withLock { samples }
        onFinish?(lastSpeechAt == nil ? nil : Self.wav(samples: recorded, sampleRate: Int(Self.sampleRate)))
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.withLock { samples += chunk }
        onPCM?(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
        let rms = Self.rms(chunk)
        DispatchQueue.main.async { self.update(rms: rms) }
    }

    private func update(rms: Float) {
        guard isRecording else { return }
        level = min(rms * 8, 1)
        let now = Date()
        if rms >= Self.speechLevel { lastSpeechAt = now }
        let elapsed = now.timeIntervalSince(startedAt)
        if let lastSpeechAt, now.timeIntervalSince(lastSpeechAt) > silenceSeconds {
            finish()
        } else if lastSpeechAt == nil && elapsed > Self.noSpeechSeconds {
            finish()
        } else if elapsed > Self.maxSeconds {
            finish()
        }
    }

    static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { total, sample in
            let value = Float(sample) / Float(Int16.max)
            return total + value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// A 16-bit mono PCM WAV file.
    static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))  // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))  // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload))
        for sample in samples { append(sample) }
        return data
    }

    enum RecorderError: Error {
        case format
    }
}
