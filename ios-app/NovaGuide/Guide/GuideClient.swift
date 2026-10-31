import Foundation

/// Talks to the Nova server on the user's Mac. The phone never holds an API key (HACKATHON.md, design rule 2).
struct GuideClient {
    enum Failure: LocalizedError {
        case noServer
        case server(status: Int, message: String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noServer: String(localized: "Set the server's address in Settings.", bundle: .ui)
            case .server(_, let message): message
            case .unreadable: String(localized: "The server sent an answer the app couldn't read.", bundle: .ui)
            }
        }
    }

    /// Camera details saved with a recording, so a session can be replayed on the Mac.
    struct CameraInfo: Encodable {
        var imageWidth: Int
        var imageHeight: Int
        var intrinsics: [Float]  // 3x3, column-major
        var transform: [Float]  // 4x4 camera-to-world, column-major
        /// How the sent frame was turned upright from the sensor image: "landscapeRight", "portrait", "landscapeLeft".
        var orientation: String
    }

    /// The maintainer's speed test setting: where Spark runs and how long it reasons. Nil is the default and is left
    /// out of the request.
    struct SparkChoice: Encodable, Equatable {
        var provider: String
        var effort: String
    }

    private struct PlanRequest: Encodable {
        var frame: String
        var question: String
        var language: String
        /// Answer in the language the question is written in; `language` is the fallback.
        var autoLanguage: Bool
        var record: Bool
        var camera: CameraInfo?
        var spark: SparkChoice?
        /// One JSON line per part: the steps first, then the located plan.
        var stream = true
        /// Nova may answer with a question instead of steps.
        var allowQuestions: Bool
        var answers: [Answer] = []
        var correction: Correction?
        /// What earlier photos of this task showed, and how many times Kokobubu asked to see something.
        var findings: [String] = []
        var shows = 0
    }

    var baseURL: URL?
    /// Sent on the internet route only; the Tailscale route needs none.
    var inviteCode: String? = nil
    /// Usage ids: one per app launch and one per task (plan), so the Mac can total model calls for cost analysis.
    var sessionID: String? = nil
    var taskID: String? = nil
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

    /// The located plan. `onSteps` gets the steps as soon as Spark has written them, a few seconds before the
    /// controls are located, so the first step can be read while the markers are still on their way.
    /// The user's answer to a question Nova asked before planning.
    struct Answer: Encodable, Equatable {
        var question: String
        var answer: String
    }

    /// "This step is wrong" or "Start over": what went wrong, so the next plan doesn't repeat it.
    struct Correction: Encodable, Equatable {
        var kind: String  // "step", "restart", "outcome" (all done, not solved), or "continue" (the next screen)
        var wrongStep: String
        var said: String
        var done: [String]
    }

    func plan(jpeg: Data, question: String, language: String, autoLanguage: Bool = false, record: Bool,
              camera: CameraInfo?, spark: SparkChoice? = nil, answers: [Answer] = [], correction: Correction? = nil,
              allowQuestions: Bool = true, findings: [String] = [], shows: Int = 0, onSteps: @MainActor (GuidePlan) -> Void = { _ in }) async throws -> GuidePlan {
        let request = PlanRequest(frame: jpeg.base64EncodedString(), question: question, language: language,
                                  autoLanguage: autoLanguage, record: record, camera: record ? camera : nil, spark: spark,
                                  allowQuestions: allowQuestions, answers: answers, correction: correction,
                                  findings: findings, shows: shows)
        let bytes = try await open(path: "api/guide/plan", body: try JSONEncoder().encode(request), timeout: 90)
        for try await line in bytes.lines where !line.isEmpty {
            let data = Data(line.utf8)
            if let failure = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw Failure.server(status: 502, message: failure.error.message)
            }
            guard let part = try? JSONDecoder().decode(GuidePlan.self, from: data) else { throw Failure.unreadable }
            if part.isLocated { return part }
            await onSteps(part)
        }
        throw Failure.unreadable
    }

    private struct VerifyRequest: Encodable {
        var frame: String
        var instruction: String
        var success: String
        var language: String
        var record: Bool
        var spark: SparkChoice?
        var view: String?
    }

    func verify(jpeg: Data, step: GuideStep, language: String, record: Bool, spark: SparkChoice? = nil,
                wholeView: Bool = false) async throws -> StepCheck {
        try await check(jpeg: jpeg, instruction: step.instruction, success: step.success, language: language, record: record,
                        spark: spark, view: wholeView ? "whole" : nil)
    }

    /// Is the whole task finished? Asked after the last step, on a photo of the whole device.
    func verifyGoal(jpeg: Data, task: String, goal: String, language: String, record: Bool,
                    spark: SparkChoice? = nil) async throws -> StepCheck {
        try await check(jpeg: jpeg, instruction: String(task.prefix(500)), success: goal, language: language, record: record,
                        spark: spark, view: "goal")
    }

    private func check(jpeg: Data, instruction: String, success: String, language: String, record: Bool,
                       spark: SparkChoice?, view: String?) async throws -> StepCheck {
        let request = VerifyRequest(frame: jpeg.base64EncodedString(), instruction: instruction, success: success,
                                    language: language, record: record, spark: spark, view: view)
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
            case wrong
        }

        var kind: Kind
        var answer: String
        /// The language Spark answered in (an older server sends none).
        var language: String?
    }

    private struct AskRequest: Encodable {
        var frame: String
        var question: String
        var language: String
        var autoLanguage: Bool
        var context: TaskContext
        var record: Bool
        var spark: SparkChoice?
        /// "detail" when this is the "Explain it in more detail" button (counted in the usage log).
        var correction: String?
    }

    /// "Re-evaluate": Nova looks at the current step again, from a new frame.
    struct Review: Decodable, Equatable {
        enum Verdict: String, Decodable {
            case stepOK = "step_ok"
            case wrongStep = "wrong_step"
            case unsure
        }

        var verdict: Verdict
        var explanation: String
        var point: NormalizedPoint?
        var box: NormalizedBox?
        var boxMethod: String
    }

    private struct ReassessRequest: Encodable {
        var frame: String
        var target: String
        var language: String
        var context: TaskContext
        var record: Bool
        var spark: SparkChoice?
    }

    func reassess(jpeg: Data, target: String, language: String, context: TaskContext, record: Bool,
                  spark: SparkChoice? = nil) async throws -> Review {
        let request = ReassessRequest(frame: jpeg.base64EncodedString(), target: target, language: language,
                                      context: context, record: record, spark: spark)
        let (data, _) = try await send(path: "api/guide/reassess", body: try JSONEncoder().encode(request), timeout: 45)
        guard let review = try? JSONDecoder().decode(Review.self, from: data) else { throw Failure.unreadable }
        return review
    }

    /// A WebSocket for one spoken turn (LiveTranscriber), with this route's headers.
    func listenTask() throws -> URLSessionWebSocketTask {
        var request = try request(path: "api/guide/listen", body: nil, contentType: "", timeout: 30)
        guard let url = request.url?.absoluteURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw Failure.noServer
        }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        request.url = parts.url
        return session.webSocketTask(with: request)
    }

    /// Counts a correction that needs no model (the user moved the marker) in the Mac's usage log.
    func noteCorrection(kind: String) async throws {
        struct Note: Encodable { var kind: String }
        _ = try await send(path: "api/guide/correction", body: try JSONEncoder().encode(Note(kind: kind)), timeout: 10)
    }

    func ask(jpeg: Data, question: String, language: String, autoLanguage: Bool = false, context: TaskContext,
             record: Bool, spark: SparkChoice? = nil, correction: String? = nil) async throws -> Reply {
        let request = AskRequest(frame: jpeg.base64EncodedString(), question: question, language: language,
                                 autoLanguage: autoLanguage, context: context, record: record, spark: spark,
                                 correction: correction)
        let (data, _) = try await send(path: "api/guide/ask", body: try JSONEncoder().encode(request), timeout: 30)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.unreadable }
        return reply
    }

    private func send(path: String, body: Data?, contentType: String = "application/json",
                      timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: try request(path: path, body: body, contentType: contentType,
                                                                       timeout: timeout))
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard http.statusCode == 200 else { throw Self.failure(http.statusCode, data) }
        return (data, http)
    }

    /// A response read as it arrives (a streamed plan); errors are read whole, as with `send`.
    private func open(path: String, body: Data, timeout: TimeInterval) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: try request(path: path, body: body,
                                                                         contentType: "application/json", timeout: timeout))
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.failure(http.statusCode, data)
        }
        return bytes
    }

    private static func failure(_ status: Int, _ data: Data) -> Failure {
        let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.message
        return .server(status: status, message: message ?? String(localized: "The server answered with HTTP \(status).", bundle: .ui))
    }

    private func request(path: String, body: Data?, contentType: String, timeout: TimeInterval) throws -> URLRequest {
        guard let baseURL else { throw Failure.noServer }
        guard let url = URL(string: path, relativeTo: baseURL.hasDirectoryPath ? baseURL : baseURL.appendingPathComponent("")) else {
            throw Failure.noServer
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("guide-ios", forHTTPHeaderField: "X-Nova-Client")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "X-Nova-Session") }
        if let taskID { request.setValue(taskID, forHTTPHeaderField: "X-Nova-Task") }
        if let inviteCode, !inviteCode.isEmpty {
            request.setValue("Bearer \(inviteCode)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}
