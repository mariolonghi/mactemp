// Generates packaging/AppIcon.icns — a friendly little thermometer.
//
//   xcrun swift packaging/make_icon.swift
//
// Draws the 1024px master with AppKit, then shells out to sips + iconutil for
// the iconset. Re-run only when changing the design; the .icns is committed.

import AppKit

let canvas: CGFloat = 1024

// Apple's icon grid: content in an ~824px rounded square, centered.
let inset: CGFloat = 100
let cornerRadius: CGFloat = 185

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Background: warm rounded square with a soft vertical gradient.
let plate = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: cornerRadius, yRadius: cornerRadius)
NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.44, blue: 0.30, alpha: 1),   // bottom: hot coral
    NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.38, alpha: 1),   // top: peach
])!.draw(in: plate, angle: 90)

// Soft sheen fading down from the top for a hint of gloss.
let sheen = NSBezierPath(
    roundedRect: NSRect(x: inset + 40, y: canvas / 2, width: canvas - 2 * inset - 80, height: canvas / 2 - inset - 40),
    xRadius: cornerRadius * 0.7, yRadius: cornerRadius * 0.7)
NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.02),
    NSColor(calibratedWhite: 1, alpha: 0.16),
])!.draw(in: sheen, angle: 90)

// Thermometer geometry (centered, bulb toward the bottom).
let cx = canvas / 2
let bulbCenter = NSPoint(x: cx, y: 330)
let bulbRadius: CGFloat = 118
let stemWidth: CGFloat = 132
let stemTop: CGFloat = 800

// White body: stem capsule + bulb ring, drawn as one silhouette.
let body = NSBezierPath()
body.append(NSBezierPath(
    roundedRect: NSRect(x: cx - stemWidth / 2, y: bulbCenter.y,
                        width: stemWidth, height: stemTop - bulbCenter.y),
    xRadius: stemWidth / 2, yRadius: stemWidth / 2))
body.append(NSBezierPath(ovalIn: NSRect(x: bulbCenter.x - bulbRadius, y: bulbCenter.y - bulbRadius,
                                        width: 2 * bulbRadius, height: 2 * bulbRadius)))
NSColor(calibratedRed: 1, green: 0.97, blue: 0.94, alpha: 1).setFill()
body.fill()

// Mercury: red bulb + column rising most of the stem.
let mercury = NSColor(calibratedRed: 0.88, green: 0.21, blue: 0.17, alpha: 1)
mercury.setFill()
let innerBulb: CGFloat = 88
NSBezierPath(ovalIn: NSRect(x: bulbCenter.x - innerBulb, y: bulbCenter.y - innerBulb,
                            width: 2 * innerBulb, height: 2 * innerBulb)).fill()
let columnWidth: CGFloat = 64
NSBezierPath(
    roundedRect: NSRect(x: cx - columnWidth / 2, y: bulbCenter.y,
                        width: columnWidth, height: 700 - bulbCenter.y),
    xRadius: columnWidth / 2, yRadius: columnWidth / 2).fill()

// A cute face on the bulb: two eyes and a smile.
NSColor(calibratedRed: 1, green: 0.97, blue: 0.94, alpha: 1).setFill()
for dx in [-38.0, 38.0] {
    NSBezierPath(ovalIn: NSRect(x: bulbCenter.x + dx - 13, y: bulbCenter.y + 14,
                                width: 26, height: 34)).fill()
}
let smile = NSBezierPath()
smile.appendArc(withCenter: NSPoint(x: bulbCenter.x, y: bulbCenter.y - 8),
                radius: 44, startAngle: 205, endAngle: 335)
smile.lineWidth = 16
smile.lineCapStyle = .round
NSColor(calibratedRed: 1, green: 0.97, blue: 0.94, alpha: 1).setStroke()
smile.stroke()

// Tick marks on the stem's right side.
NSColor(calibratedRed: 1, green: 0.62, blue: 0.42, alpha: 1).setFill()
for y in stride(from: 560.0, through: 740.0, by: 90.0) {
    NSBezierPath(
        roundedRect: NSRect(x: cx + stemWidth / 2 + 26, y: y, width: 56, height: 18),
        xRadius: 9, yRadius: 9).fill()
}

image.unlockFocus()

// Write the master PNG.
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outDir = scriptDir.appendingPathComponent("icon.iconset")
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("couldn't render the master PNG")
}
let master = outDir.appendingPathComponent("icon_512x512@2x.png")
try! png.write(to: master)

// Downscale into the full iconset with sips, then build the .icns.
func shell(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(args[0]) failed")
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
]
for size in sizes {
    shell(["sips", "-z", "\(size.px)", "\(size.px)", master.path,
           "--out", outDir.appendingPathComponent(size.name).path])
}

let icns = scriptDir.appendingPathComponent("AppIcon.icns")
shell(["iconutil", "-c", "icns", outDir.path, "-o", icns.path])
try? FileManager.default.removeItem(at: outDir)
print("wrote \(icns.path)")
