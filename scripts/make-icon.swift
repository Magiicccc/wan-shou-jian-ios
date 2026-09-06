import AppKit

let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Failed to allocate icon canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.08, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let ring = NSBezierPath(ovalIn: NSRect(x: 154, y: 154, width: 716, height: 716))
NSColor(calibratedWhite: 0.48, alpha: 0.45).setStroke()
ring.lineWidth = 2
ring.stroke()
let blade = NSBezierPath()
blade.move(to: NSPoint(x: 512, y: 846))
blade.line(to: NSPoint(x: 563, y: 724))
blade.line(to: NSPoint(x: 548, y: 354))
blade.line(to: NSPoint(x: 512, y: 307))
blade.line(to: NSPoint(x: 476, y: 354))
blade.line(to: NSPoint(x: 461, y: 724))
blade.close()
let silver = NSGradient(colors: [NSColor(calibratedWhite: 0.54, alpha: 1), .white, NSColor(calibratedRed: 0.58, green: 0.7, blue: 0.81, alpha: 1)])!
silver.draw(in: blade, angle: 0)
NSColor(calibratedWhite: 0.1, alpha: 0.55).setStroke()
let spine = NSBezierPath()
spine.move(to: NSPoint(x: 512, y: 793))
spine.line(to: NSPoint(x: 512, y: 359))
spine.lineWidth = 2
spine.stroke()
let guardPath = NSBezierPath(roundedRect: NSRect(x: 368, y: 295, width: 288, height: 26), xRadius: 10, yRadius: 10)
silver.draw(in: guardPath, angle: 90)
let grip = NSBezierPath(roundedRect: NSRect(x: 492, y: 184, width: 40, height: 101), xRadius: 8, yRadius: 8)
silver.draw(in: grip, angle: 0)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render original app icon")
}
try png.write(to: URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"), options: .atomic)
