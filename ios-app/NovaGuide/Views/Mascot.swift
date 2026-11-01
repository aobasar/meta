import SwiftUI

/// Kokobubu's mascot, drawn as shapes (in a 100×100 box) so its parts can move: a head with headphones, a visor, one big eye.
/// Its mood says what the app is doing. Reduce Motion keeps it still: it holds the pose, without hops or scans.
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
    /// Where the phone is moving, from -1 to 1 on each axis (y down): the eye looks that way.
    var look = CGPoint.zero

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
    @State private var scanDown = false

    private static let shell = Color(red: 0.957, green: 0.965, blue: 0.984)  // #F4F6FB
    private static let trim = Color(red: 0.216, green: 0.541, blue: 0.867)  // #378ADD
    private static let visor = Color(red: 0.71, green: 0.831, blue: 0.957)  // #B5D4F4
    private static let ink = Color(red: 0.047, green: 0.267, blue: 0.486)  // #0C447C
    private static let mouth = Color(red: 0.847, green: 0.353, blue: 0.188)  // #D85A30

    var body: some View {
        let unit = size / 100
        let small = size < 60  // at the card's size a mouth can't be seen, and lines need more weight
        let pupilRoom: CGFloat = 4
        ZStack {
            Circle().fill(Self.shell)
                .overlay(Circle().stroke(Self.trim, lineWidth: (small ? 4 : 2) * unit))
                .frame(width: 80 * unit, height: 80 * unit)
                .position(x: 50 * unit, y: 52 * unit)
            ForEach([8.5, 91.5], id: \.self) { x in
                RoundedRectangle(cornerRadius: 5.5 * unit, style: .continuous)
                    .fill(glowing && mood == .listening ? Self.visor : Self.trim)
                    .frame(width: 11 * unit, height: 24 * unit)
                    .position(x: x * unit, y: 54 * unit)
            }
            ZStack {
                Self.visor
                Self.trim.frame(height: 2.5 * unit)
                    .offset(y: (scanDown ? 13 : -13) * unit)
                    .opacity(mood == .looking && !reduceMotion ? 1 : 0)
                Color.white.opacity(flash ? 0.9 : 0)
            }
            .frame(width: 60 * unit, height: 42 * unit)
            .clipShape(RoundedRectangle(cornerRadius: 17 * unit, style: .continuous))
            .position(x: 50 * unit, y: 53 * unit)
            if mood == .yes {
                MascotArc(from: CGPoint(x: 29, y: 53), control: CGPoint(x: 39, y: 41), to: CGPoint(x: 49, y: 53))
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: (small ? 5 : 3.5) * unit, lineCap: .round))
            } else {
                ZStack {
                    Circle().fill(Color.white).frame(width: 20 * unit, height: 20 * unit)
                    Circle().fill(Self.ink)
                        .frame(width: 12 * unit, height: 12 * unit)
                        .offset(x: max(-pupilRoom, min(pupilRoom, glance + look.x * 3.3)) * unit, y: look.y * 3.3 * unit)
                        .animation(.easeOut(duration: 0.2), value: look)
                }
                .scaleEffect(x: eyeScale, y: eyeScale * (blinking ? 0.08 : 1))
                .position(x: 39 * unit, y: 51 * unit)
            }
            MascotArc(from: CGPoint(x: 57, y: 50), control: CGPoint(x: 63, y: 43), to: CGPoint(x: 69, y: 50))
                .stroke(Self.ink, style: StrokeStyle(lineWidth: (small ? 5 : 3.5) * unit, lineCap: .round))
            if !small {
                MascotSmile().fill(Self.mouth)
                    .scaleEffect(x: smileScale, y: smileScale, anchor: UnitPoint(x: 0.61, y: 0.62))
            }
        }
        .frame(width: size, height: size)
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
        scanDown = false
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { glowing = true }
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
            look = side * 3
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
                await hopOnce(height: size * 0.12)
            } else if round % 3 == 0 {  // now and then a look to one side, then back
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.easeInOut(duration: 0.3)) { glance = round % 6 == 0 ? -2.6 : 2.6 }
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeInOut(duration: 0.3)) { glance = 0 }
            }
        }
    }

    private func hopping(every seconds: Double) async {
        while !Task.isCancelled {
            await hopOnce(height: size * 0.12)
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func looking() async {
        await shutter()
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { scanDown = true }
        var side: CGFloat = 1
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.7)) { glance = side * 3 }
            try? await Task.sleep(for: .seconds(0.8))
            side = -side
        }
    }

    private func jump() async {
        await hopOnce(height: size * 0.3)
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

/// The smile, in the 100×100 box.
private struct MascotSmile: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        var path = Path()
        path.move(to: CGPoint(x: 54 * s, y: 60 * s))
        path.addQuadCurve(to: CGPoint(x: 68 * s, y: 57 * s), control: CGPoint(x: 63 * s, y: 58 * s))
        path.addQuadCurve(to: CGPoint(x: 59 * s, y: 68 * s), control: CGPoint(x: 67 * s, y: 69 * s))
        path.addQuadCurve(to: CGPoint(x: 54 * s, y: 60 * s), control: CGPoint(x: 55 * s, y: 66 * s))
        path.closeSubpath()
        return path
    }
}

/// A closed eye: one curved line in the 100×100 box.
private struct MascotArc: Shape {
    var from: CGPoint, control: CGPoint, to: CGPoint

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        var path = Path()
        path.move(to: CGPoint(x: from.x * s, y: from.y * s))
        path.addQuadCurve(to: CGPoint(x: to.x * s, y: to.y * s), control: CGPoint(x: control.x * s, y: control.y * s))
        return path
    }
}

/// The mascot inside the card, so it never covers the camera or reads as something to tap.
/// Its mood says what the app is doing.
struct CardMascot: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var ar: ARGuideController
    @EnvironmentObject private var settings: GuideSettings

    static let size: CGFloat = 34

    private var mood: KokobubuMascot.Mood {
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
            case .confirmDial: return .looking  // a question, not a failure
            case nil:
                guard let target = ar.marker?.center.x else { return .idle }
                return .lean(target < ar.arView.bounds.midX ? -1 : 1)
            }
        case .finished:
            return model.unsolved ? .no : .yes
        default:
            return .idle
        }
    }

    var body: some View {
        if settings.showMascot {
            Watching(gaze: ar.gaze, mood: mood)
        }
    }

    /// Its own view, so only the mascot redraws while the phone moves.
    private struct Watching: View {
        @ObservedObject var gaze: CameraGaze
        var mood: KokobubuMascot.Mood
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            KokobubuMascot(size: CardMascot.size, mood: mood, hops: true, look: reduceMotion ? .zero : gaze.look)
        }
    }
}

extension View {
    /// Keeps a card's top line clear of the mascot in the corner.
    func clearsMascot() -> some View { modifier(MascotClearance()) }
}

private struct MascotClearance: ViewModifier {
    @EnvironmentObject private var settings: GuideSettings

    func body(content: Content) -> some View {
        content.padding(.trailing, settings.showMascot ? CardMascot.size + 6 : 0)
    }
}
