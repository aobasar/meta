import SwiftUI

@main
struct NovaGuideApp: App {
    @StateObject private var settings: GuideSettings
    @StateObject private var ar: ARGuideController
    @StateObject private var model: GuideModel

    init() {
        let settings = GuideSettings()
        let ar = ARGuideController()
        _settings = StateObject(wrappedValue: settings)
        _ar = StateObject(wrappedValue: ar)
        _model = StateObject(wrappedValue: GuideModel(settings: settings, ar: ar))
    }

    var body: some Scene {
        WindowGroup {
            GuideView()
                .environmentObject(settings)
                .environmentObject(ar)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
