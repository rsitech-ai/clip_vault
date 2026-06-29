#!/usr/bin/env swift
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let work = output.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.22
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06), xRadius: corner, yRadius: corner)

    let gradient = NSGradient(colors: [
        NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1),
        NSColor(red: 0.11, green: 0.27, blue: 0.54, alpha: 1),
        NSColor(red: 0.22, green: 0.72, blue: 0.86, alpha: 1)
    ])!
    gradient.draw(in: path, angle: -35)

    NSColor.white.withAlphaComponent(0.20).setStroke()
    path.lineWidth = max(1, size * 0.012)
    path.stroke()

    let boardRect = NSRect(x: size * 0.25, y: size * 0.20, width: size * 0.50, height: size * 0.58)
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: size * 0.055, yRadius: size * 0.055)
    NSColor.white.withAlphaComponent(0.90).setFill()
    boardPath.fill()

    let clipRect = NSRect(x: size * 0.39, y: size * 0.72, width: size * 0.22, height: size * 0.10)
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: size * 0.04, yRadius: size * 0.04)
    NSColor(red: 0.18, green: 0.38, blue: 0.78, alpha: 1).setFill()
    clipPath.fill()

    NSColor(red: 0.11, green: 0.15, blue: 0.22, alpha: 0.72).setStroke()
    for index in 0..<4 {
        let y = boardRect.minY + size * (0.30 + CGFloat(index) * 0.085)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: boardRect.minX + size * 0.09, y: y))
        line.line(to: NSPoint(x: boardRect.maxX - size * 0.09, y: y))
        line.lineWidth = max(1.5, size * 0.018)
        line.stroke()
    }

    let sparkle = NSBezierPath()
    sparkle.move(to: NSPoint(x: size * 0.72, y: size * 0.76))
    sparkle.line(to: NSPoint(x: size * 0.78, y: size * 0.64))
    sparkle.line(to: NSPoint(x: size * 0.90, y: size * 0.58))
    sparkle.line(to: NSPoint(x: size * 0.78, y: size * 0.52))
    sparkle.line(to: NSPoint(x: size * 0.72, y: size * 0.40))
    sparkle.line(to: NSPoint(x: size * 0.66, y: size * 0.52))
    sparkle.line(to: NSPoint(x: size * 0.54, y: size * 0.58))
    sparkle.line(to: NSPoint(x: size * 0.66, y: size * 0.64))
    sparkle.close()
    NSColor(red: 0.44, green: 0.90, blue: 1.0, alpha: 0.95).setFill()
    sparkle.fill()

    image.unlockFocus()
    return image
}

for (name, size) in sizes {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render \(name)")
    }
    try png.write(to: work.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", work.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}
