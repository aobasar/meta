import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var ar: ARGuideController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "I speak"), selection: $settings.languageName) {
                        ForEach(UserLanguage.all) { language in
                            Text(language.title).tag(language.serverName)
                        }
                    }
                }
                Section {
                    TextField(String(localized: "Internet address"), text: $settings.publicURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(String(localized: "Invite code"), text: $settings.inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nova over the internet")
                } footer: {
                    Text("Tried first. Needs the invite code you were given; it is kept in this iPhone's Keychain.")
                }
                Section {
                    TextField(String(localized: "Mac address"), text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Mac over Tailscale")
                } footer: {
                    Text("Used when the internet address doesn't answer. The phone never holds the API key; the Mac does.")
                }
                Section {
                    Toggle(String(localized: "Recording mode"), isOn: $settings.record)
                } footer: {
                    Text("When on, your Mac saves each camera frame and answer for testing. Nothing is saved on the phone.")
                }
                Section {
                    LabeledContent(String(localized: "Depth sensor"), value: ar.hasLiDAR ? String(localized: "LiDAR") : String(localized: "None (less precise)"))
                } footer: {
                    Text("Nova Guide shows where to touch; you do every step yourself. Its guidance is AI-generated and can be wrong.")
                }
            }
            .navigationTitle(Text("Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
        }
    }
}
