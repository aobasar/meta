// Draws the Nova Guide app icon: a camera lens inside a glowing yellow ring, a sparkle on the ring, and viewfinder
// corners, 1024x1024 PNG. CoreGraphics only, no fonts or images, so the icon is entirely Nova's own. The maintainer's
// mockup was a visual reference only.
// Usage: swift ios-app/scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let center = CGPoint(x: size / 2, y: size / 2)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}

let yellow = color(1, 0.80, 0.10)
let glowYellow = color(1, 0.76, 0.05, 0.75)

let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func circle(_ radius: CGFloat, at point: CGPoint = center) -> CGRect {
    CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
}

func radial(_ colors: [CGColor], _ locations: [CGFloat], from inner: CGPoint = center, to outer: CGPoint = center,
            radius: CGFloat, clip: CGRect? = nil) {
    context.saveGState()
    if let clip {
        context.addEllipse(in: clip)
        context.clip()
    }
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    context.drawRadialGradient(gradient, startCenter: inner, startRadius: 0, endCenter: outer, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    context.restoreGState()
}

func glowStroke(_ path: CGPath, width: CGFloat, blurs: [(CGFloat, CGFloat)]) {
    for (blur, alpha) in blurs {
        context.saveGState()
        context.setShadow(offset: .zero, blur: blur, color: color(1, 0.76, 0.05, alpha))
        context.addPath(path)
        context.setStrokeColor(yellow)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.strokePath()
        context.restoreGState()
    }
}

// Background: near black, a little warmer around the lens.
radial([color(0.16, 0.12, 0.03), color(0.03, 0.03, 0.03)], [0, 1], radius: size * 0.62)

// Viewfinder corners.
let inset: CGFloat = 92, arm: CGFloat = 150, corner: CGFloat = 40
let corners = CGMutablePath()
for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (size - inset, inset, -1.0, 1.0),
                       (inset, size - inset, 1.0, -1.0), (size - inset, size - inset, -1.0, -1.0)] {
    corners.move(to: CGPoint(x: x, y: y + dy * arm))
    corners.addLine(to: CGPoint(x: x, y: y + dy * corner))
    corners.addQuadCurve(to: CGPoint(x: x + dx * corner, y: y), control: CGPoint(x: x, y: y))
    corners.addLine(to: CGPoint(x: x + dx * arm, y: y))
}
glowStroke(corners, width: 30, blurs: [(30, 0.45), (8, 0.6)])

// The ring: the marker Nova draws around a control.
let ringRadius: CGFloat = 338
glowStroke(CGPath(ellipseIn: circle(ringRadius), transform: nil), width: 22, blurs: [(70, 0.7), (26, 0.8), (6, 0.9)])

// The lens: a metal rim, dark barrels, then glass with warm and cool reflections.
radial([color(0.42, 0.42, 0.44), color(0.16, 0.16, 0.17), color(0.30, 0.30, 0.31), color(0.07, 0.07, 0.08)],
       [0, 0.55, 0.8, 1], from: CGPoint(x: center.x - 80, y: center.y + 110), radius: 300, clip: circle(292))
for (radius, shade) in [(262.0, 0.05), (236.0, 0.11), (214.0, 0.03), (190.0, 0.09), (168.0, 0.02)] as [(CGFloat, CGFloat)] {
    context.setFillColor(color(shade, shade, shade + 0.01))
    context.fillEllipse(in: circle(radius))
    context.setStrokeColor(color(0.32, 0.32, 0.34, 0.6))
    context.setLineWidth(2)
    context.strokeEllipse(in: circle(radius))
}
radial([color(0.20, 0.16, 0.36), color(0.05, 0.05, 0.12), color(0.01, 0.01, 0.02)], [0, 0.6, 1],
       radius: 150, clip: circle(150))
radial([color(0.36, 0.38, 0.85, 0.55), color(0.36, 0.38, 0.85, 0)], [0, 1],
       from: CGPoint(x: center.x - 40, y: center.y - 30), to: CGPoint(x: center.x - 40, y: center.y - 30), radius: 95,
       clip: circle(150))
radial([color(1, 0.72, 0.25, 0.85), color(1, 0.55, 0.05, 0)], [0, 1],
       from: CGPoint(x: center.x - 70, y: center.y + 70), to: CGPoint(x: center.x - 70, y: center.y + 70), radius: 85,
       clip: circle(150))
radial([color(1, 0.86, 0.45), color(1, 0.62, 0.08, 0.9), color(0.5, 0.25, 0, 0)], [0, 0.45, 1], radius: 44)
context.setFillColor(color(1, 0.95, 0.75))
context.fillEllipse(in: circle(9, at: CGPoint(x: center.x - 12, y: center.y + 14)))
radial([color(1, 0.8, 0.4, 0.7), color(1, 0.6, 0.1, 0)], [0, 1],
       from: CGPoint(x: center.x + 40, y: center.y - 40), to: CGPoint(x: center.x + 40, y: center.y - 40), radius: 30)

// The sparkle on the ring, upper right.
let sparkle = CGPoint(x: center.x + ringRadius * cos(.pi / 4), y: center.y + ringRadius * sin(.pi / 4))
radial([color(1, 1, 0.9, 0.95), color(1, 0.85, 0.3, 0.5), color(1, 0.75, 0.1, 0)], [0, 0.3, 1],
       from: sparkle, to: sparkle, radius: 80)
let star = CGMutablePath()
let long: CGFloat = 112, waist: CGFloat = 2
for index in 0..<4 {
    let angle = CGFloat(index) * .pi / 2
    let tip = CGPoint(x: sparkle.x + cos(angle) * long, y: sparkle.y + sin(angle) * long)
    let side = CGPoint(x: sparkle.x + cos(angle + .pi / 4) * waist, y: sparkle.y + sin(angle + .pi / 4) * waist)
    if index == 0 { star.move(to: tip) } else { star.addLine(to: tip) }
    star.addQuadCurve(to: CGPoint(x: sparkle.x + cos(angle + .pi / 2) * long, y: sparkle.y + sin(angle + .pi / 2) * long),
                      control: side)
}
star.closeSubpath()
context.saveGState()
context.setShadow(offset: .zero, blur: 24, color: glowYellow)
context.addPath(star)
context.setFillColor(color(1, 0.97, 0.82))
context.fillPath()
context.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try! NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: output)
