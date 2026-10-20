import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = NSRect(x: 54, y: 54, width: 916, height: 916)
        let base = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.47, blue: 0.85, alpha: 1), ending: NSColor(srgbRed: 0.12, green: 0.20, blue: 0.49, alpha: 1))!
        gradient.draw(in: base, angle: -80)
        NSColor.white.setStroke()
        let outline = NSBezierPath()
        outline.lineWidth = 62
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round
        for points in [[NSPoint(x: 400, y: 745), NSPoint(x: 290, y: 745), NSPoint(x: 290, y: 635)],
                       [NSPoint(x: 624, y: 745), NSPoint(x: 734, y: 745), NSPoint(x: 734, y: 635)],
                       [NSPoint(x: 290, y: 400), NSPoint(x: 290, y: 290), NSPoint(x: 400, y: 290)],
                       [NSPoint(x: 624, y: 290), NSPoint(x: 734, y: 290), NSPoint(x: 734, y: 400)]] {
            outline.move(to: points[0]); outline.line(to: points[1]); outline.line(to: points[2])
        }
        outline.stroke()
        NSColor(srgbRed: 0.51, green: 0.93, blue: 0.83, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 448, y: 448, width: 128, height: 128)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not render icon") }
        try data.write(to: url)
    }
}
