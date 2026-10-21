import AppKit
import ImageIO
import UniformTypeIdentifiers

struct AnnotationColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let coral = AnnotationColor(red: 0.96, green: 0.25, blue: 0.23)
    static let ink = AnnotationColor(red: 0.08, green: 0.09, blue: 0.12)
    static let white = AnnotationColor(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemRed
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

enum AnnotationTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case select, arrow, curvedArrow, line, rectangle, ellipse, pen, text, counter
    case highlight, spotlight, pixelate, blur, redact, crop, image

    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .curvedArrow: return "Curved arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .text: return "Text"
        case .counter: return "Counter"
        case .highlight: return "Highlight"
        case .spotlight: return "Spotlight"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .redact: return "Redact"
        case .crop: return "Crop"
        case .image: return "Image"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .curvedArrow: return "arrow.turn.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .highlight: return "highlighter"
        case .spotlight: return "rectangle.center.inset.filled"
        case .pixelate: return "checkerboard.rectangle"
        case .blur: return "drop.fill"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        case .image: return "photo.badge.plus"
        }
    }

    var keyboardKey: String? {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .curvedArrow: return "u"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .text: return "t"
        case .counter: return "n"
        case .highlight: return "h"
        case .spotlight: return "s"
        case .pixelate: return "x"
        case .blur: return "b"
        case .redact: return "d"
        case .crop: return "c"
        case .image: return nil
        }
    }
}

struct ImageAnnotation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var tool: AnnotationTool
    var rect: CGRect
    var points: [CGPoint] = []
    var color = AnnotationColor.coral
    var lineWidth: Double = 5
    var filled = false
    var text = ""
    var fontSize: Double = 28
    var bold = true
    var italic = false
    var number = 1
    var imageID: UUID?

    var bounds: CGRect {
        guard !points.isEmpty else { return rect.standardized }
        let x = points.map(\.x), y = points.map(\.y)
        return CGRect(x: x.min() ?? 0, y: y.min() ?? 0,
                      width: max(1, (x.max() ?? 0) - (x.min() ?? 0)),
                      height: max(1, (y.max() ?? 0) - (y.min() ?? 0)))
    }

    // strokes count where they are drawn, not across their whole bounding box
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard [.pen, .line, .arrow, .curvedArrow].contains(tool), let start = points.first, let end = points.last, points.count >= 2 else {
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
        var path = points
        if tool == .curvedArrow {
            let control = points.count > 2 ? points[1] : CGPoint(x: end.x, y: start.y)
            path = (0...24).map { step in
                let t = CGFloat(step) / 24, u = 1 - t
                return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x, y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
            }
        }
        let reach = tolerance + lineWidth / 2
        return zip(path, path.dropFirst()).contains { a, b in
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= reach
        }
    }

    mutating func move(dx: CGFloat, dy: CGFloat) {
        rect = rect.offsetBy(dx: dx, dy: dy)
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    mutating func resize(from old: CGRect, to new: CGRect) {
        guard old.width > 0, old.height > 0 else { return }
        let sx = new.width / old.width, sy = new.height / old.height
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: new.minX + (point.x - old.minX) * sx,
                    y: new.minY + (point.y - old.minY) * sy)
        }
        rect = CGRect(origin: map(rect.origin), size: CGSize(width: rect.width * sx, height: rect.height * sy))
        points = points.map(map)
        if tool == .text || tool == .counter { fontSize = max(6, min(512, fontSize * min(sx, sy))) }
    }

    var isValid: Bool {
        rect.isFiniteRect && abs(rect.minX) < 200_000 && abs(rect.minY) < 200_000 &&
        abs(rect.width) <= 200_000 && abs(rect.height) <= 200_000 &&
        points.count <= 100_000 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) < 200_000 && abs($0.y) < 200_000 } &&
        color.isValid && lineWidth.isFinite && (0.5...200).contains(lineWidth) &&
        fontSize.isFinite && (6...512).contains(fontSize) && text.utf8.count <= 100_000 &&
        (0...999_999).contains(number) && tool != .select && tool != .crop
    }
}

struct ImageBackground: Codable, Equatable, Sendable {
    var enabled = false
    var color = AnnotationColor(red: 0.18, green: 0.20, blue: 0.31)
    var secondColor = AnnotationColor(red: 0.40, green: 0.31, blue: 0.57)
    var gradient = true
    var padding: Double = 64
    var cornerRadius: Double = 14
    var shadow: Double = 24
    var aspectRatio: Double = 0
    var imageID: UUID?
    var contentOffset: CGPoint?
    var inset: Double?
    var insetColor: AnnotationColor?

