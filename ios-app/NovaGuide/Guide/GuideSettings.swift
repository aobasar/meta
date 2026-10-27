import Foundation

/// A language the user speaks: the name the Nova server expects, and the voice that reads the steps.
struct UserLanguage: Identifiable, Hashable {
    var id: String { serverName }
    var serverName: String
    var voice: String
    var title: String

    static let all = [
        UserLanguage(serverName: "Turkish", voice: "tr-TR", title: "Türkçe"),
        UserLanguage(serverName: "English", voice: "en-US", title: "English"),
    ]

    static func named(_ name: String) -> UserLanguage { all.first { $0.serverName == name } ?? all[0] }
}

/// User settings, kept in UserDefaults on the phone.
final class GuideSettings: ObservableObject {
    private let defaults: UserDefaults

    /// The Mac over Tailscale; defaults to NOVA_SERVER_URL from the build (ios-app/Config/Local.xcconfig).
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    /// The guide server over the internet (a tunnel to the Mac); defaults to NOVA_PUBLIC_URL from the build.
    @Published var publicURL: String { didSet { defaults.set(publicURL, forKey: "publicURL") } }
    /// The tester's invite code for the internet route, kept in the Keychain.
    @Published var inviteCode: String { didSet { Keychain.write(inviteCode, for: "invite") } }
    @Published var languageName: String { didSet { defaults.set(languageName, forKey: "language") } }
    /// Recording mode: the Mac saves each frame, the camera details and the answer (git-ignored, on the Mac only).
    @Published var record: Bool { didSet { defaults.set(record, forKey: "record") } }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let built = (bundle.object(forInfoDictionaryKey: "NovaServerURL") as? String) ?? ""
        serverURL = defaults.string(forKey: "serverURL") ?? built
        let builtPublic = (bundle.object(forInfoDictionaryKey: "NovaPublicURL") as? String) ?? ""
        publicURL = defaults.string(forKey: "publicURL") ?? builtPublic
        inviteCode = Keychain.read("invite")
        languageName = defaults.string(forKey: "language") ?? UserLanguage.all[0].serverName
        record = defaults.bool(forKey: "record")
    }

    var language: UserLanguage { UserLanguage.named(languageName) }

    /// Internet first, then Tailscale.
    var routes: [Route] { Route.candidates(publicURL: publicURL, inviteCode: inviteCode, tailscaleURL: serverURL) }
}
