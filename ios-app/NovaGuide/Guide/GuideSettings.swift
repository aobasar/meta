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

    /// The voice for a language Spark names (the language printed on a device); English when the iPhone has none.
    static func voice(forLanguageNamed name: String?) -> String {
        let voices = ["English": "en-US", "Turkish": "tr-TR", "German": "de-DE", "French": "fr-FR", "Spanish": "es-ES",
                      "Italian": "it-IT", "Portuguese": "pt-PT", "Dutch": "nl-NL", "Polish": "pl-PL", "Swedish": "sv-SE",
                      "Greek": "el-GR", "Russian": "ru-RU", "Arabic": "ar-SA", "Japanese": "ja-JP", "Korean": "ko-KR",
                      "Chinese": "zh-CN"]
        return name.flatMap { voices[$0] } ?? "en-US"
    }

    /// A quick guess from the letters and a few common words, only for the instant "Let me look…"; the plan then
    /// names the language for real. Nil when the words give no hint.
    static func guess(_ text: String) -> UserLanguage? {
        let lower = text.lowercased()
        if lower.rangeOfCharacter(from: CharacterSet(charactersIn: "çğıöşü")) != nil { return all[0] }
        let words = Set(lower.components(separatedBy: CharacterSet.letters.inverted))
        let turkish: Set = ["bu", "ne", "nasil", "mi", "ve", "bir", "icin", "istiyorum", "yap", "ac", "kapat", "nerede"]
        let english: Set = ["the", "how", "what", "i", "to", "do", "this", "is", "want", "turn", "set", "my", "where"]
        if !words.isDisjoint(with: turkish) { return all[0] }
        if !words.isDisjoint(with: english) { return all[1] }
        return nil
    }

    /// A fixed phrase from the string catalog in this language, whatever the iPhone's language: the screen follows
    /// the iPhone, the voice follows the user.
    func phrase(_ key: String) -> String {
        let code = String(voice.prefix(2))
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The spoken language that matches the iPhone's language, so the voice and the screen agree by default.
    static func matching(preferred languages: [String]) -> UserLanguage {
        languages.first?.hasPrefix("tr") == true ? all[0] : all[1]
    }
}

/// Settings › Interface language: the iPhone's language, or one chosen for this app. iOS reads the choice at launch.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case iPhone, turkish, english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iPhone: String(localized: "iPhone language")
        case .turkish: "Türkçe"
        case .english: "English"
        }
    }

    /// The value for iOS's per-app language key; nil follows the iPhone.
    var appleLanguages: [String]? {
        switch self {
        case .iPhone: nil
        case .turkish: ["tr"]
        case .english: ["en"]
        }
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

/// Settings › Camera › Field of view. ARKit tracks with one back camera at a time; the markers stay on the controls
/// only on a camera ARKit itself runs, so there is no digital zoom.
enum LensChoice: String, CaseIterable, Identifiable {
    case widest, normal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .widest: String(localized: "Widest")
        case .normal: String(localized: "Normal (1x)")
        }
    }
}

/// Settings › Camera › Torch.
enum TorchChoice: String, CaseIterable, Identifiable {
    case automatic, on, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        }
    }
}

/// Settings › Speed test (the maintainer's builds): where Spark runs. SAM and transcription always stay on Meta.
enum SparkProvider: String, CaseIterable, Identifiable {
    case meta, baseten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meta: "Meta · Muse Spark 1.3"
        case .baseten: "Baseten · Muse Spark Open"
        }
    }

    var shortTitle: String {
        switch self {
        case .meta: "Meta"
        case .baseten: "Baseten"
        }
    }
}

/// Settings › Speed test: how long Spark reasons before it answers.
enum SparkEffort: String, CaseIterable, Identifiable {
    case low, minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .minimal: String(localized: "Minimal")
        }
    }
}

/// User settings, kept in UserDefaults on the phone.
final class GuideSettings: ObservableObject {
    /// The version of the terms the consent screen shows; a new version asks again.
    static let termsVersion = "2026-10-27"
    /// Settings › I speak › Automatic: Nova answers in the language the user just spoke (the default).
    static let automaticLanguage = "Automatic"

    private let defaults: UserDefaults
    private let preferredLanguages: [String]

