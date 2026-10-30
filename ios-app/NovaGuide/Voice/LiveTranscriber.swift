import Foundation

/// One spoken turn over a WebSocket to the Mac, which relays it to Muse Voice Transcribe: words arrive while the user
/// speaks. The audio is not stored anywhere. If the connection fails, the recording goes through the file route.
final class LiveTranscriber {
    enum Event: Equatable {
        case partial(String)
        case speechEnded
        case final(String)
        case failed
    }

    /// One server message; nil for those the app doesn't use.
    static func event(from text: String) -> Event? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let words = message["transcript"] as? String ?? ""
        switch message["type"] as? String {
        case "transcript": return .partial(words)
        case "speechEnd": return .speechEnded
        case "speechComplete": return .final(words)
        case "error": return .failed
        default: return nil
        }
    }

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var pending = Data()
    private var finished = false

    /// Audio recorded before the connection is ready waits here, so the first words aren't lost.
    func send(pcm: Data) {
        let sendNow: Data? = lock.withLock {
            guard ready else {
                pending.append(pcm)
                return nil
            }
            return pcm
        }
        if let sendNow { task?.send(.data(sendNow)) { _ in } }
    }

    func connect(_ task: URLSessionWebSocketTask, languages: [String]) {
        self.task = task
        task.resume()
        let config = (try? JSONSerialization.data(withJSONObject: ["languages": languages])) ?? Data()
        task.send(.string(String(decoding: config, as: UTF8.self))) { [weak self] error in
            if error != nil { self?.deliver(.failed) }
        }
        receive()
    }

    /// No more audio; Meta sends the final words, then the connection closes.
    func finish() {
        lock.withLock { finished = true }
        task?.send(.string("{\"type\":\"endStream\"}")) { _ in }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func fail() { deliver(.failed) }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if text.contains("\"ready\"") { self.becameReady() }
                if let event = Self.event(from: text) { self.deliver(event) }
                self.receive()
            case .success:
                self.receive()
            case .failure:
                let done = self.lock.withLock { self.finished }
                if !done { self.deliver(.failed) }
            }
        }
    }

    private func becameReady() {
        let waiting: Data = lock.withLock {
            ready = true
            defer { pending = Data() }
            return pending
        }
        if !waiting.isEmpty { task?.send(.data(waiting)) { _ in } }
    }

    private func deliver(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}