    var isValid: Bool {
        color.isValid && secondColor.isValid && padding.isFinite && (0...1000).contains(padding) &&
        cornerRadius.isFinite && (0...500).contains(cornerRadius) && shadow.isFinite && (0...200).contains(shadow) &&
        aspectRatio.isFinite && (aspectRatio == 0 || (0.1...10).contains(aspectRatio)) &&
        (contentOffset.map { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 } ?? true) &&
        (inset.map { $0.isFinite && (0...300).contains($0) } ?? true) && (insetColor?.isValid ?? true)
    }
}

struct ImageDocument: Codable, Equatable, Sendable {
    var version = 1
    var sourceSize: CGSize
    var cropRect: CGRect
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var outputScale: Double = 1
    var annotations: [ImageAnnotation] = []
    var background = ImageBackground()

    var renderingAnnotations: [ImageAnnotation] {
        annotations.filter { $0.tool != .counter } + annotations.filter { $0.tool == .counter }
    }

    init(size: CGSize) {
        sourceSize = size
        cropRect = CGRect(origin: .zero, size: size)
    }

    var contentSize: CGSize {
        quarterTurns % 2 == 0 ? cropRect.size : CGSize(width: cropRect.height, height: cropRect.width)
    }

    var canvasSize: CGSize {
        guard background.enabled else { return contentSize }
        var size = CGSize(width: contentSize.width + 2 * (background.padding + backgroundInset),
                          height: contentSize.height + 2 * (background.padding + backgroundInset))
        if background.aspectRatio > 0 {
            if size.width / size.height < background.aspectRatio {
                size.width = size.height * background.aspectRatio
            } else { size.height = size.width / background.aspectRatio }
        }
        return size
    }

    var contentOrigin: CGPoint {
        let xSpace = canvasSize.width - contentSize.width - 2 * backgroundInset
        let ySpace = canvasSize.height - contentSize.height - 2 * backgroundInset
        let offset = background.enabled ? background.contentOffset ?? .zero : .zero
        return CGPoint(x: backgroundInset + min(xSpace, max(0, xSpace / 2 + offset.x)),
                       y: backgroundInset + min(ySpace, max(0, ySpace / 2 + offset.y)))
    }

    var backgroundInset: Double { background.enabled ? background.inset ?? 0 : 0 }

    // annotations stay in original pixel coordinates through crop, rotation and resize
    var originalToCanvas: CGAffineTransform {
        let width = cropRect.width, height = cropRect.height
        var transform = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        let rotation: CGAffineTransform
        switch quarterTurns {
        case 1: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 2: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: rotation = .identity
        }
        transform = transform.concatenating(rotation)
        if flipHorizontal {
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: contentSize.width, ty: 0))
        }
        if flipVertical {
            transform = transform.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: contentSize.height))
        }
        return transform.concatenating(CGAffineTransform(translationX: contentOrigin.x, y: contentOrigin.y))
    }

    var outputSize: CGSize {
        CGSize(width: max(1, (canvasSize.width * outputScale).rounded()),
               height: max(1, (canvasSize.height * outputScale).rounded()))
    }

    func validated() throws -> ImageDocument {
        let assets = Set(annotations.compactMap(\.imageID) + [background.imageID].compactMap { $0 })
        guard assets.count + 1 <= ImageProject.maximumAssetCount else {
            throw GlintError.message("This project contains too many image assets.")
        }
        guard version == 1,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              sourceSize.width <= 100_000, sourceSize.height <= 100_000,
              sourceSize.width * sourceSize.height <= 80_000_000,
              cropRect.isFiniteRect, cropRect.width >= 1, cropRect.height >= 1,
              abs(cropRect.minX) <= 100_000, abs(cropRect.minY) <= 100_000,
              cropRect.width <= 100_000, cropRect.height <= 100_000,
              cropRect.width * cropRect.height <= 80_000_000,
              (0...3).contains(quarterTurns), outputScale.isFinite, (0.01...16).contains(outputScale),
              outputSize.width * outputSize.height <= 80_000_000,
              outputSize.width <= 100_000, outputSize.height <= 100_000,
              background.isValid, annotations.count <= 10_000,
              Set(annotations.map(\.id)).count == annotations.count,
              annotations.allSatisfy(\.isValid) else {
            throw GlintError.message("This image project contains unsupported or invalid dimensions.")
        }
        return self
    }
}

extension CGRect {
    var isFiniteRect: Bool { [origin.x, origin.y, width, height].allSatisfy(\.isFinite) }
}

