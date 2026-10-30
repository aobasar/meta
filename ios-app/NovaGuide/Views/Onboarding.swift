import SwiftUI

/// First launch: Welcome, the consent screen (App Review Guideline 5.1.2(i)), then How Nova works and the camera.
/// Nothing leaves the phone before the user agrees.
struct OnboardingView: View {
    enum Page { case welcome, how, consent }

    @EnvironmentObject private var settings: GuideSettings
    @EnvironmentObject private var model: GuideModel
    #if DEBUG
    @State private var page: Page = DemoMode.onboardingPage ?? .welcome
    #else
    @State private var page: Page = .welcome
    #endif
    @State private var sawHow = false

    var body: some View {
        Group {
            switch page {
            case .welcome:
                WelcomeView(onStart: { withAnimation { page = .consent } }, onHow: {
                    sawHow = true
                    withAnimation { page = .how }
                })
            case .how: HowView(buttonTitle: String(localized: "Continue", bundle: .ui)) { withAnimation { page = .consent } }
            case .consent: ConsentView {
                withAnimation {
                    model.showWelcome = false  // the user has just seen it
                    model.showHowNext = !sawHow
                    settings.acceptTerms()
                }
            }
            }
        }
        .transition(.opacity)
    }
}

/// Lays a screen out side by side when the phone is sideways.
private struct Orientation {
    var landscape: Bool
    init(_ size: CGSize) { landscape = size.width > size.height }
}

struct WelcomeView: View {
    var onStart: () -> Void
    var onHow: () -> Void
    /// Later launches and Home only: on first launch Settings waits until the terms are accepted.
    var onSettings: (() -> Void)? = nil

    var body: some View {
        lightScreen { GeometryReader { geometry in
            let land = Orientation(geometry.size).landscape
            ZStack(alignment: .topTrailing) {
                Color.sheetGround.ignoresSafeArea()
                if land {
                    HStack(spacing: 32) {
                        mark(logo: 192, word: 40)
                        text(land: true).frame(width: 410)
                    }
                    .padding(.horizontal, 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 40) {
                        mark(logo: 160, word: 34).frame(maxHeight: .infinity)
                        text(land: false).frame(maxWidth: 360)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 36)
                }
                if let onSettings {
                    RoundIconButton(action: onSettings, accessibility: Text("Settings")) {
                        Image(systemName: "gearshape").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 8)
                }
            }
        } }
    }

    /// The logo with "NOVA" under it, scaled together: wordmark 0.21 × logo, gap 0.09 × logo.
    private func mark(logo: CGFloat, word: CGFloat) -> some View {
        VStack(spacing: logo * 0.09) {
            NovaLogo(size: logo)
            Text(verbatim: "KOKO")
                .font(.system(size: word, weight: .light))
                .tracking(word * 0.35)
                .padding(.leading, word * 0.35)
        }
    }

