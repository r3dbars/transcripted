#!/usr/bin/swift

import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "scripts/release/assets/dmg-background.png"
let outputURL = URL(fileURLWithPath: outputPath)

let canvasSize = NSSize(width: 960, height: 640)
let designScale: CGFloat = 0.5
let designCanvasSize = NSSize(width: canvasSize.width / designScale, height: canvasSize.height / designScale)
let titleColor = NSColor(hex: 0x231C16)
let subtitleColor = NSColor(hex: 0x5F5248)
let arrowColor = NSColor(hex: 0xD8C6B2)
let panelFillColor = NSColor.white.withAlphaComponent(0.32)
let panelStrokeColor = NSColor.white.withAlphaComponent(0.55)

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xff) / 255
        let green = CGFloat((hex >> 8) & 0xff) / 255
        let blue = CGFloat(hex & 0xff) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

func centeredAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping

    return [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style
    ]
}

func drawText(_ string: String, rect: NSRect, font: NSFont, color: NSColor) {
    let attributed = NSAttributedString(string: string, attributes: centeredAttributes(font: font, color: color))
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func drawGlow(rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

func drawRoundedPanel(rect: NSRect) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)

    let shadow = NSShadow()
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: 14)
    shadow.shadowColor = NSColor(hex: 0x7D6B5A, alpha: 0.14)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    panelFillColor.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    panelStrokeColor.setStroke()
    path.lineWidth = 4
    path.stroke()
}

func drawArrow() {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 760, y: 560))
    path.curve(
        to: NSPoint(x: 1020, y: 640),
        controlPoint1: NSPoint(x: 860, y: 520),
        controlPoint2: NSPoint(x: 1010, y: 540)
    )
    path.curve(
        to: NSPoint(x: 980, y: 970),
        controlPoint1: NSPoint(x: 1030, y: 760),
        controlPoint2: NSPoint(x: 900, y: 900)
    )
    path.curve(
        to: NSPoint(x: 1330, y: 980),
        controlPoint1: NSPoint(x: 1030, y: 1040),
        controlPoint2: NSPoint(x: 1200, y: 1040)
    )

    path.lineWidth = 14
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.setLineDash([18, 24], count: 2, phase: 0)
    arrowColor.setStroke()
    path.stroke()

    let tip = NSPoint(x: 1330, y: 980)
    let arrowHead = NSBezierPath()
    arrowHead.move(to: tip)
    arrowHead.line(to: NSPoint(x: 1270, y: 948))
    arrowHead.move(to: tip)
    arrowHead.line(to: NSPoint(x: 1292, y: 916))
    arrowHead.lineWidth = 14
    arrowHead.lineCapStyle = .round
    arrowHead.lineJoinStyle = .round
    arrowColor.setStroke()
    arrowHead.stroke()
}

let image = NSImage(size: canvasSize)
image.lockFocusFlipped(true)

let transform = NSAffineTransform()
transform.scale(by: designScale)
transform.concat()

let backgroundRect = NSRect(origin: .zero, size: designCanvasSize)
let backgroundGradient = NSGradient(colors: [
    NSColor(hex: 0xF4EBDD),
    NSColor(hex: 0xF7EFE3),
    NSColor(hex: 0xF2E6D7)
])
backgroundGradient?.draw(in: backgroundRect, angle: 90)

drawGlow(rect: NSRect(x: -140, y: 120, width: 760, height: 760), color: NSColor(hex: 0xF5A451, alpha: 0.10))
drawGlow(rect: NSRect(x: 1240, y: 780, width: 520, height: 320), color: NSColor(hex: 0xE7D5BF, alpha: 0.18))
drawGlow(rect: NSRect(x: 1360, y: 250, width: 420, height: 420), color: NSColor(hex: 0xF0E4D2, alpha: 0.45))

drawText(
    "Transcripted",
    rect: NSRect(x: 260, y: 84, width: 1400, height: 170),
    font: .systemFont(ofSize: 110, weight: .black),
    color: titleColor
)
drawText(
    "Drag Transcripted into Applications to install.",
    rect: NSRect(x: 300, y: 220, width: 1320, height: 60),
    font: .systemFont(ofSize: 34, weight: .medium),
    color: subtitleColor
)

drawRoundedPanel(rect: NSRect(x: 190, y: 370, width: 520, height: 520))
drawArrow()

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Failed to render DMG background.\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: outputURL)
    print("Wrote \(outputURL.path)")
} catch {
    fputs("Failed to write \(outputURL.path): \(error)\n", stderr)
    exit(1)
}
