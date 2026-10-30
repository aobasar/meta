import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var showHow = false
    @State private var showLastRecording = false

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") + " Beta"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "I speak", bundle: .ui), selection: $settings.languageName) {
                        Text("Automatic").tag(GuideSettings.automaticLanguage)
                        ForEach(UserLanguage.all) { language in
                            Text(language.title).tag(language.serverName)
                        }
                    }
                    Picker(String(localized: "Interface language", bundle: .ui), selection: $settings.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(String(localized: "Live transcription", bundle: .ui), isOn: $settings.liveTranscription)
                    Toggle(String(localized: "Speak instructions aloud", bundle: .ui), isOn: $settings.speakAloud)
                    LabeledContent(String(localized: "Voice", bundle: .ui), value: Speaker.voiceDescription(for: model.language.voice))
                } header: {
                    Text("Language & voice")
                } footer: {
                    Text("Automatic: speak Turkish or English and Nova answers in the same language. Words printed on the device are read in their own language. Live transcription: your words appear as you speak, and Nova notices when you finish; turn it off if it cuts you off. For a more natural voice, download a Premium or Enhanced one in the iPhone's Settings › Accessibility › Read & Speak (or Spoken Content) › Voices; Nova uses the best one it finds.")
                }
                Section(String(localized: "Screen", bundle: .ui)) {
                    Picker(String(localized: "Screen orientation", bundle: .ui), selection: $settings.orientation) {
                        ForEach(OrientationChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                }
                Section {
                    if ARGuideController.hasUltraWide {
                        Picker(String(localized: "Field of view", bundle: .ui), selection: $settings.lens) {
                            ForEach(LensChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                    }
                    Toggle(String(localized: "High detail (small labels)", bundle: .ui), isOn: $settings.highDetail)
                    Picker(String(localized: "Torch", bundle: .ui), selection: $settings.torch) {
                        ForEach(TorchChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    LabeledContent(String(localized: "In use", bundle: .ui), value: ar.activeCamera)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("The default is the widest camera this iPhone can use with the markers: more of the panel is in view, and wide panels fit in one frame. High detail is for small labels. Automatic torch: on in the dark; it goes off for a moment now and then to check the room, and stays off when there is enough light.")
                }
                Section(String(localized: "Task guidance", bundle: .ui)) {
                    Toggle(String(localized: "Verify each step", bundle: .ui), isOn: $settings.verifyEach)
                    Toggle(String(localized: "Continue 5 s after a check", bundle: .ui), isOn: $settings.autoContinue)
                        .disabled(!settings.verifyEach)
                    Toggle(String(localized: "Haptics", bundle: .ui), isOn: $settings.haptics)
                }
                Section {
                    Toggle(String(localized: "Record tasks on screen", bundle: .ui), isOn: $settings.screenRecording)
                    Button { showLastRecording = true } label: {
                        LabeledContent(String(localized: "Share the last recording", bundle: .ui), value: lastRecordingText)
                    }
                    .foregroundStyle(.primary)
                    .disabled(screenRecorder.last == nil)
                } header: {
                    Text("Screen recording")
                } footer: {
                    Text("When on, each task is recorded without sound; recording pauses while Nova thinks. The video stays on the phone; save it to Photos or share it from here.")
                }
                Section {
                    TextField(String(localized: "Internet address", bundle: .ui), text: $settings.publicURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(String(localized: "Invite code", bundle: .ui), text: $settings.inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField(String(localized: "Mac over Tailscale", bundle: .ui), text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent(String(localized: "Status", bundle: .ui), value: connectionText)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The internet address is tried first and needs your invite code, kept in this iPhone's Keychain. The Mac over Tailscale is the fallback. The phone never holds the API key.")
                }
                #if DEBUG
                Section {
                    Picker(String(localized: "Model", bundle: .ui), selection: $settings.sparkProvider) {
                        ForEach(SparkProvider.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(String(localized: "Thinking", bundle: .ui), selection: $settings.sparkEffort) {
                        ForEach(SparkEffort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(String(localized: "Show timings on the camera screen", bundle: .ui), isOn: $settings.showTimings)
                    LabeledContent(String(localized: "Last task", bundle: .ui),
                                   value: model.timings.isEmpty ? String(localized: "none yet", bundle: .ui) : model.timings.summary)
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
                    Toggle(String(localized: "Recording mode (for testing)", bundle: .ui), isOn: $settings.record)
                } footer: {
                    Text("When on, each frame and answer is saved on the Mac for testing; nothing is kept on the phone. Audio is never saved. Only invite codes allowed to record can use it.")
                }
                Section {
                    Button(String(localized: "How Nova works", bundle: .ui)) { showHow = true }
                    Link(String(localized: "Privacy and terms", bundle: .ui), destination: ConsentView.legalURL)
                    LabeledContent(String(localized: "Version", bundle: .ui), value: version)
                    LabeledContent(String(localized: "Depth sensor", bundle: .ui), value: ar.hasLiDAR ? String(localized: "LiDAR", bundle: .ui) : String(localized: "None (less precise)", bundle: .ui))
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
                    Button(String(localized: "Close", bundle: .ui)) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showHow) {
                HowView(buttonTitle: String(localized: "Close", bundle: .ui)) { showHow = false }
            }
            .sheet(isPresented: $showLastRecording) {
                if let last = screenRecorder.last { RecordingPreview(video: last) }
            }
        }
    }

    private var lastRecordingText: String {
        guard let last = screenRecorder.last else { return String(localized: "none yet", bundle: .ui) }
        guard let seconds = last.seconds else { return "" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private var connectionText: String {
        switch model.connection {
        case .connected(.internet): String(localized: "Connected over the internet", bundle: .ui)
        case .connected(.tailscale): String(localized: "Connected to the Mac (Tailscale)", bundle: .ui)
        case .rejected: String(localized: "Invite code not accepted", bundle: .ui)
        case .noKey: String(localized: "The Mac has no API key", bundle: .ui)
        case .unreachable: String(localized: "Mac not reachable", bundle: .ui)
        case .unknown: String(localized: "Checking…", bundle: .ui)
        }
    }
}
