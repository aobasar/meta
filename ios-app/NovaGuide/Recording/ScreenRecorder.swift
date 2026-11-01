import AVFoundation
import CoreImage
import ReplayKit

/// The last screen recording, kept until the next one replaces it or the user deletes it.
struct RecordedVideo: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var seconds: Double?
}

/// Records Nova's own screen (camera view, markers, cards) with ReplayKit while a task runs, when Settings › Screen
/// recording is on. Video only. It pauses while Nova waits for a model, so the video holds only the action. Only the
/// last recording is kept, on the phone; it never goes to the server. Settings shares, saves or deletes it.
/// The demo video (Settings › Demo video) runs from launch to Home with the app's audio and the microphone, so both
/// Kokobubu and the maintainer are heard. It is only ever on by their choice, and it stays on the phone. A task's video
/// never has sound: no one else's voice is captured by it (project rules, design rule 6).
@MainActor
final class ScreenRecorder: ObservableObject {
    enum State: Equatable {
        case off, starting, recording, paused, finishing
    }

    static let lastURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kokobubu last recording.mp4")

    @Published private(set) var state: State = .off
    @Published private(set) var last: RecordedVideo?
    @Published var failure: String?
    /// A demo video is being recorded.
    @Published private(set) var isDemo = false
    /// It has ended: the preview offers to save it.
    @Published var demoFinished = false
    @Published var demoFailed = false
    private var writer: VideoWriter?
    /// Nova's waiting state, which can change while ReplayKit is still starting.
    private var wantPaused = false

    var isActive: Bool { state == .starting || state == .recording || state == .paused }

    init() {
        if FileManager.default.fileExists(atPath: Self.lastURL.path) {
            last = RecordedVideo(url: Self.lastURL)
            Task { await loadDuration() }
        }
    }

    /// A task started. `paused`: Nova is thinking right now, so nothing is written until the first step shows.
    func beginTask(paused: Bool) {
        begin(paused: paused, audio: false)
    }

    /// From launch: the whole demo, with the app's audio.
    func beginDemo() {
        guard state == .off else { return }
        isDemo = true
        begin(paused: false, audio: true)
    }

    private func begin(paused: Bool, audio: Bool) {
        guard state == .off else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            isDemo = false
            failure = String(localized: "Screen recording isn't available on this iPhone right now.", bundle: .ui)
            return
        }
        recorder.isMicrophoneEnabled = audio
        if audio {
            // Playback alone leaves the room's sound out until the first tap on the microphone, so a demo records from the start.
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let writer = VideoWriter(url: FileManager.default.temporaryDirectory.appendingPathComponent("Nova-\(UUID().uuidString).mp4"), audio: audio)
        writer.setPaused(paused)
        wantPaused = paused
        self.writer = writer
        state = .starting
        recorder.startCapture(handler: { buffer, type, error in
            guard error == nil else { return }
            switch type {
            case .video: writer.append(buffer)
            case .audioApp: if audio { writer.appendAudio(buffer) }
            case .audioMic: if audio { writer.appendMic(buffer) }
            @unknown default: break
            }
        }, completionHandler: { error in
            Task { @MainActor in
                guard self.writer === writer else { return }
                if let error {
                    self.writer = nil
                    self.state = .off
                    self.isDemo = false
                    // The user tapped "Don't Allow" on iOS's prompt, or recording failed to start.
                    self.failure = error.localizedDescription
                } else if self.state == .starting {
                    self.state = self.wantPaused ? .paused : .recording
                }
            }
        })
    }

    func setPaused(_ paused: Bool) {
        guard isActive, let writer, wantPaused != paused else { return }
        wantPaused = paused
        writer.setPaused(paused)
        if state != .starting { state = paused ? .paused : .recording }
    }

    /// The task ended (completed, Home, or a new task): the video becomes the last recording.
    func finishTask() {
        end { url in _ = self.keep(url) }
    }

    /// The demo ended (Home, or stopped from the menu, or the app left the screen): what was filmed is kept and offered.
    func finishDemo() {
        guard isDemo else { return }
        end { url in
            self.isDemo = false
            if self.keep(url) {
                self.demoFinished = true
            } else {
                self.demoFailed = true
            }
        }
    }

    private func keep(_ url: URL?) -> Bool {
        guard let url else { return false }
        try? FileManager.default.removeItem(at: Self.lastURL)
        guard (try? FileManager.default.moveItem(at: url, to: Self.lastURL)) != nil else { return false }
        last = RecordedVideo(url: Self.lastURL)
        Task { await loadDuration() }
        return true
    }

