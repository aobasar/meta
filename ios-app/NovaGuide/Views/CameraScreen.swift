import RealityKit
import SwiftUI

/// The camera screen: the camera fills the screen, with one card over it (at the bottom in portrait, at the right in
/// landscape, under the thumb). Everything used rarely is behind the ⋯ button.
struct CameraScreen: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: Panel?
    @State private var markerShown = 0

    enum Panel: String, Identifiable {
        case more, settings
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let land = geometry.size.width > geometry.size.height
            ZStack(alignment: land ? .bottomTrailing : .bottom) {
                cameraArea(land: land)
                SidePanel(land: land)
                    .frame(maxWidth: land ? 300 : .infinity)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $panel, onDismiss: { Task { await model.checkConnection() } }) { which in
            switch which {
            case .more:
                MoreMenu { panel = $0 }
                    .presentationDetents([.large])  // every action in view, with the camera out of the way
            case .settings:
                SettingsView()
            }
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
        .alert(String(localized: "Screen recording", bundle: .ui), isPresented: Binding(
            get: { screenRecorder.failure != nil }, set: { if !$0 { screenRecorder.failure = nil } })) {
            Button(String(localized: "OK", bundle: .ui), role: .cancel) {}
        } message: {
            Text(screenRecorder.failure ?? "")
        }
        .onChange(of: model.phase) { old, phase in
            if phase == .asking { model.greet() }
            // Settings › Screen recording: each task is one video, from the question to the last step.
            var taskIsRunning = old == .guiding || old == .confirming
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
                // A tap on the camera, or a new step, shows the ring and the motion again.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { markerShown += 1 }
                MarkerOverlay(marker: marker, tint: ringTint, motion: model.currentStep?.motionKind)
                    .id("\(model.stepIndex)-\(markerShown)")
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
            VStack(spacing: 8) {
                TopBar { panel = .more }
                #if DEBUG
                if settings.showTimings && !model.timings.isEmpty {
                    Text(model.timings.summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.trailing, land ? 310 : 0)  // beside the card, which can be tall in landscape
                        .allowsHitTesting(false)
                }
                #endif
                if let issue = ar.trackingIssue, model.phase != .thinking {
                    Chip(text: issue, systemImage: "exclamationmark.triangle.fill", tint: .novaOrange)
                }
                if let problem = connectionProblem {
                    Chip(text: problem, systemImage: "wifi.exclamationmark", tint: .novaOrange)
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
        case .rejected: String(localized: "Invite code not accepted", bundle: .ui)
        case .noKey: String(localized: "The Mac has no API key", bundle: .ui)
        case .unreachable: String(localized: "Mac not reachable", bundle: .ui)
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

/// Only what can't wait: the torch while it is lit, and ⋯ for everything else. Its dot shows the connection.
private struct TopBar: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    var openMore: () -> Void
    @EnvironmentObject private var settings: GuideSettings

    var body: some View {
        HStack(spacing: 6) {
            if settings.record {  // frames are being kept on the Mac: never silently
                Text(verbatim: "REC").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.novaRed, in: Capsule())
            }
            Spacer(minLength: 6)
            if ar.torchOn {
                // The torch is lit (automatically in the dark, or from Settings): one tap turns it off for this task.
                RoundIconButton(action: { ar.turnTorchOffForTask() }, accessibility: Text("Turn the torch off")) {
                    Image(systemName: "flashlight.on.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.novaYellow)
                }
            }
            RoundIconButton(action: openMore, accessibility: Text("More options")) {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(dotColor).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.novaCard, lineWidth: 2))
                            .offset(x: 10, y: -10)
                    }
            }
        }
    }

    private var dotColor: Color {
        switch model.connection {
        case .connected: .novaGreen
        case .unknown: .gray
        default: .novaOrange
        }
    }
}

/// ⋯: everything used rarely, two taps away.
private struct MoreMenu: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    var open: (CameraScreen.Panel) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.phase == .guiding, model.currentStep != nil {
                    Section {
                        row("Say it again", "speaker.wave.2") { model.repeatStep() }
                        row("Re-evaluate", "arrow.triangle.2.circlepath") { model.reassess() }
                        row("Explain it in more detail", "text.bubble") { model.explainMore() }
                        row("The marker is in the wrong place", "scope") { model.startMovingMarker() }
                        row("This step is wrong", "exclamationmark.bubble") { model.openCorrection() }
                        row("Previous step", "chevron.left") { model.back() }
                    }
                }
                Section {
                    row("Start over", "arrow.counterclockwise") { model.newTask(keepDevice: true) }
                    Button { open(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                    row("Home", "house") { model.goHome() }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let device = model.knownDevice { Text(device) }
                        Text("AI-generated guidance. Check before you press.")
                    }
                }
            }
            .tint(.primary)  // dark rows: the default blue is hard to read
            .navigationTitle(Text("More options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Close", bundle: .ui)) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
        .presentationBackground(Color.sheetGround)  // solid: the camera must not show through the text
    }

    private func row(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Label(title, systemImage: icon)
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

// MARK: Microphone

struct Waveform: View {
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
