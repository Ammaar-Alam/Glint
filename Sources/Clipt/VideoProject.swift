import AppKit
import AVFoundation

struct VideoTimeRange: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}

struct VideoPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    static let center = VideoPoint(x: 0.5, y: 0.5)
    var clamped: VideoPoint { .init(x: min(1, max(0, x)), y: min(1, max(0, y))) }
}

struct VideoCursorSample: Codable, Equatable, Sendable {
    var time: Double
    var position: VideoPoint
    var visible: Bool = true
}

struct VideoClick: Codable, Equatable, Sendable {
    var time: Double
    var position: VideoPoint
    var button: Int = 0
    var releaseTime: Double?
}

struct VideoKeystroke: Codable, Equatable, Sendable {
    var time: Double
    var text: String
    var isShortcut: Bool = true
}

struct VideoZoom: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Double
    var duration: Double = 3
    var scale: Double = 1.7
    var center: VideoPoint = .center
    var followsCursor = true
}

enum VideoAspect: String, CaseIterable, Codable, Sendable, Identifiable {
    case original = "Original", wide = "Landscape", square = "Square", portrait = "Portrait"
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .wide: return 16 / 9
        case .square: return 1
        case .portrait: return 9 / 16
        }
    }
}

enum VideoCameraPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case bottomRight = "Bottom right", bottomLeft = "Bottom left", topRight = "Top right", topLeft = "Top left"
    var id: String { rawValue }
}

enum VideoCameraShape: String, CaseIterable, Codable, Sendable, Identifiable {
    case circle = "Circle", rounded = "Rounded", square = "Square"
    var id: String { rawValue }
}

enum VideoCursorStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case arrow = "Arrow", circle = "Circle"
    var id: String { rawValue }
}

enum VideoCursorMovement: String, CaseIterable, Codable, Sendable, Identifiable {
    case recorded = "Recorded", smooth = "Smooth"
    var id: String { rawValue }
}

enum VideoKeyPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case bottomLeft = "Bottom left", bottom = "Bottom center", bottomRight = "Bottom right"
    case topLeft = "Top left", top = "Top center", topRight = "Top right"
    var id: String { rawValue }
}

enum VideoKeyStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case dark = "Dark", light = "Light", plain = "Plain"
    var id: String { rawValue }
}

struct VideoColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    static let blue = VideoColor(red: 0.16, green: 0.25, blue: 0.48)
    static let purple = VideoColor(red: 0.40, green: 0.23, blue: 0.53)
    static let white = VideoColor(red: 1, green: 1, blue: 1)
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

struct VideoEdits: Codable, Equatable, Sendable {
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var cuts: [VideoTimeRange] = []
    var zooms: [VideoZoom] = []
    var aspect: VideoAspect = .original
    var maximumDimension: Int = 1920
    var customWidth: Int?
    var customHeight: Int?
    var exportQuality: Double = 0.85
    var audioEnabled = true
    var padding: Double = 48
    var cornerRadius: Double = 16
    var shadow: Double = 20
    var backgroundTop: VideoColor = .blue
    var backgroundBottom: VideoColor = .purple
    var backgroundFile: String?
    var showsBackground = true
    var showsCursor = true
    var cursorScale: Double = 1.5
    var cursorStyle: VideoCursorStyle = .arrow
    var cursorSmoothing: Double = 0.4
    var cursorMovement: VideoCursorMovement = .smooth
    var cursorHideWhenStationary = false
    var cursorHideWhileTyping = false
    var cursorPressEffect = true
    var showsClicks = true
    var clickColor: VideoColor = .init(red: 1, green: 0.65, blue: 0.15)
    var clickSize: Double = 1
    var clickFilled = false
    var clickAnimated = true
    var showsKeystrokes = true
    var keystrokeScale: Double = 1
    var keystrokesOnlyShortcuts = true
    var keystrokePosition: VideoKeyPosition = .bottom
    var keystrokeStyle: VideoKeyStyle = .dark
    var showsCamera = true
    var cameraSize: Double = 0.20
    var cameraPosition: VideoCameraPosition = .bottomRight
    var cameraShape: VideoCameraShape = .circle
    var cameraMirrored = true
    var cameraFullScreen = false
    var cameraSmallerDuringZoom = false
    var systemVolume: Double = 1
    var microphoneVolume: Double = 1
    var motionBlur: Double = 0.2
}

struct VideoProject: Codable, Equatable, Sendable {
    var version = 1
    var createdAt = Date()
    var screenFile = "screen.mov"
    var cameraFile: String?
    var backgroundFiles: [String] = []
    var cameraStartTime: Double = 0
    var systemAudioTrackID: Int32?
    var microphoneAudioTrackID: Int32?
    var duration: Double
    var width: Int
    var height: Int
    var frameRate: Int = 30
    var cursorSamples: [VideoCursorSample] = []
    var clicks: [VideoClick] = []
    var keystrokes: [VideoKeystroke] = []
    var edits: VideoEdits

