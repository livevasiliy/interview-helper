// Generates the app icon set (all macOS sizes) so the icon is reproducible from source:
//   swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

/// Draws one icon at an exact pixel size: a dark rounded square with a green waveform
/// (the same green as the "Listening" dot), following macOS's icon grid (body = 80.5% of the canvas).
func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let inset = size * 0.0977
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)

    // Soft drop shadow, as macOS icons have.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.20, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(
        starting: NSColor(calibratedRed: 0.21, green: 0.25, blue: 0.31, alpha: 1),
        ending: NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 1)
    )!.draw(in: path, angle: -90)

    // Waveform glyph.
    let green = NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [green]))
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let glyph = symbol.size
        symbol.draw(
            in: NSRect(x: (size - glyph.width) / 2, y: (size - glyph.height) / 2, width: glyph.width, height: glyph.height),
            from: .zero, operation: .sourceOver, fraction: 1
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

var images: [[String: String]] = []
for entry in entries {
    let file = "\(entry.name).png"
    try render(pixels: entry.points * entry.scale).write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(file))
    images.append(["idiom": "mac", "size": "\(entry.points)x\(entry.points)", "scale": "\(entry.scale)x", "filename": file])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("Contents.json"))
print("wrote \(entries.count) icons to \(outputDirectory)")
