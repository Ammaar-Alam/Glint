import AppKit
import UniformTypeIdentifiers

enum CaptureAction: String, CaseIterable, Identifiable {
    case popup, copy, save, editor
    var id: Self { self }

    var title: String {
        switch self {
        case .popup: return "Show Popup"
        case .copy: return "Copy"
        case .save: return "Save"
        case .editor: return "Open Editor"
        }
    }

    var symbol: String {
        switch self {
        case .popup: return "rectangle.on.rectangle"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .editor: return "pencil.and.outline"
        }
    }

    static func key(_ action: CaptureAction, recording: Bool) -> String {
        (recording ? "recording." : "screenshot.") + action.rawValue
    }

    static func enabled(recording: Bool, in defaults: UserDefaults = .standard) -> Set<CaptureAction> {
        Set(allCases.filter { defaults.bool(forKey: key($0, recording: recording)) })
    }

    // carries the old single after-capture choice and copy toggle over, recordings land in the popup like screenshots
    static func migrate(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: key(.popup, recording: false)) == nil {
            let legacy = defaults.string(forKey: "afterCapture")
            let screenshot: Set<CaptureAction> = [legacy == "editor" ? .editor : legacy == "save" ? .save : .popup]
            for action in allCases {
                defaults.set(screenshot.contains(action) || (action == .copy && defaults.bool(forKey: "autoCopy")), forKey: key(action, recording: false))
            }
        }
        // recordings used to open the editor by default, they now wait in the popup once
        guard !defaults.bool(forKey: "recordingPopupDefault") else { return }
        defaults.set(true, forKey: "recordingPopupDefault")
        for action in allCases { defaults.set(action == .popup, forKey: key(action, recording: true)) }
    }
}

enum ScreenshotFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    static var current: ScreenshotFormat {
        UserDefaults.standard.string(forKey: "screenshotFormat").flatMap(ScreenshotFormat.init(rawValue:)) ?? .png
    }
}

enum CaptureFolder {
    // nil means saving asks where each time
    static var current: URL? {
        guard let path = UserDefaults.standard.string(forKey: "saveFolder"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // names handed out but not written yet, so overlapping saves never share a file
    private static let lock = NSLock()
    private static var reserved: Set<String> = []

    static func uniqueURL(in folder: URL, name: String, pathExtension: String, taken: Set<String> = []) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) || taken.contains(url.path) {
            url = folder.appendingPathComponent("\(name) \(index)").appendingPathExtension(pathExtension)
            index += 1
        }
        return url
    }

    // never an existing file, a taken name gets a number
    static func destination(in folder: URL, name: String, pathExtension: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GlintError.message("The save folder “\(folder.lastPathComponent)” is no longer available. Choose another in Settings.")
        }
        // a renamed capture can contain path separators
        let name = name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        lock.lock()
        defer { lock.unlock() }
        let url = uniqueURL(in: folder, name: name, pathExtension: pathExtension, taken: reserved)
        reserved.insert(url.path)
        return url
    }

    // call once the file is written or the write failed
    static func release(_ url: URL) {
        lock.lock()
        reserved.remove(url.path)
        lock.unlock()
    }

    static func saveImage(_ source: URL, named name: String, format: ScreenshotFormat, in folder: URL) throws -> URL {
        let destination = try destination(in: folder, name: name, pathExtension: format.type.preferredFilenameExtension ?? format.rawValue)
        defer { release(destination) }
        try writeImage(source, format: format, to: destination)
        return destination
    }

    static func saveFile(_ source: URL, named name: String, in folder: URL) throws -> URL {
        let destination = try destination(in: folder, name: name, pathExtension: source.pathExtension)
        defer { release(destination) }
        try ExportFile.copy(source, to: destination)
        return destination
    }

    static func writeImage(_ source: URL, format: ScreenshotFormat, to destination: URL) throws {
        if UTType(filenameExtension: source.pathExtension) == format.type {
            try ExportFile.copy(source, to: destination)
        } else {
            let image = try ImageProject.readImage(source)
            try ImageFile.write(format == .jpeg ? opaque(image) : image, to: destination, type: format.type)
        }
    }

    // jpeg has no alpha, so transparent shadows go on white instead of black
    static func opaque(_ image: CGImage) -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }
}

enum EditorDefaults {
    static let lineWidthRange: ClosedRange<Double> = 1...40

    static var color: AnnotationColor {
        guard let data = UserDefaults.standard.data(forKey: "annotationColor"),
              let color = try? JSONDecoder().decode(AnnotationColor.self, from: data), color.isValid else { return .coral }
        return color
    }

    static var lineWidth: Double {
        let value = UserDefaults.standard.double(forKey: "annotationLineWidth")
        return lineWidthRange.contains(value) ? value : 5
    }

    static var backgroundPresets: [ImageBackground] {
        guard let data = UserDefaults.standard.data(forKey: "imageBackgroundPresets"),
              let presets = try? JSONDecoder().decode([ImageBackground].self, from: data) else { return [] }
        return presets.filter(\.isValid)
    }

    // only a preset that still exists counts, removing it in the editor turns the default off
    static var backgroundPreset: ImageBackground? {
        guard let data = UserDefaults.standard.data(forKey: "defaultBackgroundPreset"),
              let preset = try? JSONDecoder().decode(ImageBackground.self, from: data),
              backgroundPresets.contains(preset) else { return nil }
        return preset
    }

    // wraps a new screenshot in a project with the background applied, so every output keeps the style
    static func styledProject(_ url: URL, background: ImageBackground, presetDirectory: URL) throws -> URL {
        let source = try ImageProject.readImage(url)
        var document = ImageDocument(size: CGSize(width: source.width, height: source.height))
        document.background = background
        var images: [UUID: CGImage] = [:]
        if let id = background.imageID {
            images[id] = try ImageProject.readImage(presetDirectory.appendingPathComponent("\(id.uuidString).png"))
        }
        let output = ImageFile.temporaryURL(extension: "glint")
        try ImageProject.save(ImageProjectContents(document: document, source: source, insertedImages: images), to: output)
        return output
    }
}
