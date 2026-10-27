import Foundation

/// Talks to the Nova server on the user's Mac. The phone never holds an API key (HACKATHON.md, design rule 2).
struct GuideClient {
    enum Failure: LocalizedError {
        case noServer
        case server(status: Int, message: String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noServer: String(localized: "Set the Mac's address in Settings.")
            case .server(_, let message): message
            case .unreadable: String(localized: "The Mac sent an answer the app couldn't read.")
            }
        }
    }

    /// Camera details saved with a recording, so a session can be replayed on the Mac.
    struct CameraInfo: Encodable {
        var imageWidth: Int
        var imageHeight: Int
        var intrinsics: [Float]  // 3x3, column-major
        var transform: [Float]  // 4x4 camera-to-world, column-major
    }

    private struct PlanRequest: Encodable {
        var frame: String
        var question: String
        var language: String
        var record: Bool
        var camera: CameraInfo?
    }

    var baseURL: URL?
    /// Sent on the internet route only; the Tailscale route needs none.
    var inviteCode: String? = nil
    var session: URLSession = .shared

    /// True for failures where the server never answered, so another route may work.
    static func isConnectionFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .networkConnectionLost,
                .notConnectedToInternet, .secureConnectionFailed, .badServerResponse].contains(error.code)
    }

    func status() async throws -> Bool {
        let (data, _) = try await send(path: "api/guide/status", body: nil, timeout: 3)
        struct Status: Decodable { var keyLoaded: Bool }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { throw Failure.unreadable }
        return status.keyLoaded
    }

    func plan(jpeg: Data, question: String, language: String, record: Bool, camera: CameraInfo?) async throws -> GuidePlan {
        let request = PlanRequest(frame: jpeg.base64EncodedString(), question: question, language: language,
                                  record: record, camera: record ? camera : nil)
        let (data, _) = try await send(path: "api/guide/plan", body: try JSONEncoder().encode(request), timeout: 90)
        do {
            return try JSONDecoder().decode(GuidePlan.self, from: data)
        } catch {
            throw Failure.unreadable
        }
    }

    private struct VerifyRequest: Encodable {
        var frame: String
        var instruction: String
        var success: String
        var language: String
        var record: Bool
    }

    func verify(jpeg: Data, step: GuideStep, language: String, record: Bool) async throws -> StepCheck {
        let request = VerifyRequest(frame: jpeg.base64EncodedString(), instruction: step.instruction,
                                    success: step.success, language: language, record: record)
        let (data, _) = try await send(path: "api/guide/verify", body: try JSONEncoder().encode(request), timeout: 30)
        do {
            return try JSONDecoder().decode(StepCheck.self, from: data)
        } catch {
            throw Failure.unreadable
        }
    }

    /// The user's words from a WAV recording; empty when Meta heard no speech. The audio is not stored on the Mac.
    func transcribe(wav: Data, language: String) async throws -> String {
        struct Transcript: Decodable { var transcript: String }
        let path = "api/guide/transcribe?language=" + (language.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let (data, _) = try await send(path: path, body: wav, contentType: "audio/wav", timeout: 30)
        guard let result = try? JSONDecoder().decode(Transcript.self, from: data) else { throw Failure.unreadable }
        return result.transcript
    }

    /// Where the user is in the task, sent with a question asked during it.
    struct TaskContext: Encodable {
        struct Step: Encodable {
            var instruction: String
            var success: String
            var result: String
        }

        var device: String
        var current: Int  // 1-based
        var steps: [Step]
    }

    struct Reply: Decodable, Equatable {
        enum Kind: String, Decodable {
            case answer
            case newTask = "new_task"
        }

        var kind: Kind
        var answer: String
    }

    private struct AskRequest: Encodable {
        var frame: String
        var question: String
        var language: String
        var context: TaskContext
        var record: Bool
    }

    func ask(jpeg: Data, question: String, language: String, context: TaskContext, record: Bool) async throws -> Reply {
        let request = AskRequest(frame: jpeg.base64EncodedString(), question: question, language: language,
                                 context: context, record: record)
        let (data, _) = try await send(path: "api/guide/ask", body: try JSONEncoder().encode(request), timeout: 30)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.unreadable }
        return reply
    }

    private func send(path: String, body: Data?, contentType: String = "application/json",
                      timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let baseURL else { throw Failure.noServer }
        guard let url = URL(string: path, relativeTo: baseURL.hasDirectoryPath ? baseURL : baseURL.appendingPathComponent("")) else {
            throw Failure.noServer
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("guide-ios", forHTTPHeaderField: "X-Nova-Client")
        if let inviteCode, !inviteCode.isEmpty {
            request.setValue("Bearer \(inviteCode)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.message
            throw Failure.server(status: http.statusCode,
                                 message: message ?? String(localized: "The Mac answered with HTTP \(http.statusCode)."))
        }
        return (data, http)
    }
}
