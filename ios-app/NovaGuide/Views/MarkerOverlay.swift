import SwiftUI

/// Spotlight, pulsing ring and bouncing arrow on the control; for a dial, a dashed arrow to the target label and its
/// translation; an edge chip when the control is off screen.
struct MarkerOverlay: View {
    var marker: MarkerState
    var setTo: GuideStep.SetTo?
    var tint: Color = .novaYellow
    var motion: GuideStep.Motion? = nil
    /// Each step: the arrow bounces for 1.5 s and fades out; 0.5 s later the dial's label tag fades in.
    @State private var arrowShown = true
    @State private var tagShown = false

    var body: some View {
        GeometryReader { geometry in
            if marker.onScreen {
                ZStack {
                    Spotlight(center: marker.center, radius: ringRadius * 1.6)
                    if let label = marker.label {
                        DialArrow(from: marker.center, to: label, startInset: ringRadius).opacity(tagShown ? 1 : 0)
                        if let setTo {
                            LabelTag(label: setTo.label, meaning: setTo.meaning).opacity(tagShown ? 1 : 0)
                                .position(x: min(max(label.x, 130), geometry.size.width - 130), y: max(label.y - 34, 70))  // kept on screen
                        }
                    }
                    PulsingRing(radius: ringRadius, precise: marker.precise, tint: tint).position(marker.center)
                    if let motion {
                        MotionCue(motion: motion, radius: ringRadius).opacity(arrowShown ? 0 : 1).position(marker.center)
                    }
                    BouncingArrow().opacity(arrowShown ? 1 : 0).position(x: marker.center.x, y: marker.center.y - ringRadius - 34)
                }
            } else {
                EdgeHint(direction: marker.direction, size: geometry.size)
            }
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.3)) { arrowShown = false }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.easeIn(duration: 0.4)) { tagShown = true }
        }
    }

    private var ringRadius: CGFloat { min(max(marker.radius * 1.25, 26), 140) }
}

/// How the hand moves the control, drawn around the ring: a turning arc, or rings moving toward or away from the user.
private struct MotionCue: View {
    var motion: GuideStep.Motion
    var radius: CGFloat
    @State private var moving = false

    var body: some View {
        Group {
            switch motion {
            case .turnClockwise, .turnCounterclockwise:
                let counter = motion == .turnCounterclockwise
                TurningArc(radius: radius + 14)
                    .scaleEffect(x: counter ? -1 : 1)
                    .rotationEffect(.degrees(moving ? (counter ? -360 : 360) : 0))
                    .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: moving)
            case .pull, .push, .press:
                let outward = motion == .pull  // a pull comes toward the user: the rings grow
                ZStack {
                    ForEach(0..<2, id: \.self) { index in
                        Circle().stroke(Color.novaCyan, lineWidth: 3)
                            .frame(width: radius * 2, height: radius * 2)
                            .scaleEffect((moving == outward) ? 1.7 : 1)
                            .opacity((moving == outward) ? 0 : 0.9)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false).delay(Double(index) * 0.4), value: moving)
                    }
                }
            }
        }
        .onAppear { moving = true }
    }
}

private struct TurningArc: View {
    var radius: CGFloat

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.72)
                .stroke(Color.novaCyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
            // The arrowhead at the arc's end; the arc runs clockwise from 3 o'clock.
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.novaCyan)
                .rotationEffect(.degrees(0.72 * 360 + 90))
                .offset(x: radius * cos(0.72 * 2 * .pi), y: radius * sin(0.72 * 2 * .pi))
        }
    }
}

private struct Spotlight: View {
    var center: CGPoint
    var radius: CGFloat

    var body: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(path, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        }
    }
}

private struct PulsingRing: View {
    var radius: CGFloat
    var precise: Bool
    var tint: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(tint, style: StrokeStyle(lineWidth: 5, dash: precise ? [] : [10, 8]))
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(pulse ? 1.12 : 0.94)
            .shadow(color: tint.opacity(0.7), radius: 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

private struct BouncingArrow: View {
    @State private var up = false

    var body: some View {
        Image(systemName: "arrowshape.down.fill")
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(Color.novaYellow)
            .shadow(color: .black.opacity(0.6), radius: 4)
            .offset(y: up ? -10 : 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

private struct DialArrow: View {
    var from: CGPoint
    var to: CGPoint
    var startInset: CGFloat

    var body: some View {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 1)
        let start = CGPoint(x: from.x + dx / length * startInset, y: from.y + dy / length * startInset)
        let angle = atan2(dy, dx)
        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: to)
            }
            .stroke(Color.novaPurple, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 8]))
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.novaPurple)
                .rotationEffect(.radians(angle))
                .position(to)
        }
    }
}

private struct LabelTag: View {
    var label: String
    var meaning: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.semibold)
            if !meaning.isEmpty {
                Image(systemName: "arrow.right")
                Text(meaning)
            }
        }
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.novaPurple, in: Capsule())
        .foregroundStyle(.white)
        .fixedSize()
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
