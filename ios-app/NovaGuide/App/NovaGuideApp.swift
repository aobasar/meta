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
                .preferredColorScheme(.dark)
        }
    }
}

/// Onboarding until the current terms are accepted, then the camera. Later launches and Home open the welcome screen;
/// its Get Started goes straight to the camera.
struct RootView: View {
    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var model: GuideModel
    @State private var showHow = false

    var body: some View {
        Group {
            if settings.needsConsent {
                OnboardingView()
            } else if model.showWelcome {
                WelcomeView(onStart: { model.showWelcome = false }, onHow: { showHow = true })
                    .fullScreenCover(isPresented: $showHow) {
                        HowView(buttonTitle: String(localized: "Continue")) {
                            showHow = false
                            model.showWelcome = false
                        }
                    }
            } else {
                CameraScreen()
            }
        }
        .onAppear { OrientationLock.apply(settings.orientation) }
        .onChange(of: settings.orientation) { _, choice in OrientationLock.apply(choice) }
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
