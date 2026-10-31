import SwiftUI

@main
struct NovaGuideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: GuideSettings
    @StateObject private var ar: ARGuideController
    @StateObject private var model: GuideModel
    @StateObject private var screenRecorder = ScreenRecorder()

    init() {
        let settings = GuideSettings()
        let ar = ARGuideController()
        let model = GuideModel(settings: settings, ar: ar)
        #if DEBUG
        settings.turnOnRecordingForTesting()
        DemoMode.prepare(settings: settings, model: model)
        #endif
        _settings = StateObject(wrappedValue: settings)
        _ar = StateObject(wrappedValue: ar)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(ar)
                .environmentObject(model)
                .environmentObject(screenRecorder)
                .environment(\.locale, Locale(identifier: settings.interfaceCode))
                .id(settings.interfaceCode)  // every view reads its strings again in the new language
        }
    }
}

/// Onboarding until the current terms are accepted, then how Nova works and the camera. Later launches and Home open the welcome screen;
/// its Get Started goes straight to the camera.
struct RootView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.scenePhase) private var scenePhase
    private static var demoStarted = false
    @State private var showHow = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if settings.needsConsent {
                OnboardingView()
            } else if model.showHowNext {
                HowView(buttonTitle: String(localized: "Continue", bundle: .ui)) { model.showHowNext = false }
            } else if settings.needsInviteCode || model.inviteRejected {
                InviteView()
            } else if model.showWelcome {
                WelcomeView(onStart: { model.showWelcome = false }, onHow: { showHow = true }, onSettings: { showSettings = true })
                    .sheet(isPresented: $showSettings) { SettingsView() }
                    .fullScreenCover(isPresented: $showHow) {
                        HowView(buttonTitle: String(localized: "Continue", bundle: .ui)) {
                            showHow = false
                            model.showWelcome = false
                        }
                    }
            } else {
                CameraScreen()
            }
        }
        .onAppear { OrientationLock.apply(settings.orientation) }
        .task { await model.checkConnection() }
        .task { await filmDemo() }
        .onChange(of: model.showWelcome) { _, home in
            if home { screenRecorder.finishDemo() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { screenRecorder.finishDemo() }  // ReplayKit stops here anyway: keep what was filmed
        }
        .sheet(isPresented: $screenRecorder.demoFinished) {
            if let last = screenRecorder.last { RecordingPreview(video: last) }
        }
        .alert(String(localized: "The demo video couldn't be saved.", bundle: .ui), isPresented: $screenRecorder.demoFailed) {
            Button(String(localized: "OK", bundle: .ui), role: .cancel) {}
        }
        .onOpenURL { link in
            guard let code = Route.inviteCode(from: link) else { return }
            Task { _ = await model.tryInvite(code) }
        }
        .onChange(of: settings.orientation) { _, choice in OrientationLock.apply(choice) }
    }
}

extension RootView {
    /// Settings › Demo video: once per launch, from the first screen. Waiting is left out of the video, but a sentence
    /// already being spoken is finished first, so words aren't cut.
    private func filmDemo() async {
        guard settings.demoVideo, !Self.demoStarted else { return }
        Self.demoStarted = true
        screenRecorder.beginDemo()
        while !Task.isCancelled, screenRecorder.isDemo {
            screenRecorder.setPaused(model.isWaiting && !model.isSpeaking)
            try? await Task.sleep(for: .seconds(0.2))
        }
    }
}

/// Settings › Screen orientation: which ways the interface may turn.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

@MainActor
enum OrientationLock {
    static func apply(_ choice: OrientationChoice) {
        let mask: UIInterfaceOrientationMask = switch choice {
        case .automatic: .allButUpsideDown
        case .portrait: .portrait
        case .landscape: .landscape
        }
        AppDelegate.orientations = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
