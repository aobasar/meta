import SwiftUI
import UIKit

/// Share: the camera view with Nova's markers and the AI label drawn into one picture, then the iOS share sheet.
/// Nothing goes to the server; the user picks where the picture goes.
@MainActor
enum ShareCapture {
    static func image(ar: ARGuideController, marker: MarkerState?, setTo: GuideStep.SetTo?, tint: Color) async -> UIImage? {
        let size = ar.arView.bounds.size
        guard size.width > 0 else { return nil }
        let snapshot: UIImage? = await withCheckedContinuation { continuation in
            ar.arView.snapshot(saveToHDR: false) { continuation.resume(returning: $0) }
        }
        let content = ZStack(alignment: .bottomLeading) {
            if let snapshot {
                Image(uiImage: snapshot).resizable().scaledToFill()
            } else {
                Color.black
            }
            if let marker {
                MarkerOverlay(marker: marker, setTo: setTo, tint: tint)
            }
            Text("AI-generated guidance · Nova")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(10)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = ar.arView.window?.screen.scale ?? 3
        return renderer.uiImage
    }

    /// The iOS share sheet, over whatever is on screen.
    static func present(_ items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: 60, width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}
