import Combine
import RealityKit
import SwiftUI

/// The camera screen: the whole camera frame, the same one Spark gets, with one card (at the bottom in portrait, at the
/// right in landscape, under the thumb, until the user drags it elsewhere). Everything used rarely is behind the ⋯ button.
struct CameraScreen: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: Panel?
    @State private var markerShown = 0
    @State private var showStoppedVideo = false
    @State private var focusMark: FocusMark.Tap?
    @State private var sceneOrientation = UIInterfaceOrientation.unknown

    enum Panel: String, Identifiable {
        case more, settings, recording
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let land = geometry.size.width > geometry.size.height
            let place = land ? settings.cardLandscape : settings.cardPortrait
            let docked = land && settings.cardDocked
            // Away from the Dynamic Island the panel can use the screen's edge, so it takes less of the camera.
            // Read fresh: the launch can turn the screen after the first read. The state only asks for a redraw.
            let _ = sceneOrientation
            let orientation = Self.currentOrientation
            let edgeIsFree = place.left ? orientation == .landscapeLeft : orientation == .landscapeRight
            let inset = !docked || !edgeIsFree ? 0 : place.left ? geometry.safeAreaInsets.leading : geometry.safeAreaInsets.trailing
            ZStack(alignment: docked ? (place.left ? .leading : .trailing) : place.alignment(land: land)) {
                cameraArea(land: land, card: place, docked: docked)
                    .padding(.leading, docked && place.left ? SidePanel.dockedWidth - inset : 0)
                    .padding(.trailing, docked && !place.left ? SidePanel.dockedWidth - inset : 0)
                SidePanel(land: land, docked: docked)
                    .frame(maxWidth: docked ? SidePanel.dockedWidth : land ? SidePanel.width : .infinity, maxHeight: docked ? .infinity : nil)
                    .padding(.horizontal, docked ? 0 : 8)
                    .padding(.vertical, docked ? 0 : 8)
                    .offset(x: place.left ? -inset : inset)
            }
        }
        // Later than the turn itself would read the old side.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification).delay(for: .seconds(0.4), scheduler: RunLoop.main)) { _ in readOrientation() }
        .onAppear(perform: readOrientation)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $panel, onDismiss: { Task { await model.checkConnection() } }) { which in
            switch which {
            case .more:
                MoreMenu { panel = $0 }
                    .presentationDetents([.large])  // every action in view, with the camera out of the way
            case .settings:
                SettingsView()
            case .recording:
                if let last = screenRecorder.last { RecordingPreview(video: last) }
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
        .onChange(of: screenRecorder.state) { _, state in
            if state == .off && showStoppedVideo {
                showStoppedVideo = false
                if screenRecorder.last != nil { panel = .recording }
            }
        }
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
            if case .showing = old { taskIsRunning = true }
            if phase == .thinking && !taskIsRunning && settings.screenRecording {
                screenRecorder.beginTask(paused: true)
            } else if phase == .finished || phase == .asking {
                screenRecorder.finishTask()
            }
        }
    }

    private func readOrientation() {
        sceneOrientation = Self.currentOrientation
    }

    private static var currentOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .unknown
    }

    /// The user stops the video: it is kept and shown, and the next task isn't recorded until Settings turns it on again.
    private func stopRecording() {
        settings.screenRecording = false
        showStoppedVideo = true
        screenRecorder.finishTask()
    }

    private func cameraArea(land: Bool, card: CardPlace, docked: Bool) -> some View {
        // The top bar stays clear of the card: at the bottom under a card on top, and beside it in landscape.
        let barsAtBottom = !land && card.top
        return ZStack {
            cameraPicture(land: land, card: card, docked: docked)
            VStack(spacing: 8) {
                if barsAtBottom { Spacer() }
                TopBar(openMore: { panel = .more }, stopRecording: stopRecording)
                #if DEBUG
                if settings.showTimings && !model.timings.isEmpty {
                    Text(model.timings.summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                if !barsAtBottom { Spacer() }
            }
            .padding(.horizontal, 14)
            .padding(.leading, land && !docked && card.left ? SidePanel.width : 0)
            .padding(.trailing, land && !docked && !card.left ? SidePanel.width : 0)
            .padding(barsAtBottom ? .bottom : .top, 12)
        }
    }

    /// The whole frame and what is drawn on it, at the frame's own shape: the screen shows exactly what Spark reads, and
    /// the markers and taps share the camera view's points. A tap beside the picture does nothing.
    private func cameraPicture(land: Bool, card: CardPlace, docked: Bool) -> some View {
        ZStack {
            ARViewContainer(arView: ar.arView)
            #if DEBUG
            if DemoMode.screen != nil { DemoBackdrop() }
            #endif
            // A tap on the camera focuses there. A tap, or a new step, also shows the ring and the motion again.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .global) { global in
                    let point = ar.cameraPoint(fromGlobal: global)
                    ar.focus(atScreen: point)
                    focusMark = FocusMark.Tap(point: point)
                    markerShown += 1
                }
            if let focusMark {
                FocusMark(tap: focusMark)
                    .id(focusMark.id)
                    .allowsHitTesting(false)
            }
            if model.phase == .guiding, let marker = ar.marker {
                MarkerOverlay(marker: marker, tint: ringTint, motion: model.feedback == .correct ? nil : model.currentStep?.motionKind, brightness: handBrightness)
                    .id("\(model.stepIndex)-\(markerShown)")
            }
            if model.correcting == .moving {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .global) { model.markerTapped(at: ar.cameraPoint(fromGlobal: $0)) }
            }
            if model.phase == .thinking {
                ScanOverlay().padding(.horizontal, 20).padding(.vertical, 60)
                    .allowsHitTesting(false)
            }
        }
        #if DEBUG
        .background(GeometryReader { geometry in
            Color.clear.onAppear { DemoMode.placeMarker(in: geometry.size, ar: ar) }
                .onChange(of: geometry.size) { _, size in DemoMode.placeMarker(in: size, ar: ar) }
        })
        #endif
        .aspectRatio(land ? ar.frameAspect : 1 / ar.frameAspect, contentMode: .fit)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pictureAlignment(land: land, card: card, docked: docked))
        // Landscape uses the full height and the edges beside the panel. Portrait stays below the Dynamic Island.
        .ignoresSafeArea(.all, edges: land ? Edge.Set.all : Edge.Set())
    }

    /// The free room stays together: under the picture for a card in portrait, beside it in landscape.
    private func pictureAlignment(land: Bool, card: CardPlace, docked: Bool) -> Alignment {
        guard land else { return card.top ? .bottom : .top }
        return docked == card.left ? .leading : .trailing
    }

    private var cameraOptions: CameraOptions {
        CameraOptions(lens: settings.lens, highDetail: settings.highDetail, torch: settings.torch)
    }

    /// Settings › Hand animation: how the hand reads the picture behind it, or nil for no hand.
    private var handBrightness: ((CGPoint) -> Double?)? {
        settings.handAnimation ? { ar.brightness(atScreen: $0) } : nil
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
        case .noKey: String(localized: "The server has no API key", bundle: .ui)
        case .unreachable: String(localized: "Kokobubu is not reachable", bundle: .ui)
        case .connected, .unknown: nil
        }
    }
}

