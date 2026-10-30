import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showHow = false
    @State private var showLastRecording = false

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") + " Beta"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "I speak"), selection: $settings.languageName) {
                        Text("Automatic").tag(GuideSettings.automaticLanguage)
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
                } header: {
                    Text("Language & voice")
                } footer: {
                    Text("Automatic: speak Turkish or English and Nova answers in the same language. Words printed on the device are read in their own language.")
                }
                Section(String(localized: "Screen")) {
                    Picker(String(localized: "Screen orientation"), selection: $settings.orientation) {
                        ForEach(OrientationChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                }
                Section {
                    if ARGuideController.hasUltraWide {
                        Picker(String(localized: "Field of view"), selection: $settings.lens) {
                            ForEach(LensChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                    }
                    Toggle(String(localized: "High detail (small labels)"), isOn: $settings.highDetail)
                    Picker(String(localized: "Torch"), selection: $settings.torch) {
                        ForEach(TorchChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    LabeledContent(String(localized: "In use"), value: ar.activeCamera)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("The default is the widest camera this iPhone can use with the markers: more of the panel is in view, and wide panels fit in one frame. High detail is for small labels. Automatic torch: on in the dark, off when the task ends.")
                }
                Section(String(localized: "Task guidance")) {
                    Toggle(String(localized: "Verify each step"), isOn: $settings.verifyEach)
                    Toggle(String(localized: "Continue 5 s after a check"), isOn: $settings.autoContinue)
                        .disabled(!settings.verifyEach)
                    Toggle(String(localized: "Haptics"), isOn: $settings.haptics)
                }
                Section {
                    Toggle(String(localized: "Record tasks on screen"), isOn: $settings.screenRecording)
                    Button { showLastRecording = true } label: {
                        LabeledContent(String(localized: "Share the last recording"), value: lastRecordingText)
                    }
                    .foregroundStyle(.primary)
                    .disabled(screenRecorder.last == nil)
                } header: {
                    Text("Screen recording")
                } footer: {
                    Text("When on, each task is recorded without sound; recording pauses while Nova thinks. The video stays on the phone; save it to Photos or share it from here.")
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
                #if DEBUG
                Section {
                    Picker(String(localized: "Model"), selection: $settings.sparkProvider) {
                        ForEach(SparkProvider.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(String(localized: "Thinking"), selection: $settings.sparkEffort) {
                        ForEach(SparkEffort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(String(localized: "Show timings on the camera screen"), isOn: $settings.showTimings)
                    LabeledContent(String(localized: "Last task"),
                                   value: model.timings.isEmpty ? String(localized: "none yet") : model.timings.summary)
                } header: {
                    Text("Speed test")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("For the maintainer's tests: the Mac refuses these settings for other invite codes. Only Muse Spark moves; SAM and voice recognition stay on Meta. Timings are measured on the phone, network included.")
                        if settings.sparkProvider == .baseten { Text("Built with Muse Spark Open") }
                    }
                }
                #endif
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
            .sheet(isPresented: $showLastRecording) {
                if let last = screenRecorder.last { RecordingPreview(video: last) }
            }
        }
    }

    private var lastRecordingText: String {
        guard let last = screenRecorder.last else { return String(localized: "none yet") }
        guard let seconds = last.seconds else { return "" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
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
