#if DEBUG
import SwiftUI

/// Simulator screenshots only, in Debug builds: `-NovaDemo <screen>` shows a screen with a fixed washing-machine plan
/// and a drawn panel, since ARKit and the camera don't run in the simulator. Screens: welcome, how, consent, ready,
/// thinking, guiding, verified, correction, finished.
@MainActor
enum DemoMode {
    static var screen: String? { UserDefaults.standard.string(forKey: "NovaDemo") }

    static var onboardingPage: OnboardingView.Page? {
        switch screen {
        case "how": .how
        case "consent": .consent
        default: nil
        }
    }

    static func prepare(settings: GuideSettings, model: GuideModel) {
        guard let screen else { return }
        if ["welcome", "how", "consent"].contains(screen) {
            settings.forgetTerms()
            return
        }
        if settings.needsConsent { settings.acceptTerms() }
        model.showWelcome = false
        model.loadDemo(screen, plan: plan, correction: "Düğme hâlâ “light” konumunda. Biraz daha sağa, “regular” yazısına çevirin.")
    }

    static func placeMarker(in size: CGSize, ar: ARGuideController) {
        guard let screen, ["guiding", "verified", "correction"].contains(screen), size.width > 0 else { return }
        ar.showDemoMarker(MarkerState(center: CGPoint(x: size.width * 0.72, y: size.height * 0.4), radius: 22, onScreen: true,
                                      direction: CGVector(dx: 0, dy: -1),
                                      label: CGPoint(x: size.width * 0.8, y: size.height * 0.24), precise: true))
    }

    static let plan: GuidePlan = {
        let json = """
        {"device": {"type": "çamaşır makinesi", "brand": "Maytag"}, "safe": true, "safetyNote": "", "uncertainty": "",
         "frame": {"width": 1600, "height": 900}, "served": [],
         "steps": [
          {"instruction": "Sıcaklık düğmesini warm konumuna getirin.", "detail": "Gösterge çizgisi “warm” yazısını gösterene kadar çevirin.",
           "target": "temperature knob", "success": "pointer at warm", "point": {"x": 0.14, "y": 0.43}, "boxMethod": "point",
           "setTo": {"label": "warm", "meaning": "ılık su"}, "verifiable": true},
          {"instruction": "Kir seviyesi düğmesini regular soil konumuna getirin.", "detail": "Sağdaki küçük düğme; “regular” yazısına kadar çevirin.",
           "target": "soil level knob", "success": "pointer at regular", "point": {"x": 0.75, "y": 0.41}, "boxMethod": "point", "motion": "turn_clockwise",
           "setTo": {"label": "regular soil", "meaning": "normal kir"}, "verifiable": true},
          {"instruction": "Ana program düğmesini normal konumuna çevirin.", "detail": "Ortadaki büyük düğme; ok “normal” bölümünü göstermeli.",
           "target": "program dial", "success": "arrow inside normal", "point": {"x": 0.5, "y": 0.42}, "boxMethod": "point",
           "setTo": {"label": "normal", "meaning": "normal yıkama"}, "verifiable": true},
          {"instruction": "Başlatmak için aynı düğmeyi dışarı doğru çekin.", "detail": "Bu adımın sonucu fotoğrafta görünmez; Nova kontrol etmez.",
           "target": "program dial", "success": "no visible change", "point": {"x": 0.5, "y": 0.42}, "boxMethod": "point", "verifiable": false}
         ]}
        """
        return try! JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8))
    }()
}

/// A drawn control panel behind the demo marker: three knobs on a brushed strip.
struct DemoBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.85))
                    .frame(width: w * 0.94, height: h * 0.36)
                    .position(x: w / 2, y: h * 0.4)
                ForEach([(0.22, 30.0), (0.5, 46.0), (0.72, 22.0)], id: \.0) { x, radius in
                    Circle().fill(Color(white: 0.95)).frame(width: radius * 2, height: radius * 2)
                        .overlay(Circle().stroke(Color(white: 0.6), lineWidth: 3))
                        .overlay(Rectangle().fill(Color(white: 0.35)).frame(width: 4, height: radius * 0.8).offset(y: -radius * 0.45))
                        .position(x: w * x, y: h * 0.4)
                }
                ForEach(["light", "regular", "heavy"], id: \.self) { label in
                    let i = ["light", "regular", "heavy"].firstIndex(of: label)!
                    Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(white: 0.3))
                        .position(x: w * (0.62 + Double(i) * 0.1), y: h * 0.27)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
