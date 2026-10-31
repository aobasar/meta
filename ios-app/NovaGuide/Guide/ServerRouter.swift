import Foundation

/// Where the guide server is reached: over the internet (a tunnel to the Mac, an invite code required) or straight
/// to the Mac over Tailscale. The internet route is tried first; Tailscale is the fallback.
struct Route: Equatable {
    enum Kind: Equatable {
        case internet, tailscale
    }

    var kind: Kind
    var baseURL: URL
    var inviteCode: String?

    var client: GuideClient { GuideClient(baseURL: baseURL, inviteCode: kind == .internet ? inviteCode : nil) }

    /// The routes to try, in order. The internet route needs both its address and an invite code.
    static func candidates(publicURL: String, inviteCode: String, tailscaleURL: String) -> [Route] {
        var routes: [Route] = []
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = parse(publicURL), !code.isEmpty {
            routes.append(Route(kind: .internet, baseURL: url, inviteCode: code))
        }
        if let url = parse(tailscaleURL) {
            routes.append(Route(kind: .tailscale, baseURL: url))
        }
        return routes
    }

    /// The code in a link like kokobubu://invite/ABCD-1234, so a tester only has to tap it.
    static func inviteCode(from link: URL) -> String? {
        guard link.scheme == "kokobubu" || link.scheme == "kokobubu-dev", link.host == "invite" else { return nil }
        let code = link.lastPathComponent
        guard (4...64).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return nil
        }
        return code
    }

    private static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
}

/// Picks the first route that answers and keeps using it. Only a connection failure moves on to the next route;
/// an answer from the server, even an error, never sends the same request twice (no double model calls).
actor ServerRouter {
    enum Probe: Equatable {
        case ok(keyLoaded: Bool)
        case rejected(String)  // the server answered but refused (an invalid invite code)
        case unreachable
    }

    enum State: Equatable {
        case unknown
        case connected(Route.Kind, keyLoaded: Bool)
        case rejected(String)
        case unreachable
    }

    private let probe: (Route) async -> Probe
    private var routes: [Route] = []
    private var active: Route?
    private(set) var state: State = .unknown

    init(probe: @escaping (Route) async -> Probe = ServerRouter.liveProbe) {
        self.probe = probe
    }

    /// The routes from Settings; a change forgets the active route.
    func update(_ routes: [Route]) {
        guard routes != self.routes else { return }
        self.routes = routes
        active = nil
    }

    /// Probes the routes in order, skipping `excluding`, and remembers the first one that answers.
    @discardableResult
    func resolve(excluding: Route? = nil) async -> State {
        active = nil
        var rejected: String?
        for route in routes where route != excluding {
            switch await probe(route) {
            case .ok(let keyLoaded):
                active = route
                state = .connected(route.kind, keyLoaded: keyLoaded)
                return state
            case .rejected(let message):
                rejected = message
            case .unreachable:
                continue
            }
        }
        state = rejected.map(State.rejected) ?? .unreachable
        return state
    }

    /// Runs a request on the active route; after a connection failure, finds another route and tries once more.
    func perform<T>(_ request: (GuideClient) async throws -> T) async throws -> T {
        if active == nil { await resolve() }
        guard let route = active else { throw GuideClient.Failure.noServer }
        do {
            return try await request(route.client)
        } catch let error where GuideClient.isConnectionFailure(error) {
            await resolve(excluding: route)
            guard let next = active else { throw error }
            return try await request(next.client)
        }
    }

    static func liveProbe(_ route: Route) async -> Probe {
        do {
            return .ok(keyLoaded: try await route.client.status())
        } catch GuideClient.Failure.server(let status, let message) where status == 401 {
            return .rejected(message)
        } catch {
            return .unreachable
        }
    }
}