    /// The app went to the background mid-task: the partial video is dropped.
    func discard() {
        end { url in
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    func deleteLast() {
        try? FileManager.default.removeItem(at: Self.lastURL)
        last = nil
    }

    private func loadDuration() async {
        guard let duration = try? await AVURLAsset(url: Self.lastURL).load(.duration) else { return }
        last?.seconds = duration.seconds
    }

    private func end(_ completion: @escaping @MainActor (URL?) -> Void) {
        guard isActive, let writer else { return }
        state = .finishing
        RPScreenRecorder.shared().stopCapture { _ in
            writer.finish { url in
                Task { @MainActor in
                    self.writer = nil
                    self.state = .off
                    completion(url)
                }
            }
        }
    }
}

/// Writes ReplayKit's video frames to an MP4 on its own queue. While paused it drops frames, and on resume it shifts
/// the timestamps so the video continues from the last frame without a frozen gap.
final class VideoWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aobasar.nova.screen-recording")
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private let withAudio: Bool
    /// The demo: one wide picture whichever way the phone is held, so the video follows every turn.
    private let fitsCanvas: Bool
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var canvas = CGSize.zero
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var paused = false
    private var resumed = false
    private var offset = CMTime.zero
    private var lastSourceTime: CMTime?

    init(url: URL, audio: Bool = false) {
        self.url = url
        withAudio = audio
        fitsCanvas = audio
    }

    /// The wide picture for a screen of this size, either way up. Video sizes must be even.
    static func canvas(for size: CGSize) -> CGSize {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        return CGSize(width: floor(long / 2) * 2, height: floor(short / 2) * 2)
    }

    /// Where a frame goes on the canvas: whole, centered, with black beside it when it is the other way up.
    static func fit(_ frame: CGSize, in canvas: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let scale = min(canvas.width / frame.width, canvas.height / frame.height)
        let width = frame.width * scale, height = frame.height * scale
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            if self.paused && !paused { self.resumed = true }
            self.paused = paused
        }
    }

    func append(_ buffer: CMSampleBuffer) {
        queue.async { self.write(buffer) }
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        queue.async { self.writeSound(buffer, to: self.audioInput) }
    }

    func appendMic(_ buffer: CMSampleBuffer) {
        queue.async { self.writeSound(buffer, to: self.micInput) }
    }

    func finish(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let writer = self.writer, writer.status == .writing else {
                completion(nil)
                return
            }
            self.input?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            let url = self.url, hasMic = self.micInput != nil
            writer.finishWriting {
                guard writer.status == .completed else { return completion(nil) }
                guard hasMic else { return completion(url) }
                Task { completion(await Self.mixSound(in: url)) }
            }
        }
    }

    private func write(_ buffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(buffer), !paused else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if writer == nil, !begin(with: buffer, at: time) { return }
        if resumed, let last = lastSourceTime {
            // The first frame after a pause lands one frame (1/30 s) after the last frame before it.
            offset = offset + (time - last) - CMTime(value: 1, timescale: 30)
            resumed = false
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        if fitsCanvas {
            // 30 frames a second is enough for a demo, and it keeps the drawing light.
            if let last = lastSourceTime, (time - last).seconds < 1.0 / 31 { return }
            if drawOnCanvas(buffer, at: time - offset) { lastSourceTime = time }
            return
        }
        if let shifted = shifted(buffer), input.append(shifted) { lastSourceTime = time }
    }

    private func drawOnCanvas(_ buffer: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let adaptor, let pool = adaptor.pixelBufferPool, let source = CMSampleBufferGetImageBuffer(buffer) else { return false }
        var image = CIImage(cvPixelBuffer: source).oriented(Self.orientation(of: buffer))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let place = Self.fit(image.extent.size, in: canvas)
        let scale = place.width / max(image.extent.width, 1)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: place.minX, y: place.minY))
        let picture = image.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas)))
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else { return false }
        context.render(picture, to: target)
        return adaptor.append(target, withPresentationTime: time)
    }

    /// Sound follows the picture: it waits for the first frame, stops with the pause and takes the same time shift.
    private func writeSound(_ buffer: CMSampleBuffer, to sound: AVAssetWriterInput?) {
        guard CMSampleBufferDataIsReady(buffer), !paused, !resumed, writer != nil,
              let sound, sound.isReadyForMoreMediaData, let shifted = shifted(buffer) else { return }
        sound.append(shifted)
    }

    /// Players often play only a file's first sound track, so the app's sound and the voice become one. If that fails the
    /// video with its two tracks is still kept.
    private static func mixSound(in url: URL) async -> URL {
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let sounds = try? await asset.loadTracks(withMediaType: .audio), sounds.count > 1,
              let duration = try? await asset.load(.duration) else { return url }
        let mix = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        for track in [video] + sounds {
            let copy = mix.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? copy?.insertTimeRange(range, of: track, at: .zero)
        }
        let output = url.deletingPathExtension().appendingPathExtension("mixed.mp4")
        guard let export = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else { return url }
        export.outputURL = output
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else { return url }
        try? FileManager.default.removeItem(at: url)
        return output
    }

    /// The buffer with the pauses taken out of its times.
    private func shifted(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
            timing[index].decodeTimeStamp = .invalid
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    private func begin(with buffer: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        if fitsCanvas { canvas = Self.canvas(for: CGSize(width: Int(size.width), height: Int(size.height))) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: fitsCanvas ? Int32(canvas.width) : size.width,
            AVVideoHeightKey: fitsCanvas ? Int32(canvas.height) : size.height,
        ])
        input.expectsMediaDataInRealTime = true
        if fitsCanvas {
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height),
            ])
        } else {
            input.transform = Self.transform(for: buffer)
        }
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        if withAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            mic.expectsMediaDataInRealTime = true
            if writer.canAdd(mic) {
                writer.add(mic)
                micInput = mic
            }
        }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.input = input
        return true
    }

    private static func orientation(of buffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber
        else { return .up }
        return CGImagePropertyOrientation(rawValue: value.uint32Value) ?? .up
    }

    /// ReplayKit sends frames in the device's native portrait orientation and says how to turn them; a task's video keeps
    /// the orientation it started in.
    private static func transform(for buffer: CMSampleBuffer) -> CGAffineTransform {
        guard let value = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return .identity }
        switch orientation {
        case .right: return CGAffineTransform(rotationAngle: .pi / 2)
        case .left: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }
}
