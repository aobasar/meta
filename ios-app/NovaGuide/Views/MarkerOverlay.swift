import SwiftUI

/// Where to act, and then out of the way, so the control and its labels can be read: a ring finds the control for a
/// moment and four small corners stay around it. The motion passes once every few seconds, a dot marks the position to
/// turn to, and an edge chip shows when the control is off screen. A tap on the camera shows it all again.
struct MarkerOverlay: View {
    var marker: MarkerState
    var tint: Color = .novaYellow
    var motion: GuideStep.Motion? = nil
    var brightness: ((CGPoint) -> Double?)? = nil
    var card: CGRect = .zero
    var aims = true
    @State private var ringShown = false
    @State private var aim: CGVector?
    @State private var cornersShown = false

    var body: some View {
        GeometryReader { geometry in
            if marker.onScreen {
                ZStack {
                    if let label = marker.label {
                        Circle().stroke(tint, lineWidth: 3)
                            .frame(width: 15, height: 15)
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .opacity(cornersShown ? 1 : 0)
                            .position(label)
                    }
                    Circle()
                        .stroke(tint, style: StrokeStyle(lineWidth: 3.5, dash: marker.precise ? [] : [10, 8]))
                        .frame(width: ringRadius * 2, height: ringRadius * 2)
                        .shadow(color: tint.opacity(0.7), radius: 6)
                        .scaleEffect(ringShown ? 1 : 1.5)
                        .opacity(ringShown ? 1 : 0)
                        .position(marker.center)
                    CornerMarks(side: ringRadius * 2 + 22, tint: tint, precise: marker.precise)
                        .opacity(cornersShown ? 1 : 0)
                        .position(marker.center)
                    if let motion {
                        MotionCue(motion: motion, radius: ringRadius + 14, center: marker.center, room: geometry.size, brightness: brightness).position(marker.center)
                    }
                    if aims, let aim {
                        // Beside the target, on the side away from the edge, so it doesn't cover what it points at.
                        AimHint(direction: aim)
                            .position(x: min(max(marker.center.x - aim.dx * 110, 110), max(geometry.size.width - 110, 110)),
                                      y: min(max(marker.center.y - aim.dy * 96, 60), max(geometry.size.height - 60, 60)))
                    }
                }
                .onAppear { updateAim(in: geometry.size) }
                .onChange(of: marker) { _, _ in updateAim(in: geometry.size) }
                .onChange(of: card) { _, _ in updateAim(in: geometry.size) }
            } else {
                EdgeHint(direction: marker.direction, size: geometry.size)
            }
        }
        .allowsHitTesting(false)
        .task {
            withAnimation(.easeOut(duration: 0.35)) { ringShown = true }
            try? await Task.sleep(for: .seconds(Self.ringSeconds))
            withAnimation(.easeInOut(duration: 0.5)) {
                ringShown = false
                cornersShown = true
            }
        }
    }

    static let ringSeconds = 1.9

    private func updateAim(in size: CGSize) {
        let next = MarkerPlacement.aim(marker: marker.center, picture: size, card: card, aiming: aim != nil)
        if next != aim { aim = next }
    }

    private var ringRadius: CGFloat { min(max(marker.radius * 1.25, 26), 140) }
}

/// Four small corners that stay around the control without covering it.
private struct CornerMarks: View {
    var side: CGFloat
    var tint: Color
    var precise: Bool

    var body: some View {
        Canvas { context, size in
            let arm = size.width * 0.2, inset: CGFloat = 2
            let (a, b) = (inset, size.width - inset)
            var path = Path()
            for (x, y, dx, dy) in [(a, a, 1.0, 1.0), (b, a, -1.0, 1.0), (b, b, -1.0, -1.0), (a, b, 1.0, -1.0)] {
                path.move(to: CGPoint(x: x, y: y + dy * arm))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx * arm, y: y))
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: precise ? [] : [5, 5]))
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.7), radius: 2)
    }
}

/// How the hand moves the control: one pass around or out from it, then a pause, because it would hide the pointer.
private struct MotionCue: View {
    static let pauseSeconds = 3.6

    var motion: GuideStep.Motion
    var radius: CGFloat
    var center: CGPoint = .zero
    var room: CGSize = .zero
    var brightness: ((CGPoint) -> Double?)? = nil
    @State private var progress = 0.0
    @State private var opacity = 0.0
    @State private var touched = 0.0
    @State private var onDark = true

    /// A press, a swipe, a drag or a step with no named motion shows the hand. A turn keeps its arrow: one finger can't
    /// show turning a dial.
    private var showsHand: Bool { brightness != nil && (motion == .press || motion == .point || motion.swipe != nil) }
    private var flipX: Bool { center.x + HandCue.width * 0.72 > room.width }
    private var flipY: Bool { center.y + HandCue.height > room.height }

