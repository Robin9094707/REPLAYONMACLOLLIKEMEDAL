// Renders the 1024×1024 app icon. Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
// "fullbleed": square, opaque icon for iOS (the system applies the rounded mask itself).
let fullBleed = CommandLine.arguments.contains("fullbleed")

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824×824 body centred in 1024 canvas.
let inset: CGFloat = fullBleed ? 0 : 100
let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = fullBleed ? 0 : 185

let shadow = NSShadow()
if fullBleed { shadow.shadowColor = .clear }
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.22, blue: 0.45, alpha: 1),
])!
gradient.draw(in: path, angle: -45)

// Ring
let center = NSPoint(x: size / 2, y: size / 2)
let ringRadius: CGFloat = 250
let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
ring.lineWidth = 48
NSColor.white.setStroke()
ring.stroke()

// Rewind arrow notch on ring (replay)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: center.x - ringRadius - 70, y: center.y + 40))
arrow.line(to: NSPoint(x: center.x - ringRadius + 70, y: center.y + 40))
arrow.line(to: NSPoint(x: center.x - ringRadius, y: center.y - 60))
arrow.close()
NSColor.white.setFill()
arrow.fill()

// Record dot
let dotRadius: CGFloat = 150
let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2))
NSColor(calibratedRed: 1, green: 0.27, blue: 0.27, alpha: 1).setFill()
dot.fill()
NSColor.white.setStroke()
dot.lineWidth = 18
dot.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
