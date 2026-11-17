// Draws the BookmarkBridge icon: a white bookmark ribbon carrying a two-way sync
// mark, on a blue-to-teal rounded square.
//
//   swift Scripts/make-icon.swift <output.png> [plain]
//
// "plain" fills the whole canvas edge to edge with no margin or shadow, for the
// small Chrome extension icons.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: make-icon.swift <output.png> [plain]") }
let plain = args.count > 2 && args[2] == "plain"

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: macOS icons sit in an 824-point rounded square inside the 1024 canvas.
let tile = plain ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = plain ? 220 : 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

if !plain {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1F5FE0))
    ctx.fillPath()
    ctx.restoreGState()
}

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x3A7BFF), color(0x1F5FE0), color(0x12B5A6)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// A soft highlight across the top, so the tile does not look flat.
let shine = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.midY), options: [])
ctx.restoreGState()

// The bookmark ribbon.
let scale: CGFloat = plain ? 1.55 : 1.25
ctx.translateBy(x: 512, y: 512)
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: -512, y: -512)

let left: CGFloat = 352, right: CGFloat = 672, top: CGFloat = 780, bottom: CGFloat = 236, notch: CGFloat = 350, corner: CGFloat = 44
let ribbon = CGMutablePath()
ribbon.move(to: CGPoint(x: left, y: bottom))
ribbon.addLine(to: CGPoint(x: left, y: top - corner))
ribbon.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + corner, y: top), radius: corner)
ribbon.addLine(to: CGPoint(x: right - corner, y: top))
ribbon.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top - corner), radius: corner)
ribbon.addLine(to: CGPoint(x: right, y: bottom))
ribbon.addLine(to: CGPoint(x: 512, y: notch))
ribbon.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0A2A6B, 0.35))
ctx.addPath(ribbon)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Two arrows chasing each other: changes travel both ways.
let center = CGPoint(x: 512, y: 580)
let ring: CGFloat = 100, stroke: CGFloat = 40, head: CGFloat = 64
func arrow(from startDeg: CGFloat, to endDeg: CGFloat, _ hex: UInt32) {
    let start = startDeg * .pi / 180, end = endDeg * .pi / 180
    ctx.setStrokeColor(color(hex))
    ctx.setFillColor(color(hex))
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: ring, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
    // Arrowhead at the end, pointing along the direction of travel (clockwise).
    let tip = end - 0.42
    let direction = tip - .pi / 2
    let p = CGPoint(x: center.x + ring * cos(end), y: center.y + ring * sin(end))
    let forward = CGPoint(x: cos(direction), y: sin(direction))
    let side = CGPoint(x: -forward.y, y: forward.x)
    ctx.move(to: CGPoint(x: p.x + forward.x * head, y: p.y + forward.y * head))
    ctx.addLine(to: CGPoint(x: p.x + side.x * head * 0.72, y: p.y + side.y * head * 0.72))
    ctx.addLine(to: CGPoint(x: p.x - side.x * head * 0.72, y: p.y - side.y * head * 0.72))
    ctx.closePath()
    ctx.fillPath()
}
arrow(from: 165, to: 40, 0x1F5FE0)
arrow(from: 345, to: 220, 0x12B5A6)

try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
