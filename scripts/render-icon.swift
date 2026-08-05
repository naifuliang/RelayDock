#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-icon.swift <output.png>\n".utf8))
    exit(2)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Unable to create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let tile = NSBezierPath(
    roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860),
    xRadius: 190,
    yRadius: 190
)
NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1).setFill()
tile.fill()

let center = NSPoint(x: 512, y: 512)
let innerRadius: CGFloat = 86
let outerRadius: CGFloat = 198
let strokeColor = NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 240 / 255, alpha: 1)

for degrees in [90.0, 210.0, 330.0] {
    let radians = CGFloat(degrees * .pi / 180)
    let start = NSPoint(
        x: center.x + cos(radians) * innerRadius,
        y: center.y + sin(radians) * innerRadius
    )
    let end = NSPoint(
        x: center.x + cos(radians) * outerRadius,
        y: center.y + sin(radians) * outerRadius
    )
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = 30
    path.lineCapStyle = .round
    strokeColor.setStroke()
    path.stroke()
}

let hub = NSBezierPath(ovalIn: NSRect(x: 466, y: 466, width: 92, height: 92))
NSColor(srgbRed: 1, green: 122 / 255, blue: 26 / 255, alpha: 1).setFill()
hub.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
