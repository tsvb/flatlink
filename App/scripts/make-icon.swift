// Draws the app icon into Resources/Assets.xcassets/AppIcon.appiconset.
//
//   swift scripts/make-icon.swift
//
// Photos filed at three depths (white), each linked (marigold) into one flat column.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    // y grows upward in CoreGraphics; the layout below is written top-down.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // The macOS icon grid: an 824 pt rounded square with room for the shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0A2438))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0x0A2438), color(0x0D3654), color(0x155178)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 260, y: 180), startRadius: 0, endCenter: CGPoint(x: 260, y: 180), endRadius: 700, options: [])
    ctx.restoreGState()

    // The tree: a trunk with photos hung at three depths.
    let photos = [CGPoint(x: 300, y: 330), CGPoint(x: 370, y: 512), CGPoint(x: 440, y: 694)]
    let slots = [CGPoint(x: 690, y: 330), CGPoint(x: 690, y: 512), CGPoint(x: 690, y: 694)]
    ctx.setLineCap(.round)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(color(0xFFFFFF, 0.45))
    ctx.move(to: CGPoint(x: 230, y: 250))
    ctx.addLine(to: CGPoint(x: 230, y: 694))
    for photo in photos {
        ctx.move(to: CGPoint(x: 230, y: photo.y))
        ctx.addLine(to: CGPoint(x: photo.x - 40, y: photo.y))
    }
    ctx.strokePath()

    // Links from each photo to its place in the flat column.
    ctx.setStrokeColor(color(0xE89E29))
    ctx.setLineWidth(22)
    for (photo, slot) in zip(photos, slots) {
        ctx.move(to: CGPoint(x: photo.x + 70, y: photo.y))
        ctx.addLine(to: CGPoint(x: slot.x - 40, y: slot.y))
    }
    ctx.strokePath()

    // Originals, white.
    for photo in photos {
        let r = CGRect(x: photo.x - 50, y: photo.y - 60, width: 120, height: 120)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil))
    }
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()

    // Links, marigold, all side by side in one folder.
    let column = CGRect(x: 630, y: 240, width: 170, height: 544)
    ctx.addPath(CGPath(roundedRect: column, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.08))
    ctx.fillPath()
    for slot in slots {
        let r = CGRect(x: slot.x - 40, y: slot.y - 55, width: 150, height: 110)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil))
    }
    ctx.setFillColor(color(0xE89E29))
    ctx.fillPath()

    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset")
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! draw(points * scale).write(to: folder.appendingPathComponent(name))
    }
}
