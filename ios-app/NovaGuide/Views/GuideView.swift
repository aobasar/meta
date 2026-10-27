import RealityKit
import SwiftUI

/// The one screen: camera full screen, chips on top, the marker over the control, and a card at the bottom.
struct GuideView: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var settings: GuideSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    private var ringTint: Color {
        switch model.feedback {
        case .correct: .green
        case .notDone: .red
        default: .yellow
        }
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: ar.arView).ignoresSafeArea()
            if model.phase == .guiding, let marker = ar.marker {
                MarkerOverlay(marker: marker, setTo: model.currentStep?.setTo, tint: ringTint).ignoresSafeArea()
            }
            if model.phase == .thinking {
                ThinkingSweep().ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                TopBar(showSettings: $showSettings)
                if let issue = ar.trackingIssue, model.phase != .thinking {
                    Chip(text: issue, systemImage: "exclamationmark.triangle.fill", tint: .orange).padding(.top, 8)
                }
                if let heard = model.heard {
                    Chip(text: "“\(heard)”", systemImage: "quote.bubble.fill").padding(.top, 8)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    BottomPanel()
                    if model.phase != .thinking {
                        MicrophoneButton(recorder: model.recorder)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.checkConnection() } }) {
            SettingsView()
        }
        .onAppear { ar.start() }
        .task { await model.checkConnection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ar.start() } else if phase == .background { ar.pause() }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: Top bar

private struct TopBar: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var settings: GuideSettings
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let plan = model.plan, !plan.deviceLabel.isEmpty {
                Chip(text: plan.deviceLabel, systemImage: "viewfinder")
            }
            Chip(text: settings.language.title, systemImage: "globe")
            connectionChip
            if settings.record {
                Chip(text: String(localized: "Recording"), systemImage: "record.circle", tint: .red)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(Text("Settings"))
        }
    }

    @ViewBuilder private var connectionChip: some View {
        switch model.connection {
        case .connected: Chip(text: String(localized: "Mac connected"), systemImage: "checkmark.circle.fill", tint: .green)
        case .noKey: Chip(text: String(localized: "The Mac has no API key"), systemImage: "key.fill", tint: .orange)
        case .unreachable: Chip(text: String(localized: "Mac not reachable"), systemImage: "wifi.exclamationmark", tint: .orange)
        case .unknown: EmptyView()
        }
    }
}

struct Chip: View {
    var text: String
    var systemImage: String
    var tint: Color = .white

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .labelStyle(TintedIconLabelStyle(tint: tint))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: Thinking

private struct ThinkingSweep: View {
    @State private var offset: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.35)
                .offset(x: offset * geometry.size.width)
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { offset = 1 }
                }
        }
        .background(Color.black.opacity(0.15))
    }
}

// MARK: Microphone

/// The large red microphone: tap to talk, tap again (or pause) to finish. It is the only way the microphone opens.
private struct MicrophoneButton: View {
    @EnvironmentObject private var model: GuideModel
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        VStack(spacing: 6) {
            if let status {
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Button { model.microphoneTapped() } label: {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.35))
                        .frame(width: 84, height: 84)
                        .scaleEffect(recorder.isRecording ? 1 + CGFloat(recorder.level) * 0.5 : 1)
                        .animation(.easeOut(duration: 0.12), value: recorder.level)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.4), radius: 6)
                    if model.listening == .transcribing || model.listening == .answering {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(model.listening == .transcribing || model.listening == .answering)
            .accessibilityLabel(Text(recorder.isRecording ? "Stop listening" : "Talk to Nova"))
        }
    }

    private var status: String? {
        switch model.listening {
        case .listening: String(localized: "Listening…")
        case .transcribing: String(localized: "Understanding…")
        case .answering: String(localized: "Thinking…")
        case .idle: nil
        }
    }
}