    private func text(land: Bool) -> some View {
        VStack(alignment: land ? .leading : .center, spacing: land ? 22 : 40) {
            VStack(alignment: land ? .leading : .center, spacing: 10) {
                (Text("See it. Understand it.") + Text(verbatim: " ") + Text("Do it right.").foregroundColor(.novaGold))
                    .font(.system(size: land ? 21 : 24, weight: .bold))
                    .lineLimit(land ? 1 : nil)
                    .minimumScaleFactor(0.8)
                Text("Shows where to touch, guides you step by step and checks every step.")
                    .font(.subheadline)
                    .foregroundStyle(Color.sheetMuted)
            }
            .multilineTextAlignment(land ? .leading : .center)
            VStack(alignment: land ? .leading : .center, spacing: 12) {
                Button(String(localized: "Get Started", bundle: .ui), action: onStart)
                    .buttonStyle(PrimaryButtonStyle())
                Button(action: onHow) {
                    Text("How it works") + Text(verbatim: " ›")
                }
                .font(.subheadline)
                .foregroundStyle(Color.sheetMuted)
                .frame(maxWidth: .infinity)
                Text("Independent experimental prototype")
                    .font(.caption)
                    .foregroundStyle(Color.sheetMuted)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct HowView: View {
    var buttonTitle: String
    var onContinue: () -> Void

    private var cards: [(icon: String, title: String, text: String)] {
        [("viewfinder", String(localized: "Show", bundle: .ui), String(localized: "Point the camera; the right control gets marked.", bundle: .ui)),
         ("list.bullet", String(localized: "Follow", bundle: .ui), String(localized: "One step at a time, large and read aloud.", bundle: .ui)),
         ("checkmark.circle", String(localized: "Verify", bundle: .ui), String(localized: "Say “done” and Koko checks with the camera.", bundle: .ui))]
    }

    var body: some View {
        lightScreen { GeometryReader { geometry in
            let land = Orientation(geometry.size).landscape
            VStack(spacing: land ? 12 : 18) {
                Text("How Koko works")
                    .font(.system(size: land ? 20 : 24, weight: .bold))
                let layout = land ? AnyLayout(HStackLayout(alignment: .top, spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
                layout {
                    ForEach(cards, id: \.title) { card in
                        let content = land ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
                        content {
                            Image(systemName: card.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.novaGold)
                                .frame(width: land ? 36 : 44, height: land ? 36 : 44)
                                .background(Color.novaYellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: land ? .center : .leading, spacing: 3) {
                                Text(card.title).font(.system(size: land ? 16 : 18, weight: .bold))
                                Text(card.text)
                                    .font(.system(size: land ? 13 : 15))
                                    .foregroundStyle(Color.sheetMuted)
                                    .multilineTextAlignment(land ? .center : .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: land ? .center : .leading)
                        }
                        .padding(land ? 12 : 14)
                        .frame(maxWidth: .infinity, maxHeight: land ? .infinity : nil)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Label(String(localized: "You'll be asked for the camera and microphone. The mic opens only when you tap it.", bundle: .ui),
                      systemImage: "mic")
                    .font(.system(size: land ? 12 : 13))
                    .foregroundStyle(Color.sheetMuted)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, land ? 4 : 24)
                Button(buttonTitle, action: onContinue)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: land ? 240 : .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, land ? 18 : 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sheetGround.ignoresSafeArea())
        } }
    }
}

struct ConsentView: View {
    static let legalURL = URL(string: "https://www.aobasar.com/projects/kokobubu/legal/")!

    var onAgree: () -> Void
    @State private var agreed = false
    @State private var glow = false

    private var items: [(icon: String, color: Color, text: String)] {
        [("paperplane", .novaYellow, String(localized: "Frames and your voice go to the Koko server and the Meta Model API only when you ask. Koko's server doesn't keep them; Meta's terms apply.", bundle: .ui)),
         ("exclamationmark.triangle", .novaOrange, String(localized: "AI-generated guidance. Check before you press. It can be wrong; labels and manuals come first.", bundle: .ui)),
         ("nosign", .novaRed, String(localized: "Not for gas, electrical panels, vehicles or medication.", bundle: .ui)),
         ("person", .novaCyan, String(localized: "For ages 18 and up.", bundle: .ui))]
    }

    var body: some View {
        lightScreen { GeometryReader { geometry in
            let land = Orientation(geometry.size).landscape
            VStack(alignment: .leading, spacing: 12) {
                Text("Before you start").font(.system(size: 24, weight: .bold))
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items, id: \.icon) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.icon).foregroundStyle(item.color).frame(width: 20)
                            Text(item.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    HStack(spacing: 4) {
                        Text("Full text:")
                        Link(String(localized: "Privacy", bundle: .ui), destination: Self.legalURL)
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.sheetMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: land ? 20 : 10) {
                    Button { agreed.toggle() } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(agreed ? Color.novaYellow : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.novaGold, lineWidth: 2))
                                .overlay {
                                    if agreed { Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(.black) }
                                }
                                .frame(width: 28, height: 28)
                                .shadow(color: .novaYellow.opacity(agreed ? 0 : (glow ? 0.8 : 0.1)), radius: 8)
                            Text("I've read and agree (18+)")
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .accessibilityAddTraits(agreed ? .isSelected : [])
                    if !land { Spacer(minLength: 0) }
                    Button(String(localized: "Continue", bundle: .ui), action: onAgree)
                        .buttonStyle(PrimaryButtonStyle(enabled: agreed))
                        .frame(width: 130)
                        .disabled(!agreed)
                }
                .frame(maxWidth: .infinity, alignment: land ? .center : .leading)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, land ? 18 : 30)
            .frame(maxWidth: 640, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .background(Color.sheetGround.ignoresSafeArea())
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
            }
        } }
    }
}

/// The screens outside the camera are light: the phone's status bar and the text follow.
private func lightScreen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .environment(\.colorScheme, .light)
        .tint(.primary)
        .preferredColorScheme(.light)
}