/// A small yellow square where the user tapped to focus; it fades by itself.
private struct FocusMark: View {
    struct Tap: Equatable {
        let id = UUID()
        var point: CGPoint
    }

    var tap: Tap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var gone = false

    var body: some View {
        GeometryReader { _ in
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.novaYellow, lineWidth: 2)
                .frame(width: 70, height: 70)
                .scaleEffect(settled || reduceMotion ? 1 : 1.35)
                .opacity(gone ? 0 : 1)
                .position(tap.point)
        }
        .accessibilityHidden(true)
        .task {
            withAnimation(.easeOut(duration: 0.2)) { settled = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeIn(duration: 0.3)) { gone = true }
        }
    }
}

extension CardPlace {
    func alignment(land: Bool) -> Alignment {
        guard land else { return top ? .top : .bottom }
        switch (top, left) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
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
    var stopRecording: () -> Void
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var screenRecorder: ScreenRecorder

    private var isRecordingScreen: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "NovaDemoRecording") { return true }  // simulator screenshots
        #endif
        return screenRecorder.isActive
    }

    var body: some View {
        HStack(spacing: 6) {
            if settings.record {  // frames are being kept on the Mac: never silently
                Text(verbatim: "REC").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.novaRed, in: Capsule())
            }
            if isRecordingScreen {
                Button(action: stopRecording) {
                    Label(String(localized: "Stop recording", bundle: .ui), systemImage: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.novaRed, in: Capsule())
                }
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
    var color = Color.white
    private static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 3) {
            ForEach([12.0, 20, 14, 22], id: \.self) { base in
                Capsule().fill(color)
                    .frame(width: 4, height: min(base * (0.6 + CGFloat(recorder.level) * 1.6), Self.height))
            }
        }
        // A fixed box: the voice moves the bars, never the card around them.
        .frame(height: Self.height)
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
