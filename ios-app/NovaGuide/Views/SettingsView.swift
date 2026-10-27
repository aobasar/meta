import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showHow = false

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") + " Beta"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Language & voice")) {
                    Picker(String(localized: "I speak"), selection: $settings.languageName) {
                        ForEach(UserLanguage.all) { language in
                            Text(language.title).tag(language.serverName)
                        }
                    }
                    // The screen follows the iPhone's language; iOS keeps a per-app choice in the Settings app.
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        LabeledContent(String(localized: "Interface language"), value: String(localized: "iPhone language"))
                    }
                    .foregroundStyle(.primary)
                    Toggle(String(localized: "Speak instructions aloud"), isOn: $settings.speakAloud)
                }
                Section(String(localized: "Screen")) {
                    Picker(String(localized: "Screen orientation"), selection: $settings.orientation) {
                        ForEach(OrientationChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                }
                Section(String(localized: "Task guidance")) {
                    Toggle(String(localized: "Verify each step"), isOn: $settings.verifyEach)
                    Toggle(String(localized: "Continue 5 s after a check"), isOn: $settings.autoContinue)
                        .disabled(!settings.verifyEach)
                    Toggle(String(localized: "Haptics"), isOn: $settings.haptics)
                }
                Section {
                    TextField(String(localized: "Internet address"), text: $settings.publicURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(String(localized: "Invite code"), text: $settings.inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField(String(localized: "Mac over Tailscale"), text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent(String(localized: "Status"), value: connectionText)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The internet address is tried first and needs your invite code, kept in this iPhone's Keychain. The Mac over Tailscale is the fallback. The phone never holds the API key.")
                }
                Section {
                    Toggle(String(localized: "Recording mode (for testing)"), isOn: $settings.record)
                } footer: {
                    Text("When on, each frame and answer is saved on the Mac for testing; nothing is kept on the phone. Audio is never saved. Only invite codes allowed to record can use it.")
                }
                Section {
                    Button(String(localized: "How Nova works")) { showHow = true }
                    Link(String(localized: "Privacy and terms"), destination: ConsentView.legalURL)
                    LabeledContent(String(localized: "Version"), value: version)
                    LabeledContent(String(localized: "Depth sensor"), value: ar.hasLiDAR ? String(localized: "LiDAR") : String(localized: "None (less precise)"))
                } header: {
                    Text("About")
                } footer: {
                    Text("Independent experimental prototype. Guidance is AI-generated and can be wrong.")
                }
            }
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showHow) {
                HowView(buttonTitle: String(localized: "Close")) { showHow = false }
            }
        }
    }

    private var connectionText: String {
        switch model.connection {
        case .connected(.internet): String(localized: "Connected over the internet")
        case .connected(.tailscale): String(localized: "Connected to the Mac (Tailscale)")
        case .rejected: String(localized: "Invite code not accepted")
        case .noKey: String(localized: "The Mac has no API key")
        case .unreachable: String(localized: "Mac not reachable")
        case .unknown: String(localized: "Checking…")
        }
    }
}
