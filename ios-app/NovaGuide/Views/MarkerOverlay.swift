import SwiftUI

/// Where to act, and then out of the way, so the control and its labels can be read: a ring finds the control for a
/// moment and four small corners stay around it. The motion passes once every few seconds, a dot marks the position to
/// turn to, and an edge chip shows when the control is off screen. A tap on the camera shows it all again.
struct MarkerOverlay: View {
    var marker: MarkerState
    var tint: Color = .novaYellow
    var motion: GuideStep.Motion? = nil
    @State private var ringShown = false
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
                        MotionCue(motion: motion, radius: ringRadius + 14, center: marker.center, room: geometry.size).position(marker.center)
                    }
                }
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
    @State private var progress = 0.0
    @State private var opacity = 0.0

    var body: some View {
        Group {
            switch motion {
            case .turnClockwise, .turnCounterclockwise:
                TurningArc(radius: radius)
                    .rotationEffect(.degrees(-70 + progress * 180))
                    .scaleEffect(x: motion == .turnCounterclockwise ? -1 : 1)
            case .pull, .push, .press:
                // A pull comes toward the user: the ring grows. A push or a press goes away: it shrinks.
                Circle().stroke(Color.white, lineWidth: 3)
                    .frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(motion == .pull ? 0.7 + progress * 0.8 : 1.4 - progress * 0.7)
                    .shadow(color: .black.opacity(0.7), radius: 2)
            case .swipeLeft, .swipeRight, .swipeUp, .swipeDown:
                let way = motion.swipe ?? CGVector(dx: 0, dy: -1)
                SwipeTrail(way: way, length: SwipeTrail.length(from: center, way: way, room: room), progress: progress)
            }
        }
        .opacity(opacity)
        .task {
            while !Task.isCancelled {
                progress = 0
                withAnimation(.easeIn(duration: 0.25)) { opacity = 1 }
                withAnimation(.easeInOut(duration: 1.6)) { progress = 1 }
                try? await Task.sleep(for: .seconds(1.6))
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
            Circle().fill(Color.white)
                .overlay(Circle().stroke(Color.novaYellow, lineWidth: 3))
                .frame(width: 26, height: 26)
                .offset(x: length * progress)
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .rotationEffect(.radians(atan2(way.dy, way.dx)))
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
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.novaYellow)
                .rotationEffect(.radians(atan2(direction.dy, direction.dx) + .pi / 2))
            Chip(text: hint, systemImage: "iphone.gen3")
        }
        .position(point)
    }

    private var hint: String {
        if abs(direction.dx) >= abs(direction.dy) {
            return direction.dx < 0 ? String(localized: "Turn the phone left", bundle: .ui) : String(localized: "Turn the phone right", bundle: .ui)
        }
        return direction.dy < 0 ? String(localized: "Tilt the phone up", bundle: .ui) : String(localized: "Tilt the phone down", bundle: .ui)
    }
}
