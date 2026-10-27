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

    /// The spoken language that matches the iPhone's language, so the voice and the screen agree by default.
    static func matching(preferred languages: [String]) -> UserLanguage {
        languages.first?.hasPrefix("tr") == true ? all[0] : all[1]
    }
}

/// Which way the screen may turn: Settings › Screen orientation.
enum OrientationChoice: String, CaseIterable, Identifiable {
    case automatic, portrait, landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .portrait: String(localized: "Portrait")
        case .landscape: String(localized: "Landscape")
        }
    }
}

/// User settings, kept in UserDefaults on the phone.
final class GuideSettings: ObservableObject {
    /// The version of the terms the consent screen shows; a new version asks again.
    static let termsVersion = "2026-10-27"

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
    @Published var speakAloud: Bool { didSet { defaults.set(speakAloud, forKey: "speakAloud") } }
    /// Check each step on a close-up; when off, "I've done it" moves on and counts as the user's own confirmation.
    @Published var verifyEach: Bool { didSet { defaults.set(verifyEach, forKey: "verifyEach") } }
    /// Move on by itself 5 s after a step is verified.
    @Published var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: "autoContinue") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var orientation: OrientationChoice { didSet { defaults.set(orientation.rawValue, forKey: "orientation") } }
    /// The terms version the user accepted, with the date; empty until the consent screen is accepted.
    @Published private(set) var acceptedTerms: String { didSet { defaults.set(acceptedTerms, forKey: "acceptedTerms") } }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        let built = (bundle.object(forInfoDictionaryKey: "NovaServerURL") as? String) ?? ""
        serverURL = defaults.string(forKey: "serverURL") ?? built
        let builtPublic = (bundle.object(forInfoDictionaryKey: "NovaPublicURL") as? String) ?? ""
        publicURL = defaults.string(forKey: "publicURL") ?? builtPublic
        inviteCode = Keychain.read("invite")
        languageName = defaults.string(forKey: "language") ?? UserLanguage.matching(preferred: preferredLanguages).serverName
        record = defaults.bool(forKey: "record")
        speakAloud = defaults.object(forKey: "speakAloud") as? Bool ?? true
        verifyEach = defaults.object(forKey: "verifyEach") as? Bool ?? true
        autoContinue = defaults.object(forKey: "autoContinue") as? Bool ?? true
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        orientation = OrientationChoice(rawValue: defaults.string(forKey: "orientation") ?? "") ?? .automatic
        acceptedTerms = defaults.string(forKey: "acceptedTerms") ?? ""
    }

    var language: UserLanguage { UserLanguage.named(languageName) }

    /// Internet first, then Tailscale.
    var routes: [Route] { Route.candidates(publicURL: publicURL, inviteCode: inviteCode, tailscaleURL: serverURL) }

    var needsConsent: Bool { !acceptedTerms.hasPrefix(Self.termsVersion + " ") }

    func acceptTerms(on date: Date = Date()) {
        acceptedTerms = Self.termsVersion + " " + ISO8601DateFormatter().string(from: date)
    }

    #if DEBUG
    /// Simulator screenshots of the onboarding screens.
    func forgetTerms() { acceptedTerms = "" }

    /// The maintainer's test builds (2026-10-27): recording mode starts on once, so the Mac keeps every frame and
    /// answer for plan tests; it can be turned off in Settings. Release builds never do this.
    func turnOnRecordingForTesting() {
        guard defaults.object(forKey: "recordOnForTesting") == nil else { return }
        defaults.set(true, forKey: "recordOnForTesting")
        record = true
    }
    #endif
}
