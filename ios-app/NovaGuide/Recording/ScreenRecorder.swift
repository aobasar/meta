import AVFoundation
import ReplayKit

/// A finished screen recording, waiting for the user's Save / Share / Delete.
struct RecordedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

/// Records Nova's own screen (camera view, markers, cards) with ReplayKit, video only: no microphone, no app audio,
/// so no one else's voice is ever captured (HACKATHON.md, design rule 6). It pauses while Nova waits for a model, so
/// the video holds only the action. The file stays in the app's temporary folder until the user saves, shares or
/// deletes it; it never goes to the server.
@MainActor
final class ScreenRecorder: ObservableObject {
    enum State: Equatable {
        case off, starting, recording, paused, finishing
    }

    @Published private(set) var state: State = .off
    @Published var finished: RecordedVideo?
    @Published var failure: String?
    private var writer: VideoWriter?

    var isActive: Bool { state == .starting || state == .recording || state == .paused }

    /// The top bar's button. `waiting`: Nova is thinking right now, so the recording starts paused.
    func toggle(waiting: Bool) {
        isActive ? stop() : start(paused: waiting)
    }

    func start(paused: Bool) {
        guard state == .off else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            failure = String(localized: "Screen recording isn't available on this iPhone right now.")
            return
        }
        recorder.isMicrophoneEnabled = false
        let name = "Nova-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".mp4"
        let writer = VideoWriter(url: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        writer.setPaused(paused)
        self.writer = writer
        state = .starting
        recorder.startCapture(handler: { buffer, type, error in
            guard error == nil, type == .video else { return }  // video only
            writer.append(buffer)
        }, completionHandler: { error in
            Task { @MainActor in
                guard self.writer === writer else { return }
                if let error {
                    self.writer = nil
                    self.state = .off
                    // The user tapped "Don't Allow" on iOS's prompt, or recording failed to start.
                    self.failure = error.localizedDescription
                } else if self.state == .starting {
                    self.state = paused ? .paused : .recording
                }
            }
        })
    }

    func setPaused(_ paused: Bool) {
        guard state == .recording || state == .paused, let writer else { return }
        writer.setPaused(paused)
        state = paused ? .paused : .recording
    }

    /// Stops and offers the video (task finished, Home, or the button).
    func stop() {
        end { url in
            if let url { self.finished = RecordedVideo(url: url) }
        }
    }

    /// Stops and deletes the video (the app went to the background).
    func discard() {
        end { url in
            if let url { try? FileManager.default.removeItem(at: url) }
        }
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
    private var paused = false
    private var resumed = false
    private var offset = CMTime.zero
    private var lastSourceTime: CMTime?

    init(url: URL) { self.url = url }

    func setPaused(_ paused: Bool) {
        queue.async {
            if self.paused && !paused { self.resumed = true }
            self.paused = paused
        }
    }

    func append(_ buffer: CMSampleBuffer) {
        queue.async { self.write(buffer) }
    }

    func finish(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let writer = self.writer, writer.status == .writing else {
                completion(nil)
                return
            }
            self.input?.markAsFinished()
            let url = self.url
            writer.finishWriting { completion(writer.status == .completed ? url : nil) }
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
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time - offset, decodeTimeStamp: .invalid)
        var shifted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &shifted)
        if let shifted, input.append(shifted) { lastSourceTime = time }
    }

    private func begin(with buffer: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        input.expectsMediaDataInRealTime = true
        input.transform = Self.transform(for: buffer)
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.input = input
        return true
    }

    /// ReplayKit sends frames in the device's native portrait orientation and says how to turn them; the video keeps
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