struct ImageProjectContents: @unchecked Sendable {
    let document: ImageDocument
    let source: CGImage
    let insertedImages: [UUID: CGImage]
}

enum ImageProject {
    static let maximumAssetCount = 128
    static let maximumDecodedPixels = 160_000_000

    static func readImage(_ url: URL) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw GlintError.message("This image couldn’t be opened.")
        }
        return try readImage(source)
    }

    static func readImage(_ source: CGImageSource) throws -> CGImage {
        let (width, height) = try dimensions(of: source)
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary) else { throw GlintError.message("This image couldn’t be decoded.") }
        try Task.checkCancellation()
        return image
    }

    private static func dimensions(of source: CGImageSource) throws -> (Int, Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              width * height <= 80_000_000 else {
            throw GlintError.message("This image is too large or has invalid dimensions.")
        }
        return (width, height)
    }

    private static func pixelCount(at url: URL) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw GlintError.message("This image couldn’t be opened.")
        }
        let (width, height) = try dimensions(of: source)
        return width * height
    }

    private static func file(_ relativePath: String, in directory: URL) throws -> URL {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = directory.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.path.hasPrefix(root.path + "/"), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 250_000_000 else {
            throw GlintError.message("This project contains an invalid image file.")
        }
        return url
    }

    static func load(_ url: URL) throws -> ImageProjectContents {
        try Task.checkCancellation()
        if url.pathExtension.lowercased() != "glint" {
            let source = try readImage(url)
            let document = try ImageDocument(size: CGSize(width: source.width, height: source.height)).validated()
            return ImageProjectContents(document: document, source: source, insertedImages: [:])
        }
        let documentURL = try file("document.json", in: url)
        let size = try documentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw GlintError.message("This project is too large to open safely.") }
        let document = try JSONDecoder().decode(ImageDocument.self, from: Data(contentsOf: documentURL)).validated()
        let assetIDs = Set(document.annotations.compactMap(\.imageID) + [document.background.imageID].compactMap { $0 })
        let originalURL = try file("original.png", in: url)
        var decodedPixels = try pixelCount(at: originalURL)
        var assetURLs: [UUID: URL] = [:]
        // check the complete decoded size before allocating any image buffers
        for id in assetIDs {
            try Task.checkCancellation()
            let assetURL = try file("images/\(id.uuidString).png", in: url)
            decodedPixels += try pixelCount(at: assetURL)
            guard decodedPixels <= maximumDecodedPixels else { throw GlintError.message("This project contains too many large images.") }
            assetURLs[id] = assetURL
        }
        let source = try readImage(originalURL)
        guard source.width == Int(document.sourceSize.width), source.height == Int(document.sourceSize.height) else {
            throw GlintError.message("The project’s original image doesn’t match its document.")
        }
        var inserted: [UUID: CGImage] = [:]
        decodedPixels = source.width * source.height
        for (id, assetURL) in assetURLs {
            let image = try readImage(assetURL)
            decodedPixels += image.width * image.height
            guard decodedPixels <= maximumDecodedPixels else { throw GlintError.message("This project contains too many large images.") }
            inserted[id] = image
        }
        return ImageProjectContents(document: document, source: source, insertedImages: inserted)
    }

    static func save(_ contents: ImageProjectContents, to url: URL) throws {
        let document = try contents.document.validated()
        let usedIDs = Set(document.annotations.compactMap(\.imageID) + [document.background.imageID].compactMap { $0 })
        let decodedPixels = usedIDs.reduce(contents.source.width * contents.source.height) { total, id in
            guard let image = contents.insertedImages[id] else { return total }
            return total + image.width * image.height
        }
        guard decodedPixels <= maximumDecodedPixels else { throw GlintError.message("This project contains too many large images.") }
        let manager = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".Glint-\(UUID().uuidString).glint")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: staging.appendingPathComponent("document.json"), options: .atomic)
        try ImageFile.write(contents.source, to: staging.appendingPathComponent("original.png"))
        if !usedIDs.isEmpty {
            try manager.createDirectory(at: staging.appendingPathComponent("images"), withIntermediateDirectories: true)
            for id in usedIDs {
                guard let image = contents.insertedImages[id] else {
                    throw GlintError.message("An image used in this project is missing.")
                }
                try ImageFile.write(image, to: staging.appendingPathComponent("images/\(id.uuidString).png"))
            }
        }
        let preview = try ImageRenderer.render(contents, maximumDimension: 1600)
        try ImageFile.write(preview, to: staging.appendingPathComponent("preview.png"))
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: staging)
        } else { try manager.moveItem(at: staging, to: url) }
    }
}
