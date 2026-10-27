import Foundation

/// Talks to the Nova server on the user's Mac. The phone never holds an API key (HACKATHON.md, design rule 2).
struct GuideClient {
    enum Failure: LocalizedError {
        case noServer
        case server(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noServer: String(localized: "Set the Mac's address in Settings.")
            case .server(let message): message
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
    var session: URLSession = .shared

    func status() async throws -> Bool {
        let (data, _) = try await send(path: "api/guide/status", body: nil, timeout: 8)
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

    private func send(path: String, body: Data?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let baseURL else { throw Failure.noServer }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.setValue("guide-ios", forHTTPHeaderField: "X-Nova-Client")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.message
            throw Failure.server(message ?? String(localized: "The Mac answered with HTTP \(http.statusCode)."))
        }
        return (data, http)
    }
}