    init(duration: Double, width: Int, height: Int, frameRate: Int = 30) {
        self.duration = duration; self.width = width; self.height = height; self.frameRate = frameRate
        edits = VideoEdits()
        edits.trimEnd = duration
    }

    var segments: [VideoTimeRange] {
        let start = max(0, min(duration, edits.trimStart))
        let end = max(start, min(duration, edits.trimEnd))
        let cuts = edits.cuts.sorted { $0.start < $1.start }
        var result: [VideoTimeRange] = []
        var cursor = start
        for cut in cuts where cut.end > cursor && cut.start < end {
            if cut.start > cursor { result.append(.init(start: cursor, end: min(end, cut.start))) }
            cursor = max(cursor, min(end, cut.end))
        }
        if cursor < end { result.append(.init(start: cursor, end: end)) }
        return result
    }

    var editedDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    func sourceTime(at outputTime: Double) -> Double {
        var remaining = max(0, outputTime)
        for segment in segments {
            if remaining < segment.duration { return segment.start + remaining }
            remaining -= segment.duration
        }
        return segments.last?.end ?? edits.trimStart
    }

    func outputTime(at sourceTime: Double) -> Double {
        var elapsed = 0.0
        for segment in segments {
            if sourceTime < segment.start { return elapsed }
            if sourceTime <= segment.end { return elapsed + sourceTime - segment.start }
            elapsed += segment.duration
        }
        return elapsed
    }

    func validated() throws -> VideoProject {
        guard version == 1, duration.isFinite, duration > 0, duration < 7 * 24 * 3600,
              width > 0, height > 0, width <= 32768, height <= 32768,
              frameRate > 0, frameRate <= 240,
              Self.safeFilename(screenFile), cameraFile.map(Self.safeFilename) ?? true,
              backgroundFiles.allSatisfy(Self.safeFilename),
              edits.backgroundFile.map({ backgroundFiles.contains($0) }) ?? true,
              edits.trimStart.isFinite, edits.trimEnd.isFinite,
              editedDuration > 0 else {
            throw CliptError.message("This video project is incomplete or unsupported.")
        }
        let numbers = [edits.padding, edits.cornerRadius, edits.shadow, edits.cursorScale, edits.cursorSmoothing,
                       edits.cameraSize, edits.systemVolume, edits.microphoneVolume, edits.motionBlur, edits.keystrokeScale,
                       edits.exportQuality, edits.clickSize, cameraStartTime]
        let colors = [edits.backgroundTop, edits.backgroundBottom, edits.clickColor]
        guard numbers.allSatisfy(\.isFinite), edits.maximumDimension >= 320, edits.maximumDimension <= 7680,
              (0...1).contains(edits.exportQuality),
              (edits.customWidth == nil) == (edits.customHeight == nil),
              edits.customWidth.map({ (64...7680).contains($0) }) ?? true,
              edits.customHeight.map({ (64...7680).contains($0) }) ?? true,
              colors.allSatisfy({ [$0.red, $0.green, $0.blue, $0.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }),
              edits.cuts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
              edits.zooms.allSatisfy({ $0.start.isFinite && $0.duration.isFinite && $0.duration > 0 && $0.scale.isFinite && $0.scale >= 1 && $0.scale <= 8 && $0.center.x.isFinite && $0.center.y.isFinite }),
              cursorSamples.allSatisfy({ $0.time.isFinite && $0.position.x.isFinite && $0.position.y.isFinite }),
              clicks.allSatisfy({ click in click.time.isFinite && click.position.x.isFinite && click.position.y.isFinite && (click.releaseTime.map({ $0.isFinite && $0 >= click.time }) ?? true) }),
              keystrokes.allSatisfy({ $0.time.isFinite && $0.text.count <= 100 }),
              zip(cursorSamples, cursorSamples.dropFirst()).allSatisfy({ $0.0.time <= $0.1.time }),
              zip(clicks, clicks.dropFirst()).allSatisfy({ $0.0.time <= $0.1.time }),
              zip(keystrokes, keystrokes.dropFirst()).allSatisfy({ $0.0.time <= $0.1.time }) else {
            throw CliptError.message("This video project contains invalid edit data.")
        }
        return self
    }

    static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    static func load(from directory: URL) throws -> VideoProject {
        let data = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(VideoProject.self, from: data).validated()
        for file in [project.screenFile, project.cameraFile].compactMap({ $0 }) + project.backgroundFiles {
            let url = directory.appendingPathComponent(file)
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.deletingLastPathComponent() == directory.resolvingSymlinksInPath().standardizedFileURL else {
                throw CliptError.message("This project references a file outside its folder.")
            }
        }
        return project
    }

    func save(to directory: URL) throws {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
    }
}
