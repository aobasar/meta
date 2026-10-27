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
                    TextField(String(localized: "Mac address"), text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nova on your Mac")
                } footer: {
                    Text("The phone talks only to your Mac over Tailscale. The Mac holds the API key.")
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