    var body: some View {
        Group {
            switch motion {
            case .turnClockwise, .turnCounterclockwise:
                TurningArc(radius: radius)
                    .rotationEffect(.degrees(-70 + progress * 180))
                    .scaleEffect(x: motion == .turnCounterclockwise ? -1 : 1)
            case .press where showsHand:
                ZStack {
                    Circle().stroke(onDark ? Color.white : Color.black, lineWidth: 3)
                        .frame(width: 44, height: 44)
                        .scaleEffect(0.4 + touched * 1.1)
                        .opacity(touched > 0 ? 1 - touched : 0)
                    HandCue(onDark: onDark, flipX: flipX, flipY: flipY)
                        .offset(x: (1 - progress) * (flipX ? -16 : 16), y: (1 - progress) * (flipY ? -24 : 24))
                }
            case .point:
                if showsHand { HandCue(onDark: onDark, flipX: flipX, flipY: flipY) }
            case .pull, .push, .press:
                // A pull comes toward the user: the ring grows. A push or a press goes away: it shrinks.
                Circle().stroke(Color.white, lineWidth: 3)
                    .frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(motion == .pull ? 0.7 + progress * 0.8 : 1.4 - progress * 0.7)
                    .shadow(color: .black.opacity(0.7), radius: 2)
            case .swipeLeft, .swipeRight, .swipeUp, .swipeDown, .dragLeft, .dragRight, .dragUp, .dragDown:
                let way = motion.swipe ?? CGVector(dx: 0, dy: -1)
                let length = SwipeTrail.length(from: center, way: way, room: room)
                ZStack {
                    if motion.holds {
                        Circle().stroke(onDark ? Color.white : Color.black, lineWidth: 3)
                            .frame(width: 44, height: 44)
                            .scaleEffect(0.4 + touched * 1.1)
                            .opacity(touched > 0 && progress == 0 ? 1 - touched / 2 : 0)
                    }
                    SwipeTrail(way: way, length: length, progress: progress, fingertip: !showsHand)
                    if showsHand {
                        HandCue(onDark: onDark, flipX: flipX, flipY: flipY)
                            .offset(x: way.dx * length * progress, y: way.dy * length * progress)
                    }
                }
            }
        }
        .opacity(opacity)
        .task {
            while !Task.isCancelled {
                progress = 0
                touched = 0
                // Read once for each pass, where the hand will be, so its color holds still while it moves.
                if showsHand, let light = brightness?(CGPoint(x: center.x + (flipX ? -28 : 28), y: center.y + (flipY ? -48 : 48))) {
                    onDark = PictureBrightness.isDark(light, was: onDark)
                }
                withAnimation(.easeIn(duration: 0.25)) { opacity = 1 }
                if motion == .press && showsHand {
                    withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
                    try? await Task.sleep(for: .seconds(0.7))
                    withAnimation(.easeOut(duration: 0.8)) { touched = 1 }
                    try? await Task.sleep(for: .seconds(0.9))
                } else if motion.holds {
                    // Pressed and held first: that is what makes it a drag and not a swipe.
                    withAnimation(.easeOut(duration: 0.5)) { touched = 1 }
                    try? await Task.sleep(for: .seconds(0.6))
                    withAnimation(.easeInOut(duration: 1.2)) { progress = 1 }
                    try? await Task.sleep(for: .seconds(1.2))
                } else {
                    withAnimation(.easeInOut(duration: 1.6)) { progress = 1 }
                    try? await Task.sleep(for: .seconds(1.6))
                }
                withAnimation(.easeOut(duration: 0.4)) { opacity = 0 }
                try? await Task.sleep(for: .seconds(Self.pauseSeconds))
            }
        }
    }
}

/// A fingertip leaving the marker the way the finger should go, drawing its line behind it, toward an arrowhead.
private struct SwipeTrail: View {
    var way: CGVector
    var length: CGFloat
    var progress: Double
    var fingertip = true

    /// Up to 120 pt, shorter where the picture ends sooner, with room left for the arrowhead.
    static func length(from center: CGPoint, way: CGVector, room: CGSize) -> CGFloat {
        let free = way.dx != 0 ? (way.dx < 0 ? center.x : room.width - center.x) : (way.dy < 0 ? center.y : room.height - center.y)
        return max(min(120, free - 34), 40)
    }

    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.85))
                .frame(width: max(length * progress, 1), height: 5)
                .offset(x: length * progress / 2)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.white)
                .offset(x: length + 10)
            if fingertip {
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.novaYellow, lineWidth: 3))
                    .frame(width: 26, height: 26)
                    .offset(x: length * progress)
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .rotationEffect(.radians(atan2(way.dy, way.dx)))
    }
}

