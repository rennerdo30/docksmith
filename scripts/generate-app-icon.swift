import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-app-icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create the icon canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                        xRadius: 196, yRadius: 196)
NSGradient(starting: color(36, 52, 71), ending: color(17, 27, 42))?
    .draw(in: tile, angle: -90)

let pale = color(184, 206, 223)
let orange = color(255, 151, 63)
for (x, y, fill) in [(200.0, 410.0, pale), (424.0, 446.0, orange), (648.0, 410.0, pale)] {
    fill.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 176, height: 176),
                 xRadius: 40, yRadius: 40).fill()
}
pale.setFill()
NSBezierPath(roundedRect: NSRect(x: 184, y: 235, width: 656, height: 96),
             xRadius: 48, yRadius: 48).fill()
orange.setFill()
NSBezierPath(roundedRect: NSRect(x: 482, y: 263, width: 60, height: 40),
             xRadius: 20, yRadius: 20).fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the icon")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
