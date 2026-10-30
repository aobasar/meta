import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var showHow = false
    @State private var showLastRecording = false
    @State private var showAdvanced = false
    @State private var showDeveloper = false
    @State private var copied = false

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") + " Beta"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Interface language", bundle: .ui), selection: $settings.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(String(localized: "Speak instructions aloud", bundle: .ui), isOn: $settings.speakAloud)
                    Toggle(String(localized: "Sound effects", bundle: .ui), isOn: $settings.soundEffects)
                    Picker(String(localized: "Torch", bundle: .ui), selection: $settings.torch) {
                        ForEach(TorchChoice.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent(String(localized: "Voice", bundle: .ui), value: Speaker.voiceDescription(for: model.language.voice))
                } footer: {
                    Text("For a more natural voice, download a Premium or Enhanced one in the iPhone's Settings › Accessibility › Read & Speak (or Spoken Content) › Voices; Kokobubu uses the best one it finds.")
                }
                Section {
                    DisclosureGroup(String(localized: "Advanced", bundle: .ui), isExpanded: $showAdvanced) {
                        Picker(String(localized: "I speak", bundle: .ui), selection: $settings.languageName) {
                            Text("Automatic").tag(GuideSettings.automaticLanguage)
                            ForEach(UserLanguage.all) { Text($0.title).tag($0.serverName) }
                        }
                        Toggle(String(localized: "Live transcription", bundle: .ui), isOn: $settings.liveTranscription)
                        Picker(String(localized: "Screen orientation", bundle: .ui), selection: $settings.orientation) {
                            ForEach(OrientationChoice.allCases) { Text($0.title).tag($0) }
                        }
                        if ARGuideController.hasUltraWide {
                            Picker(String(localized: "Field of view", bundle: .ui), selection: $settings.lens) {
                                ForEach(LensChoice.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        Toggle(String(localized: "High detail (small labels)", bundle: .ui), isOn: $settings.highDetail)
                        Toggle(String(localized: "Verify each step", bundle: .ui), isOn: $settings.verifyEach)
                        Toggle(String(localized: "Continue 5 s after a check", bundle: .ui), isOn: $settings.autoContinue)
                            .disabled(!settings.verifyEach)
                        Toggle(String(localized: "Haptics", bundle: .ui), isOn: $settings.haptics)
                        Toggle(String(localized: "Record tasks on screen", bundle: .ui), isOn: $settings.screenRecording)
                        Button { showLastRecording = true } label: {
                            LabeledContent(String(localized: "Share the last recording", bundle: .ui), value: lastRecordingText)
                        }
                        .foregroundStyle(.primary)
                        .disabled(screenRecorder.last == nil)
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
                        Button(String(localized: "How Kokobubu works", bundle: .ui)) { showHow = true }
                        Link(String(localized: "Privacy", bundle: .ui), destination: ConsentView.legalURL)
                    }
                }
                #if DEBUG
                Section {
                    DisclosureGroup(String(localized: "Developer", bundle: .ui), isExpanded: $showDeveloper) {
                        Picker(String(localized: "Model", bundle: .ui), selection: $settings.sparkProvider) {
                            ForEach(SparkProvider.allCases) { Text($0.title).tag($0) }
                        }
                        Picker(String(localized: "Thinking", bundle: .ui), selection: $settings.sparkEffort) {
                            ForEach(SparkEffort.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledContent(String(localized: "Reasoning", bundle: .ui), value: reasoningModel)
                        LabeledContent(String(localized: "Finding controls", bundle: .ui), value: "sam-3.1")
                        LabeledContent(String(localized: "Voice to text", bundle: .ui), value: "muse-voice-transcribe-1.0")
                        LabeledContent(String(localized: "Last task", bundle: .ui),
                                       value: model.timings.isEmpty ? String(localized: "none yet", bundle: .ui) : model.timings.summary)
                        Toggle(String(localized: "Show timings on the camera screen", bundle: .ui), isOn: $settings.showTimings)
                        Toggle(String(localized: "Recording mode (for testing)", bundle: .ui), isOn: $settings.record)
                        LabeledContent(String(localized: "Connection", bundle: .ui), value: connectionText)
                        LabeledContent(String(localized: "In use", bundle: .ui), value: ar.activeCamera)
                        LabeledContent(String(localized: "Depth sensor", bundle: .ui), value: depthText)
                        LabeledContent(String(localized: "AR tracking", bundle: .ui), value: ar.trackingIssue ?? String(localized: "Normal", bundle: .ui))
                        LabeledContent(String(localized: "Version", bundle: .ui), value: version)
                        Button(copied ? String(localized: "Copied", bundle: .ui) : String(localized: "Copy debug report", bundle: .ui)) {
                            UIPasteboard.general.string = debugReport
                            copied = true
                        }
                        if settings.sparkProvider == .baseten { Text("Built with Muse Spark Open") }
                    }
                } footer: {
                    if showDeveloper {
                        Text("Timings are measured on the phone, network included. Only Muse Spark moves; SAM and voice recognition stay on Meta. The report has no frames, words or keys.")
                    }
                }
                #endif
                Section {
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
            .preferredColorScheme(.light)
            .fullScreenCover(isPresented: $showHow) {
                HowView(buttonTitle: String(localized: "Close", bundle: .ui)) { showHow = false }
            }
            .sheet(isPresented: $showLastRecording) {
                if let last = screenRecorder.last { RecordingPreview(video: last) }
            }
        }
        .presentationBackground(Color.sheetGround)
    }

    private var depthText: String {
        ar.hasLiDAR ? String(localized: "LiDAR", bundle: .ui) : String(localized: "None (less precise)", bundle: .ui)
    }

    private var reasoningModel: String {
        (settings.sparkProvider == .baseten ? "muse-spark-open-1026" : "muse-spark-1.3") + " · " + settings.sparkEffort.rawValue
    }

    /// For pasting into a bug report; no frames, words or keys.
    private var debugReport: String {
        ["Kokobubu debug report", "version: \(version)", "phase: \(model.phase)", "step: \(model.stepIndex + 1)",
         "reasoning: \(reasoningModel)", "provider: \(settings.sparkProvider.rawValue)", "controls: sam-3.1",
         "voice: muse-voice-transcribe-1.0, live: \(settings.liveTranscription)", "connection: \(model.connection)",
         "camera: \(ar.activeCamera), depth: \(ar.hasLiDAR)", "tracking: \(ar.trackingIssue ?? "normal")",
         "torch: \(settings.torch.rawValue), lit: \(ar.torchOn)", "timings: \(model.timings.summary)"].joined(separator: "\n")
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