    /// The Mac over Tailscale; defaults to NOVA_SERVER_URL from the build (ios-app/Config/Local.xcconfig).
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    /// The guide server over the internet (a tunnel to the Mac); defaults to NOVA_PUBLIC_URL from the build.
    @Published var publicURL: String { didSet { defaults.set(publicURL, forKey: "publicURL") } }
    /// The tester's invite code for the internet route, kept in the Keychain.
    @Published var inviteCode: String { didSet { Keychain.write(inviteCode, for: "invite") } }
    @Published var languageName: String { didSet { defaults.set(languageName, forKey: "language") } }
    /// Recording mode: the Mac saves each frame, the camera details and the answer (git-ignored, on the Mac only).
    @Published var record: Bool { didSet { defaults.set(record, forKey: "record") } }
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage")
            if let languages = interfaceLanguage.appleLanguages {
                defaults.set(languages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    /// Words appear while the user speaks, and Meta finds the end of the sentence.
    @Published var liveTranscription: Bool { didSet { defaults.set(liveTranscription, forKey: "liveTranscription") } }
    @Published var speakAloud: Bool { didSet { defaults.set(speakAloud, forKey: "speakAloud") } }
    /// Check each step on a close-up; when off, "I've done it" moves on and counts as the user's own confirmation.
    @Published var verifyEach: Bool { didSet { defaults.set(verifyEach, forKey: "verifyEach") } }
    /// Move on by itself 5 s after a step is verified.
    @Published var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: "autoContinue") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var orientation: OrientationChoice { didSet { defaults.set(orientation.rawValue, forKey: "orientation") } }
    /// The widest camera ARKit can track with is the default: more of a wide panel fits in one frame.
    @Published var lens: LensChoice { didSet { defaults.set(lens.rawValue, forKey: "lens") } }
    /// The camera's highest-resolution format, for small labels (close-ups are cut from the full frame).
    @Published var highDetail: Bool { didSet { defaults.set(highDetail, forKey: "highDetail") } }
    /// Automatic by default: on in the dark, off when the task ends.
    @Published var torch: TorchChoice { didSet { defaults.set(torch.rawValue, forKey: "torchMode") } }
    /// Record every task on screen (video only); the last recording is shared from Settings.
    @Published var screenRecording: Bool { didSet { defaults.set(screenRecording, forKey: "screenRecording") } }
    @Published var sparkProvider: SparkProvider { didSet { defaults.set(sparkProvider.rawValue, forKey: "sparkProvider") } }
    @Published var sparkEffort: SparkEffort { didSet { defaults.set(sparkEffort.rawValue, forKey: "sparkEffort") } }
    /// A line on the camera screen with the current task's timings.
    @Published var showTimings: Bool { didSet { defaults.set(showTimings, forKey: "showTimings") } }
    /// The terms version the user accepted, with the date; empty until the consent screen is accepted.
    @Published private(set) var acceptedTerms: String { didSet { defaults.set(acceptedTerms, forKey: "acceptedTerms") } }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let built = (bundle.object(forInfoDictionaryKey: "NovaServerURL") as? String) ?? ""
        serverURL = defaults.string(forKey: "serverURL") ?? built
        let builtPublic = (bundle.object(forInfoDictionaryKey: "NovaPublicURL") as? String) ?? ""
        publicURL = defaults.string(forKey: "publicURL") ?? builtPublic
        inviteCode = Keychain.read("invite")
        languageName = defaults.string(forKey: "language") ?? Self.automaticLanguage
        record = defaults.bool(forKey: "record")
        interfaceLanguage = InterfaceLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .iPhone
        liveTranscription = defaults.object(forKey: "liveTranscription") as? Bool ?? true
        speakAloud = defaults.object(forKey: "speakAloud") as? Bool ?? true
        verifyEach = defaults.object(forKey: "verifyEach") as? Bool ?? true
        autoContinue = defaults.object(forKey: "autoContinue") as? Bool ?? true
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        orientation = OrientationChoice(rawValue: defaults.string(forKey: "orientation") ?? "") ?? .automatic
        lens = LensChoice(rawValue: defaults.string(forKey: "lens") ?? "") ?? .widest
        highDetail = defaults.bool(forKey: "highDetail")
        torch = TorchChoice(rawValue: defaults.string(forKey: "torchMode") ?? "") ?? .automatic
        screenRecording = defaults.bool(forKey: "screenRecording")
        sparkProvider = SparkProvider(rawValue: defaults.string(forKey: "sparkProvider") ?? "") ?? .meta
        sparkEffort = SparkEffort(rawValue: defaults.string(forKey: "sparkEffort") ?? "") ?? .minimal
        showTimings = defaults.bool(forKey: "showTimings")
        acceptedTerms = defaults.string(forKey: "acceptedTerms") ?? ""
    }

    var isAutomaticLanguage: Bool { languageName == Self.automaticLanguage }

    /// The chosen language; with Automatic, the iPhone's language until the user speaks.
    var language: UserLanguage {
        isAutomaticLanguage ? UserLanguage.matching(preferred: preferredLanguages) : UserLanguage.named(languageName)
    }

    /// The speed test setting to send; nil for the default (Meta, minimal), and always nil outside the maintainer's builds.
    var sparkChoice: GuideClient.SparkChoice? {
        #if DEBUG
        sparkProvider == .meta && sparkEffort == .minimal
            ? nil : GuideClient.SparkChoice(provider: sparkProvider.rawValue, effort: sparkEffort.rawValue)
        #else
        nil
        #endif
    }

    /// "Meta Minimal", for the timings line.
    var sparkLabel: String {
        #if DEBUG
        "\(sparkProvider.shortTitle) \(sparkEffort.title)"
        #else
        ""
        #endif
    }

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