/// The pointing hand, with its fingertip on the center of this view: white on a dark picture, black on a light one. It
/// turns away from the picture's edge so it stays whole.
private struct HandCue: View {
    static let height: CGFloat = 84
    static let width: CGFloat = height * HandShape.size.width / HandShape.size.height

    var onDark: Bool
    var flipX: Bool
    var flipY: Bool

    var body: some View {
        let color = onDark ? Color.white : Color.black
        ZStack {
            HandShape().fill(color.opacity(onDark ? 0.2 : 0.14))
            HandShape().stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            HandShape.Knuckles().stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
        .shadow(color: (onDark ? Color.black : Color.white).opacity(0.6), radius: 1.5)
        .frame(width: Self.width, height: Self.height)
        .offset(x: Self.width / 2 - Self.width * HandShape.tip.x, y: Self.height / 2 - Self.height * HandShape.tip.y)
        .scaleEffect(x: flipX ? -1 : 1, y: flipY ? -1 : 1, anchor: .center)
    }
}

/// A right hand pointing up, drawn for Kokobubu in a 110 by 136 box.
private struct HandShape: Shape {
    static let size = CGSize(width: 110, height: 136)
    static let tip = CGPoint(x: 32.0 / 110, y: 6.0 / 136)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        path.move(to: p(32, 6))
        path.addCurve(to: p(44, 16), control1: p(38, 6), control2: p(42, 10))
        path.addLine(to: p(54, 52))
        path.addCurve(to: p(67, 47), control1: p(56, 46), control2: p(62, 44))
        path.addCurve(to: p(73, 56), control1: p(70, 49), control2: p(72, 52))
        path.addCurve(to: p(86, 55), control1: p(76, 52), control2: p(82, 51))
        path.addCurve(to: p(90, 63), control1: p(88, 57), control2: p(89, 60))
        path.addCurve(to: p(99, 66), control1: p(93, 61), control2: p(97, 62))
        path.addCurve(to: p(99, 106), control1: p(102, 74), control2: p(102, 92))
        path.addLine(to: p(94, 128))
        path.addLine(to: p(52, 128))
        path.addCurve(to: p(26, 94), control1: p(46, 116), control2: p(36, 104))
        path.addLine(to: p(8, 74))
        path.addCurve(to: p(8, 58), control1: p(3, 69), control2: p(3, 61))
        path.addCurve(to: p(23, 63), control1: p(13, 55), control2: p(19, 58))
        path.addLine(to: p(34, 74))
        path.addLine(to: p(22, 20))
        path.addCurve(to: p(32, 6), control1: p(20, 12), control2: p(24, 6))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / Self.size.width, y: rect.height / Self.size.height))
    }

    struct Knuckles: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for (start, end) in [(CGPoint(x: 54, y: 52), CGPoint(x: 58, y: 70)), (CGPoint(x: 73, y: 56), CGPoint(x: 75, y: 72)),
                                 (CGPoint(x: 90, y: 63), CGPoint(x: 90, y: 76))] {
                path.move(to: start)
                path.addLine(to: end)
            }
            return path.applying(CGAffineTransform(scaleX: rect.width / size.width, y: rect.height / size.height))
        }

        private var size: CGSize { HandShape.size }
    }
}

private struct TurningArc: View {
    var radius: CGFloat

    var body: some View {
        ZStack {
            // A quarter circle, clockwise from 3 o'clock to 6 o'clock, with its arrowhead at the end.
            Circle().trim(from: 0, to: 0.25)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.white)
                .offset(y: radius)
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
    }
}

private struct EdgeHint: View {
    var direction: CGVector
    var size: CGSize

    var body: some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Where the direction leaves the screen, kept inside a margin.
        let scale = min(abs(direction.dx) > 0.001 ? (size.width / 2 - 70) / abs(direction.dx) : .infinity,
                        abs(direction.dy) > 0.001 ? (size.height / 2 - 60) / abs(direction.dy) : .infinity)
        let point = CGPoint(x: center.x + direction.dx * scale, y: center.y + direction.dy * scale)
        AimHint(direction: direction).position(point)
    }
}

/// Which way to move the phone: a yellow arrow and a few words.
private struct AimHint: View {
    var direction: CGVector

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.novaYellow)
                .rotationEffect(.radians(atan2(direction.dy, direction.dx) + .pi / 2))
            Chip(text: hint, systemImage: "iphone.gen3")
        }
    }

    private var hint: String {
        if abs(direction.dx) >= abs(direction.dy) {
            return direction.dx < 0 ? String(localized: "Turn the phone left", bundle: .ui) : String(localized: "Turn the phone right", bundle: .ui)
        }
        return direction.dy < 0 ? String(localized: "Tilt the phone up", bundle: .ui) : String(localized: "Tilt the phone down", bundle: .ui)
    }
}
