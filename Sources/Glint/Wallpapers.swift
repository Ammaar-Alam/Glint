import AppKit

// soft mesh-like backgrounds drawn on demand, kept beside saved styles so projects can reference them
enum Wallpaper {
    static let names = ["Lagoon", "Sunset", "Berry", "Meadow", "Peach", "Ocean", "Graphite", "Cloud"]

    // a base gradient plus three glows, each color as rgb
    private static let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
        [(0.05, 0.36, 0.55), (0.13, 0.78, 0.86), (0.36, 0.95, 0.85), (0.20, 0.40, 0.95), (0.55, 0.90, 1.00)],
        [(0.98, 0.45, 0.30), (0.99, 0.75, 0.35), (0.95, 0.30, 0.55), (0.55, 0.30, 0.85), (1.00, 0.88, 0.50)],
        [(0.45, 0.18, 0.75), (0.85, 0.30, 0.70), (0.30, 0.35, 0.95), (0.98, 0.45, 0.60), (0.65, 0.50, 1.00)],
        [(0.15, 0.62, 0.45), (0.65, 0.90, 0.55), (0.10, 0.75, 0.75), (0.95, 0.90, 0.45), (0.40, 0.85, 0.65)],
        [(0.98, 0.70, 0.62), (0.99, 0.88, 0.78), (0.95, 0.60, 0.75), (0.80, 0.75, 0.98), (1.00, 0.82, 0.60)],
        [(0.06, 0.15, 0.45), (0.10, 0.45, 0.85), (0.45, 0.25, 0.85), (0.15, 0.80, 0.95), (0.30, 0.35, 0.95)],
        [(0.13, 0.14, 0.18), (0.30, 0.32, 0.40), (0.22, 0.30, 0.45), (0.45, 0.42, 0.50), (0.18, 0.22, 0.30)],
        [(0.90, 0.92, 0.95), (0.99, 0.99, 1.00), (0.80, 0.88, 0.98), (0.95, 0.88, 0.95), (0.85, 0.95, 0.95)]
    ]
    private static let glows: [(CGFloat, CGFloat, CGFloat)] = [(0.18, 0.22, 0.75), (0.85, 0.30, 0.70), (0.35, 0.88, 0.80)]

    static var count: Int { palettes.count }

    static func id(_ index: Int) -> UUID { UUID(uuidString: String(format: "6C1A7E00-0000-4000-8000-%012d", index))! }

    static func render(_ index: Int, size: CGSize) -> CGImage? {
        let colors = palettes[index].map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = CGGradient(colorsSpace: space, colors: [colors[0], colors[1]] as CFArray, locations: [0, 1]) else { return nil }
        context.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let longest = max(size.width, size.height)
        for (glow, color) in zip(glows, colors.dropFirst(2)) {
            let center = CGPoint(x: size.width * glow.0, y: size.height * glow.1)
            guard let fade = CGGradient(colorsSpace: space, colors: [color.copy(alpha: 0.9)!, color.copy(alpha: 0)!] as CFArray, locations: [0, 1]) else { continue }
            context.drawRadialGradient(fade, startCenter: center, startRadius: 0, endCenter: center, endRadius: longest * glow.2, options: [])
        }
        return context.makeImage()
    }

    static let thumbnails: [NSImage] = (0..<palettes.count).map { index in
        render(index, size: CGSize(width: 160, height: 100)).map { NSImage(cgImage: $0, size: NSSize(width: 80, height: 50)) } ?? NSImage()
    }

    // writes the full size wallpaper once so the editor and saved projects can load it by id
    static func file(_ index: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(id(index).uuidString).png")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let image = render(index, size: CGSize(width: 2560, height: 1600)) else { throw GlintError.message("The background couldn’t be created.") }
        try ImageFile.write(image, to: url)
        return url
    }
}
