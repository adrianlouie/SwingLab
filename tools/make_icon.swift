// Generates the SwingLab app icon (1024×1024 PNG) with Core Graphics.
// Run: swift tools/make_icon.swift <output.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create bitmap context")
}

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

let fairway = color(0.05, 0.36, 0.22)
let fairwayDeep = color(0.02, 0.16, 0.10)
let lime = color(0.66, 0.91, 0.18)

// Background gradient.
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [fairway, fairwayDeep] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

let s = Double(size)

// Swing-plane line: a lime diagonal from the low-left ball up to the right.
ctx.setStrokeColor(lime)
ctx.setLineWidth(s * 0.035)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: s * 0.22, y: s * 0.22))
ctx.addLine(to: CGPoint(x: s * 0.80, y: s * 0.80))
ctx.strokePath()

// Dashed measurement arc suggesting an angle off the plane line.
ctx.setStrokeColor(color(1, 1, 1, 0.85))
ctx.setLineWidth(s * 0.016)
ctx.setLineDash(phase: 0, lengths: [s * 0.035, s * 0.030])
ctx.addArc(center: CGPoint(x: s * 0.22, y: s * 0.22), radius: s * 0.34,
           startAngle: 0, endAngle: .pi / 4, clockwise: false)
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// Horizontal ground reference through the ball.
ctx.setStrokeColor(color(1, 1, 1, 0.85))
ctx.setLineWidth(s * 0.016)
ctx.move(to: CGPoint(x: s * 0.22, y: s * 0.22))
ctx.addLine(to: CGPoint(x: s * 0.78, y: s * 0.22))
ctx.strokePath()

// The ball.
ctx.setFillColor(color(1, 1, 1))
let ballRadius = s * 0.062
ctx.fillEllipse(in: CGRect(x: s * 0.22 - ballRadius, y: s * 0.22 - ballRadius,
                           width: ballRadius * 2, height: ballRadius * 2))

// Lime accent dot at the top of the plane line.
ctx.setFillColor(lime)
let dot = s * 0.045
ctx.fillEllipse(in: CGRect(x: s * 0.80 - dot, y: s * 0.80 - dot,
                           width: dot * 2, height: dot * 2))

guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create image destination at \(outputPath)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }
print("Wrote \(outputPath)")
