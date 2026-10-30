import SwiftUI

/// Kokobubu's mascot, the app icon drawn as shapes (in the icon's 1024×1024 box) so its parts can move.
/// Its mood says what the app is doing. Reduce Motion keeps it still: it holds the pose, without hops or flashes.
struct KokobubuMascot: View {
    enum Mood: Equatable {
        case idle, listening
        /// Taking the photo: the eye closes like a shutter, then looks around while the answer comes.
        case looking
        /// Looking at the marker; the sign is the side it is on.
        case lean(CGFloat)
        case yes, no
    }

    var size: CGFloat
    var mood: Mood = .idle
    /// A small hop now and then while idle; on the Home screen it stays calm.
    var hops = false
    /// Over the camera: a yellow body with a dark outline, which reads on dark and light scenes alike.
    var onCamera = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var glowing = false
    @State private var blinking = false
    @State private var glance: CGFloat = 0
    @State private var eyeScale: CGFloat = 1
    @State private var smileScale: CGFloat = 1
    @State private var tilt: Double = 0
    @State private var hop: CGFloat = 0
    @State private var flash = false

    private static let ink = Color(red: 0.082, green: 0.094, blue: 0.11)  // #15181C

    var body: some View {
        let unit = size / 1024
        let body = onCamera ? Color.novaYellow : Self.ink
        let face = onCamera ? Self.ink : Color.novaYellow
        let outline = onCamera ? Self.ink : Color.clear
        ZStack {
            Circle().fill(onCamera ? Color.white : Color.novaYellow)
                .frame(width: 128 * unit, height: 128 * unit)
                .scaleEffect(glowing ? 1.25 : 0.8)
                .opacity(glowing ? 0.65 : 0.1)
                .position(x: 514 * unit, y: 68 * unit)
            Rectangle().fill(body)
                .overlay(Rectangle().stroke(outline, lineWidth: 2))
                .frame(width: 25 * unit, height: 110 * unit)
                .position(x: 514 * unit, y: 140 * unit)
            Circle().fill(body)
                .overlay(Circle().stroke(outline, lineWidth: 2))
                .frame(width: 64 * unit, height: 64 * unit)
                .position(x: 514 * unit, y: 68 * unit)
            Circle().fill(body)
                .overlay(Circle().stroke(outline, lineWidth: 3))
                .frame(width: 806 * unit, height: 806 * unit)
                .position(x: 514 * unit, y: 565 * unit)
            ZStack {
                Circle().fill(face)
                    .frame(width: 296 * unit, height: 296 * unit)
                Circle().fill(body)
                    .frame(width: 174 * unit, height: 174 * unit)
                    .offset(x: glance * unit)
            }
            .scaleEffect(x: eyeScale, y: eyeScale * (blinking ? 0.08 : 1))
            .position(x: 514 * unit, y: 498 * unit)
            MascotSmile().fill(face)
                .scaleEffect(x: smileScale, y: smileScale, anchor: UnitPoint(x: 0.5, y: 0.74))
            Circle().fill(Color.white)
                .frame(width: size * 1.5, height: size * 1.5)
                .scaleEffect(flash ? 1 : 0.2)
                .opacity(flash ? 0.9 : 0)
                .position(x: 514 * unit, y: 498 * unit)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(onCamera ? 0.35 : 0), radius: 5, y: 2)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .offset(y: hop)
        .scaleEffect(settled ? 1 : 0.86)
        .opacity(settled ? 1 : 0)
        .accessibilityHidden(true)
        .task(id: mood) { await live() }
    }

