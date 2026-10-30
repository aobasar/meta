import RealityKit
import SwiftUI

/// The camera screen. Portrait: the camera fills the screen, Pulse and the cards sit over its bottom. Landscape: the
/// camera on the left, a 300 pt column on the right under the thumb, Pulse at the bottom of the camera.
struct CameraScreen: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var tipClosed = false

    var body: some View {
        GeometryReader { geometry in
            let land = geometry.size.width > geometry.size.height
            ZStack {
                if land {
                    HStack(spacing: 0) {
                        cameraArea(land: true)
                        SidePanel(land: true)
                            .frame(width: 300)
                            .background(Color.novaColumn.ignoresSafeArea())
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        cameraArea(land: false)
                        SidePanel(land: false)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                }
                if model.phase == .finished {
                    CompletionView().transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.phase == .finished)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.checkConnection() } }) {
            SettingsView()
        }
        .onAppear {
            model.greet()
            ar.apply(cameraOptions)
            ar.start()
            UIApplication.shared.isIdleTimerDisabled = true  // the screen stays on while the camera is in use
        }
        .onDisappear {
            ar.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: cameraOptions) { _, options in ar.apply(options) }
        .task { await model.checkConnection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ar.start()
            } else if phase == .background {
                ar.pause()
                screenRecorder.discard()
            }
        }
        .onChange(of: model.isWaiting) { _, waiting in screenRecorder.setPaused(waiting) }
        .onChange(of: model.isWaiting || model.listening != .idle) { _, busy in ar.holdTorch = busy }
        .alert(String(localized: "Screen recording"), isPresented: Binding(
            get: { screenRecorder.failure != nil }, set: { if !$0 { screenRecorder.failure = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(screenRecorder.failure ?? "")
        }
        .onChange(of: model.phase) { old, phase in
            if phase == .asking { model.greet() }
            // Settings › Screen recording: each task is one video, from the question to the last step.
            var taskIsRunning = old == .guiding
            if case .choosing = old { taskIsRunning = true }
            if phase == .thinking && !taskIsRunning && settings.screenRecording {
                screenRecorder.beginTask(paused: true)
            } else if phase == .finished || phase == .asking {
                screenRecorder.finishTask()
            }
        }
    }

    private func cameraArea(land: Bool) -> some View {
        ZStack {
            ARViewContainer(arView: ar.arView).ignoresSafeArea()
            #if DEBUG
            if DemoMode.screen != nil { DemoBackdrop().ignoresSafeArea() }
            #endif
            if model.phase == .guiding, let marker = ar.marker {
                MarkerOverlay(marker: marker, setTo: model.currentStep?.setTo, tint: ringTint)
                    .id(model.stepIndex)  // each step replays the arrow, then the label tag
                    .ignoresSafeArea()
            }
            if model.correcting == .moving {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(coordinateSpace: .local) { model.markerTapped(at: $0) }
            }
            if model.phase == .thinking {
                ScanOverlay().padding(.horizontal, 20).padding(.top, land ? 60 : 110).padding(.bottom, land ? 60 : 300)
                    .allowsHitTesting(false)
            }
            if model.phase == .asking && model.plan == nil {
                ReadyHint(land: land)
            }
            VStack(spacing: 8) {
                TopBar(showSettings: $showSettings)
                #if DEBUG
                if settings.showTimings && !model.timings.isEmpty {
                    Text(model.timings.summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .allowsHitTesting(false)
                }
                #endif
                if let issue = ar.trackingIssue, model.phase != .thinking {
                    Chip(text: issue, systemImage: "exclamationmark.triangle.fill", tint: .novaOrange)
                }
                if let problem = connectionProblem {
                    Chip(text: problem, systemImage: "wifi.exclamationmark", tint: .novaOrange)
                }
                if !land && !tipClosed && model.phase != .finished {
                    RotateTip { tipClosed = true }
                        .task {
                            try? await Task.sleep(for: .seconds(5))  // hides itself, with no countdown on screen
                            withAnimation { tipClosed = true }
                        }
                }
                if let words = model.liveWords, !words.isEmpty {
                    Text(verbatim: "“\(words)”")
                        .font(.body.weight(.semibold))
                        .lineLimit(3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.novaCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .allowsHitTesting(false)
                } else if let heard = model.heard {
                    Text(verbatim: "“\(heard)”")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.novaCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Spacer()
                if land && model.phase != .finished {
                    PulseButton().padding(.bottom, 14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        #if DEBUG
        .background(GeometryReader { geometry in
            Color.clear.onAppear { DemoMode.placeMarker(in: geometry.size, ar: ar) }
                .onChange(of: geometry.size) { _, size in DemoMode.placeMarker(in: size, ar: ar) }
        }.ignoresSafeArea())
        #endif
    }

    private var cameraOptions: CameraOptions {
        CameraOptions(lens: settings.lens, highDetail: settings.highDetail, torch: settings.torch)
    }

    private var ringTint: Color {
        switch model.feedback {
        case .correct: .novaGreen
        case .notDone: .novaRed
        case .unsure: .novaOrange
        default: .novaYellow
        }
    }

    private var connectionProblem: String? {
        switch model.connection {
        case .rejected: String(localized: "Invite code not accepted")
        case .noKey: String(localized: "The Mac has no API key")
        case .unreachable: String(localized: "Mac not reachable")
        case .connected, .unknown: nil
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: Top bar

/// Home (with the recognized device) on the left, Settings on the right; recording and sharing live in Settings.
private struct TopBar: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { model.goHome() } label: {
                    Image(systemName: "house").font(.system(size: 15, weight: .semibold)).padding(.vertical, 4)
                }
                .accessibilityLabel(Text("Home"))
                if let device = model.knownDevice {
                    Rectangle().fill(Color(white: 0.28)).frame(width: 1, height: 14)
                    Text(device).font(.footnote.weight(.semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.novaCard.opacity(0.85), in: Capsule())
            Spacer(minLength: 6)
            if ar.torchOn {
                // The torch is lit (automatically in the dark, or from Settings): one tap turns it off for this task.
                RoundIconButton(action: { ar.turnTorchOffForTask() }, accessibility: Text("Turn the torch off")) {
                    Image(systemName: "flashlight.on.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.novaYellow)
                }
            }
            RoundIconButton(action: { showSettings = true }, accessibility: Text("Settings")) {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(dotColor).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.novaCard, lineWidth: 2))
                            .offset(x: 8, y: -8)
                    }
            }
        }
    }

    /// The connection at a glance: green when the server answers with its key loaded.
    private var dotColor: Color {
        switch model.connection {
        case .connected: .novaGreen
        case .unknown: .gray
        default: .novaOrange
        }
    }
}

struct Chip: View {
    var text: String
    var systemImage: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.novaCard.opacity(0.9), in: Capsule())
    }
}

private struct RotateTip: View {
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rotate.right").foregroundStyle(Color.novaYellow).font(.title3)
            Text("For wide control panels, turn your iPhone sideways. Portrait is fully supported.")
                .font(.footnote)
                .foregroundStyle(Color(white: 0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(Color.novaText2) }
                .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.novaCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Before the first question: what to do, over the camera.
private struct ReadyHint: View {
    var land: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder").font(.system(size: 52, weight: .light)).foregroundStyle(Color.novaYellow)
            Text("Point the camera at what you need help with, then tap Pulse and say what you want to do.")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: land ? 260 : 340)
        }
        .offset(y: land ? 10 : -120)
        .allowsHitTesting(false)
    }
}

/// While Nova thinks: viewfinder corners and a purple line sweeping down the frame.
private struct ScanOverlay: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.novaPurple.opacity(0.08)
                LinearGradient(colors: [.novaPurple.opacity(0), .novaPurple, .novaPurple.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                    .offset(y: sweep ? geometry.size.height - 2 : 0)
                CornerBrackets().stroke(Color.novaYellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { sweep = true }
            }
        }
    }
}

/// Corner brackets that hug any rectangle (34 pt arms, rounded corners).
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 34, round: CGFloat = 10
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0), (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * round))
            path.addQuadCurve(to: CGPoint(x: corner.x + dx * round, y: corner.y), control: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}

// MARK: Pulse

/// Pulse: the one round button. Same size in every state; only its color and content change.
struct PulseButton: View {
    @EnvironmentObject private var model: GuideModel
    @State private var glow = false

    var body: some View {
        let pulse = model.pulse
        VStack(spacing: 6) {
            Button { model.microphoneTapped() } label: {
                ZStack {
                    Circle().fill(color(pulse))
                        .shadow(color: pulse == .ready ? Color.novaYellow.opacity(glow ? 0.7 : 0.15) : .black.opacity(0.45),
                                radius: pulse == .ready ? 14 : 12, y: pulse == .ready ? 0 : 8)
                    switch pulse {
                    case .ready, .guiding:
                        Image(systemName: "mic").font(.system(size: 26, weight: .semibold)).foregroundStyle(.black)
                    case .listening:
                        Waveform(recorder: model.recorder)
                    case .thinking:
                        Orb(size: 26)
                    }
                }
                .frame(width: 68, height: 68)
                .scaleEffect(model.awaitingFirstTap && pulse == .ready && glow ? 1.08 : 1)
            }
            .disabled(pulse == .thinking)
            .accessibilityLabel(Text(label(pulse)))
            Text(label(pulse))
                .font(.footnote.weight(.bold))
                .foregroundStyle(color(pulse))
                .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                .lineLimit(1)
                .frame(width: 128)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = true } }
    }

    private func color(_ pulse: GuideModel.Pulse) -> Color {
        switch pulse {
        case .ready: .novaYellow
        case .listening: .novaRed
        case .thinking: .novaPurple
        case .guiding: .novaGreen
        }
    }

    private func label(_ pulse: GuideModel.Pulse) -> String {
        switch pulse {
        case .ready: String(localized: "Tap and talk")
        case .listening: String(localized: "Listening…")
        case .thinking: String(localized: "Thinking…")
        case .guiding: String(localized: "Ask")
        }
    }
}

private struct Waveform: View {
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        HStack(spacing: 3) {
            ForEach([12.0, 20, 14, 22], id: \.self) { base in
                Capsule().fill(.white)
                    .frame(width: 4, height: base * (0.6 + CGFloat(recorder.level) * 1.6))
            }
        }
        .animation(.easeOut(duration: 0.12), value: recorder.level)
    }
}

struct Orb: View {
    var size: CGFloat
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [.white, Color(red: 0.898, green: 0.722, blue: 1), .novaPurple],
                                 center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.6))
            .frame(width: size, height: size)
            .scaleEffect(breathe ? 1.12 : 0.9)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true } }
    }
}
