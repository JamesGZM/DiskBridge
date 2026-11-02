import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let rect = NSRect(x: 88, y: 88, width: 848, height: 848)
    let background = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.64, blue: 0.99, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.32, blue: 0.82, alpha: 1))!.draw(in: background, angle: -90)
    NSColor.white.setFill()
    let top = NSBezierPath()
    top.move(to: NSPoint(x: 256, y: 490)); top.line(to: NSPoint(x: 318, y: 590))
    top.line(to: NSPoint(x: 706, y: 590)); top.line(to: NSPoint(x: 768, y: 490)); top.close(); top.fill()
    NSBezierPath(roundedRect: NSRect(x: 256, y: 310, width: 512, height: 198), xRadius: 52, yRadius: 52).fill()
    NSColor(srgbRed: 0.09, green: 0.40, blue: 0.86, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 662, y: 384, width: 32, height: 32)).fill()
    NSBezierPath(roundedRect: NSRect(x: 320, y: 393, width: 220, height: 14), xRadius: 7, yRadius: 7).fill()
    NSColor.white.setStroke()
    let bridge = NSBezierPath(); bridge.lineWidth = 34; bridge.lineCapStyle = .round
    bridge.move(to: NSPoint(x: 322, y: 650)); bridge.line(to: NSPoint(x: 702, y: 650))
    bridge.move(to: NSPoint(x: 350, y: 630)); bridge.line(to: NSPoint(x: 350, y: 716))
    bridge.curve(to: NSPoint(x: 674, y: 716), controlPoint1: NSPoint(x: 420, y: 824), controlPoint2: NSPoint(x: 604, y: 824))
    bridge.line(to: NSPoint(x: 674, y: 630)); bridge.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name)) }
}