    private func live() async {
        pose()
        guard !reduceMotion else {
            settled = true
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { settled = true }
        glowing = false
        withAnimation(.easeInOut(duration: mood == .idle ? 1.4 : 0.5).repeatForever(autoreverses: true)) { glowing = true }
        switch mood {
        case .idle: await idle()
        case .listening: await hopping(every: 1.1)
        case .looking: await looking()
        case .yes: await jump()
        case .lean, .no: break
        }
    }

    /// The pose each mood holds, also with Reduce Motion on.
    private func pose() {
        var look: CGFloat = 0, eye: CGFloat = 1, smile: CGFloat = 1, lean: Double = 0
        switch mood {
        case .idle, .looking: break
        case .listening: eye = 1.12
        case .lean(let side):
            lean = side * 12
            look = side * 30
        case .yes: smile = 1.25
        case .no:
            lean = -13
            eye = 0.82
            smile = 0.5
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            glance = look
            eyeScale = eye
            smileScale = smile
            tilt = lean
        }
    }

    private func idle() async {
        var round = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            await blink()
            round += 1
            if hops && round % 2 == 0 {
                await hopOnce(height: 8)
            } else if round % 3 == 0 {  // now and then a look to one side, then back
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.easeInOut(duration: 0.3)) { glance = round % 6 == 0 ? -26 : 26 }
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeInOut(duration: 0.3)) { glance = 0 }
            }
        }
    }

    private func hopping(every seconds: Double) async {
        while !Task.isCancelled {
            await hopOnce(height: 8)
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func looking() async {
        await shutter()
        var side: CGFloat = 1
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.7)) { glance = side * 30 }
            try? await Task.sleep(for: .seconds(0.8))
            side = -side
        }
    }

    private func jump() async {
        await hopOnce(height: 22)
        withAnimation(.easeInOut(duration: 0.4)) { smileScale = 1 }
    }

    private func blink() async {
        withAnimation(.easeIn(duration: 0.08)) { blinking = true }
        try? await Task.sleep(for: .seconds(0.1))
        withAnimation(.easeOut(duration: 0.12)) { blinking = false }
    }

    private func shutter() async {
        withAnimation(.easeIn(duration: 0.1)) { blinking = true }
        try? await Task.sleep(for: .seconds(0.12))
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        try? await Task.sleep(for: .seconds(0.08))
        withAnimation(.easeOut(duration: 0.3)) {
            flash = false
            blinking = false
        }
        try? await Task.sleep(for: .seconds(0.3))
    }

    private func hopOnce(height: CGFloat) async {
        withAnimation(.easeOut(duration: 0.16)) { hop = -height }
        try? await Task.sleep(for: .seconds(0.16))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { hop = 0 }
        try? await Task.sleep(for: .seconds(0.25))
    }
}

/// The icon's smile: a crescent in the 1024×1024 box.
private struct MascotSmile: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 1024
        var path = Path()
        path.move(to: CGPoint(x: 420 * s, y: 727 * s))
        path.addQuadCurve(to: CGPoint(x: 609 * s, y: 727 * s), control: CGPoint(x: 514 * s, y: 777 * s))
        path.addQuadCurve(to: CGPoint(x: 420 * s, y: 727 * s), control: CGPoint(x: 514 * s, y: 857 * s))
        path.closeSubpath()
        return path
    }
}

/// The mascot on the camera screen. It stands on the card with its whole face showing, comes to the middle while looking
/// at the photo, and steps away once a step is on screen, so the marker and the control stay clear.
struct CameraMascot: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    var card: CGRect
    var bounds: CGSize
    @State private var away = false

    private static let size: CGFloat = 76

    private var mood: KokobubuMascot.Mood? {
        if model.correcting == .moving { return nil }
        switch model.listening {
        case .listening, .transcribing: return .listening
        case .answering: return .looking
        case .idle: break
        }
        switch model.phase {
        case .thinking:
            return .looking
        case .guiding:
            if model.reassessing { return .looking }
            switch model.feedback {
            case .checking: return .looking
            case .correct: return .yes
            case .notDone, .unsure, .error: return .no
            case nil:
                let target = ar.marker?.center.x ?? bounds.width / 2
                return .lean(target < spot.x ? -1 : 1)
            }
        case .finished:
            return model.unsolved ? .no : .yes
        default:
            return .idle
        }
    }

    private var isCentered: Bool {
        model.phase == .thinking || model.reassessing || card == .zero
    }

    private var spot: CGPoint {
        if isCentered { return CGPoint(x: bounds.width / 2, y: bounds.height * 0.28) }
        let half = Self.size / 2
        return CGPoint(x: min(card.maxX - half - 18, bounds.width - half - 6), y: card.minY - Self.size * 0.42)
    }

    /// Only a step that just appeared sends the mascot away; a tap on the camera does not bring it back.
    private var stepping: Bool {
        guard case .lean = mood else { return false }
        return true
    }

    var body: some View {
        KokobubuMascot(size: Self.size, mood: mood ?? .idle, hops: true, onCamera: true)
            .position(spot)
            .opacity(mood == nil || (stepping && away) ? 0 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: spot)
            .animation(.easeInOut(duration: 0.25), value: away)
            .frame(width: bounds.width, height: bounds.height)
            .allowsHitTesting(false)
            .task(id: "\(model.stepIndex)-\(stepping)") {
                away = false
                guard stepping else { return }
                try? await Task.sleep(for: .seconds(2.6))
                if !Task.isCancelled { away = true }
            }
    }
}

/// Where the card is, so the mascot can sit behind it.
struct CardFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
