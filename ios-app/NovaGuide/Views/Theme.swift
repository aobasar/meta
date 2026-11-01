import SwiftUI

/// Nova's colors (the prototype's palette): near-black ground, signal yellow for the one thing to do next.
extension Color {
    /// "#RRGGBB"; nil for anything else.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }

    static let novaBlue = Color(red: 0.165, green: 0.471, blue: 0.831)  // #2A78D4
    static let novaGround = Color(red: 0.043, green: 0.043, blue: 0.047)  // #0B0B0C
    static let novaColumn = Color(red: 0.078, green: 0.078, blue: 0.086)  // #141416
    static let novaCard = Color(red: 0.11, green: 0.11, blue: 0.118)  // #1C1C1E
    static let novaRaised = Color(red: 0.173, green: 0.173, blue: 0.18)  // #2C2C2E
    static let novaLine = Color(red: 0.227, green: 0.227, blue: 0.235)  // #3A3A3C
    static let novaText2 = Color(red: 0.78, green: 0.78, blue: 0.8)  // #C7C7CC
    static let novaText3 = Color(red: 0.631, green: 0.631, blue: 0.651)  // #A1A1A6
    static let novaGreen = Color(red: 0.188, green: 0.82, blue: 0.345)  // #30D158
    static let novaRed = Color(red: 1, green: 0.271, blue: 0.227)  // #FF453A
    static let novaOrange = Color(red: 1, green: 0.624, blue: 0.039)  // #FF9F0A
    static let novaPurple = Color(red: 0.749, green: 0.353, blue: 0.949)  // #BF5AF2
    static let sheetGround = Color(red: 0.965, green: 0.97, blue: 0.975)  // the screens outside the camera
    static let novaBlueText = Color(red: 0.094, green: 0.373, blue: 0.647)  // #185FA5, readable on a light ground
    static let sheetMuted = Color(white: 0.32)  // secondary text on the light card
    static let novaCyan = Color(red: 0.392, green: 0.824, blue: 1)  // #64D2FF
}

/// The yellow call-to-action button used on every screen.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = .novaBlue
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.heavy))
            .foregroundStyle(enabled ? (fill == .novaBlue ? Color.white : Color.black) : Color(white: 0.56))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .background(enabled ? fill : Color.novaLine, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// An outlined secondary button.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 10)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.novaLine))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A round dark button for the camera's top bar.
struct RoundIconButton<Label: View>: View {
    var action: () -> Void
    var accessibility: Text
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 40, height: 40)
                .background(Color.novaCard.opacity(0.85), in: Circle())
        }
        .accessibilityLabel(accessibility)
    }
}

/// Four rounded corner brackets, in a 100×100 box like the prototype's SVG.
struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        for (corner, horizontal, vertical) in [(p(18, 18), 1.0, 1.0), (p(82, 18), -1.0, 1.0), (p(82, 82), -1.0, -1.0), (p(18, 82), 1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + vertical * 16 * s))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + vertical * 6 * s))
            path.addQuadCurve(to: CGPoint(x: corner.x + horizontal * 6 * s, y: corner.y), control: corner)
            path.addLine(to: CGPoint(x: corner.x + horizontal * 16 * s, y: corner.y))
        }
        return path
    }
}

/// The prototype's star: M50 26 C52 42 58 48 74 50 … in a 100×100 box.
struct FourPointStar: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(50, 26))
        path.addCurve(to: p(74, 50), control1: p(52, 42), control2: p(58, 48))
        path.addCurve(to: p(50, 74), control1: p(58, 52), control2: p(52, 58))
        path.addCurve(to: p(26, 50), control1: p(48, 58), control2: p(42, 52))
        path.addCurve(to: p(50, 26), control1: p(42, 48), control2: p(48, 42))
        path.closeSubpath()
        return path
    }
}
