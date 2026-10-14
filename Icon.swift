import AppKit
import Foundation

let directory = "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
func icon(_ pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let s = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: s, y: s)
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 202, yRadius: 202)
    background.addClip()
    NSGradient(starting: NSColor(red: 0.10, green: 0.27, blue: 0.43, alpha: 1), ending: NSColor(red: 0.22, green: 0.64, blue: 0.83, alpha: 1))!.draw(in: background, angle: 60)
    NSColor.white.withAlphaComponent(0.10).setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 510, width: 950, height: 620)).fill()
    for (x, y, alpha) in [(270.0, 390.0, 0.30), (204.0, 280.0, 0.60)] {
        NSColor.white.withAlphaComponent(alpha).setFill()
        let card = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 550, height: 365), xRadius: 60, yRadius: 60)
        card.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        card.lineWidth = 4
        card.stroke()
    }
    NSColor(red: 0.09, green: 0.30, blue: 0.47, alpha: 0.6).setFill()
    NSBezierPath(roundedRect: NSRect(x: 246, y: 322, width: 466, height: 281), xRadius: 32, yRadius: 32).fill()
    NSColor.white.withAlphaComponent(0.62).setFill()
    NSBezierPath(roundedRect: NSRect(x: 282, y: 475, width: 394, height: 85), xRadius: 18, yRadius: 18).fill()
    NSColor.white.withAlphaComponent(0.35).setFill()
    for row in 0..<2 {
        NSBezierPath(roundedRect: NSRect(x: 282, y: 363 + row * 42, width: 310 - row * 58, height: 20), xRadius: 8, yRadius: 8).fill()
    }
    image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size)@2x.png"))
}
