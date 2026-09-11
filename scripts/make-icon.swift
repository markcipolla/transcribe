#!/usr/bin/env swift
// Draws the app icon into Transcribe/Assets.xcassets/AppIcon.appiconset.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit

let output = URL(fileURLWithPath: "Transcribe/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // macOS icon grid: the tile is inset ~10% with a continuous-corner radius.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.23, blue: 0.62, alpha: 1),
                        NSColor(red: 0.13, green: 0.62, blue: 0.72, alpha: 1)])!
        .draw(in: path, angle: -60)

    // Waveform bars.
    let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.46, 0.84, 0.56, 0.34, 0.6, 0.28]
    let barWidth = tile.width * 0.055
    let gap = tile.width * 0.035
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = tile.midX - total / 2
    NSColor.white.withAlphaComponent(0.95).setFill()
    for height in heights {
        let h = tile.height * 0.62 * height
        let bar = NSRect(x: x, y: tile.midY - h / 2, width: barWidth, height: h)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
try Data(#"{"info":{"version":1,"author":"xcode"}}"#.utf8)
    .write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
