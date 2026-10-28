import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "SignFlow/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 205, yRadius: 205)
NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.48, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.28, blue: 0.82, alpha: 1))!.draw(in: background, angle: -80)
let shield = NSBezierPath()
shield.move(to: NSPoint(x: 512, y: 810))
shield.curve(to: NSPoint(x: 750, y: 705), controlPoint1: NSPoint(x: 610, y: 756), controlPoint2: NSPoint(x: 694, y: 727))
shield.line(to: NSPoint(x: 735, y: 500))
shield.curve(to: NSPoint(x: 512, y: 235), controlPoint1: NSPoint(x: 725, y: 390), controlPoint2: NSPoint(x: 625, y: 282))
shield.curve(to: NSPoint(x: 289, y: 500), controlPoint1: NSPoint(x: 399, y: 282), controlPoint2: NSPoint(x: 299, y: 390))
shield.line(to: NSPoint(x: 274, y: 705))
shield.curve(to: NSPoint(x: 512, y: 810), controlPoint1: NSPoint(x: 330, y: 727), controlPoint2: NSPoint(x: 414, y: 756))
shield.close(); NSColor.white.setFill(); shield.fill()
let check = NSBezierPath(); check.lineWidth = 57; check.lineCapStyle = .round; check.lineJoinStyle = .round
check.move(to: NSPoint(x: 391, y: 527)); check.line(to: NSPoint(x: 480, y: 438)); check.line(to: NSPoint(x: 642, y: 627))
NSColor(srgbRed: 0.10, green: 0.38, blue: 0.93, alpha: 1).setStroke(); check.stroke()
image.unlockFocus()
var entries: [[String: String]] = []
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = pointSize * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let file = "icon_\(pointSize)@\(scale)x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(file))
        entries.append(["idiom": "mac", "size": "\(pointSize)x\(pointSize)", "scale": "\(scale)x", "filename": file])
    }
}
let data = try JSONSerialization.data(withJSONObject: ["images": entries, "info": ["author": "SignFlow", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination.appendingPathComponent("Contents.json"))
print("Generated 10 macOS icon renditions at \(destination.path)")
