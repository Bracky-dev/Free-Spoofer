// Draws a 1024px app icon (location pin on a blue squircle) to the path in argv[1].
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824px rounded square centered in 1024
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.33, green: 0.62, blue: 1.0, alpha: 1).cgColor,
    NSColor(srgbRed: 0.10, green: 0.32, blue: 0.92, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Ground ellipse under the pin
ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
ctx.fillEllipse(in: CGRect(x: size / 2 - 150, y: 215, width: 300, height: 70))

// Pin: circle head + tapered point
let cx = size / 2, headY: CGFloat = 600, r: CGFloat = 200, tipY: CGFloat = 250
let pin = CGMutablePath()
let theta = acos(r / (headY - tipY))
pin.move(to: CGPoint(x: cx, y: tipY))
pin.addLine(to: CGPoint(x: cx + r * sin(theta), y: headY - r * cos(theta)))
pin.addArc(center: CGPoint(x: cx, y: headY), radius: r, startAngle: -.pi / 2 + theta, endAngle: 3 * .pi / 2 - theta, clockwise: false)
pin.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(pin)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Hole in the head
ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.45, blue: 0.97, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: cx - 80, y: headY - 80, width: 160, height: 160))
ctx.restoreGState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
