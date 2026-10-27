// Draws the Nova Guide app icon: a glowing four-pointed star inside viewfinder corners, 1024x1024 PNG.
// CoreGraphics only, no fonts or images, so the icon is entirely Nova's own.
// Usage: swift ios-app/scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let center = CGPoint(x: size / 2, y: size / 2)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}

let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Background: near black, a touch warmer in the middle.
let background = CGGradient(colorsSpace: space, colors: [color(0.13, 0.12, 0.10), color(0.04, 0.04, 0.04)] as CFArray,
                            locations: [0, 1])!
context.drawRadialGradient(background, startCenter: center, startRadius: 0, endCenter: center, endRadius: size * 0.72,
                           options: [.drawsAfterEndLocation])

// Viewfinder corners: rounded, with a soft yellow glow.
let inset: CGFloat = 182, arm: CGFloat = 190, corner: CGFloat = 46, line: CGFloat = 20
let corners = CGMutablePath()
for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (size - inset, inset, -1.0, 1.0),
                       (inset, size - inset, 1.0, -1.0), (size - inset, size - inset, -1.0, -1.0)] {
    corners.move(to: CGPoint(x: x, y: y + dy * arm))
    corners.addLine(to: CGPoint(x: x, y: y + dy * corner))
    corners.addQuadCurve(to: CGPoint(x: x + dx * corner, y: y), control: CGPoint(x: x, y: y))
    corners.addLine(to: CGPoint(x: x + dx * arm, y: y))
}
for (blur, alpha) in [(CGFloat(40), CGFloat(0.55)), (14, 0.7)] {
    context.saveGState()
    context.setShadow(offset: .zero, blur: blur, color: color(1, 0.78, 0.05, alpha))
    context.addPath(corners)
    context.setStrokeColor(color(1, 0.80, 0.10))
    context.setLineWidth(line)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
}

// The star: concave sides, long slender points, a light center fading to deep yellow.
let radius: CGFloat = 250, waist: CGFloat = 70
let star = CGMutablePath()
for index in 0..<4 {
    let angle = CGFloat(index) * .pi / 2 + .pi / 2
    let next = angle + .pi / 2
    let tip = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    let nextTip = CGPoint(x: center.x + cos(next) * radius, y: center.y + sin(next) * radius)
    let control = CGPoint(x: center.x + cos(angle + .pi / 4) * waist, y: center.y + sin(angle + .pi / 4) * waist)
    if index == 0 { star.move(to: tip) }
    star.addCurve(to: nextTip,
                  control1: CGPoint(x: tip.x + (control.x - tip.x) * 0.7, y: tip.y + (control.y - tip.y) * 0.7),
                  control2: CGPoint(x: nextTip.x + (control.x - nextTip.x) * 0.7, y: nextTip.y + (control.y - nextTip.y) * 0.7))
}
star.closeSubpath()
for (blur, alpha) in [(CGFloat(90), CGFloat(0.55)), (30, 0.6)] {
    context.saveGState()
    context.setShadow(offset: .zero, blur: blur, color: color(1, 0.76, 0.05, alpha))
    context.addPath(star)
    context.setFillColor(color(1, 0.80, 0.10))
    context.fillPath()
    context.restoreGState()
}
context.saveGState()
context.addPath(star)
context.clip()
let fill = CGGradient(colorsSpace: space, colors: [color(1, 0.96, 0.55), color(1, 0.85, 0.20), color(0.98, 0.74, 0.02)] as CFArray,
                      locations: [0, 0.35, 1])!
context.drawRadialGradient(fill, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsAfterEndLocation])
context.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try! NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: output)
