import AppKit
import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers

enum CaptureKind: String, Codable, Sendable {
    case image, video, imageProject, videoProject

    static func identify(_ url: URL) throws -> CaptureKind {
        switch url.pathExtension.lowercased() {
        case "glint": return .imageProject
        case "glintvideo": return .videoProject
        default:
            if let type = UTType(filenameExtension: url.pathExtension) {
                if type.conforms(to: .image) { return .image }
                if type.conforms(to: .movie) { return .video }
            }
            throw GlintError.message("Choose an image, a video, or a Glint project.")
        }
    }

    var isVideo: Bool { self == .video || self == .videoProject }
    var isProject: Bool { self == .imageProject || self == .videoProject }
}

struct CaptureItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var title: String
    var filename: String
    var kind: CaptureKind
    var modifiedAt: Date? = nil

    func directory(in root: URL) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func url(in root: URL) -> URL { directory(in: root).appendingPathComponent(filename) }
    func thumbnail(in root: URL) -> URL { directory(in: root).appendingPathComponent("thumbnail.png") }
    func shareURL(in root: URL) -> URL? {
        if kind == .videoProject { return nil }
        return kind == .imageProject ? directory(in: root).appendingPathComponent("share.png") : url(in: root)
    }

    var hasSafeFilename: Bool {
        !filename.isEmpty && filename != "." && filename != ".." &&
        !filename.contains("/") && !filename.contains("\\") && !filename.contains("\0")
    }
}

actor CaptureStorage {
    static let defaultRoot = URL.applicationSupportDirectory.appendingPathComponent("Glint/Captures", isDirectory: true)
    let root: URL

    init(root: URL = defaultRoot) { self.root = root }

    func load() throws -> [CaptureItem] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("item.json")),
                      let item = try? JSONDecoder().decode(CaptureItem.self, from: data),
                      directory.lastPathComponent == item.id.uuidString,
                      item.hasSafeFilename,
                      FileManager.default.fileExists(atPath: item.url(in: root).path) else { return nil }
                return item
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func ingest(_ source: URL, title: String) async throws -> CaptureItem {
        guard source.isFileURL else { throw GlintError.message("Only local files can be opened.") }
        let kind = try CaptureKind.identify(source)
        let item = CaptureItem(id: UUID(), createdAt: Date(), title: title,
                               filename: "capture." + source.pathExtension.lowercased(), kind: kind)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".\(UUID().uuidString).pending", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let asset = staging.appendingPathComponent(item.filename)
            try FileManager.default.copyItem(at: source, to: asset)
            let thumbnail = try await makeThumbnail(asset, kind: kind, directory: staging)
            try ImageFile.write(thumbnail, to: staging.appendingPathComponent("thumbnail.png"))
            try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("item.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: item.directory(in: root))
            return item
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func rename(_ item: CaptureItem, to title: String) throws -> CaptureItem {
        var updated = item
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { throw GlintError.message("Enter a name for this capture.") }
        try JSONEncoder().encode(updated).write(to: item.directory(in: root).appendingPathComponent("item.json"), options: .atomic)
        return updated
    }

    func refresh(_ item: CaptureItem) async throws -> CaptureItem {
        let thumbnail = try await makeThumbnail(item.url(in: root), kind: item.kind, directory: item.directory(in: root))
        try ImageFile.write(thumbnail, to: item.thumbnail(in: root))
        var updated = item
        updated.modifiedAt = Date()
        try JSONEncoder().encode(updated).write(to: item.directory(in: root).appendingPathComponent("item.json"), options: .atomic)
        return updated
    }

    private func makeThumbnail(_ url: URL, kind: CaptureKind, directory: URL) async throws -> CGImage {
        var imageURL = url
        if kind == .imageProject {
            let contents = try ImageProject.load(url)
            let flattened = try ImageRenderer.render(contents)
            imageURL = directory.appendingPathComponent("share.png")
            try ImageFile.write(flattened, to: imageURL)
        }
        if !kind.isVideo {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else {
                throw GlintError.message("The image couldn’t be read.")
            }
            return thumbnail
        }
        if kind == .videoProject {
            let project = try VideoProject.load(from: url)
            return try await VideoCompositionBuilder.thumbnail(project: project, directory: url)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        return try await generator.image(at: .zero).image
    }
}

@MainActor @Observable
final class CaptureLibrary {
    private(set) var items: [CaptureItem] = []
    private(set) var isLoading = false
    var error: String?
    let root: URL
    private let storage: CaptureStorage

    init(root: URL = CaptureStorage.defaultRoot) {
        self.root = root
        storage = CaptureStorage(root: root)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { items = try await storage.load() }
        catch { self.error = error.localizedDescription }
    }

    func ingest(_ url: URL, title: String? = nil) async throws -> CaptureItem {
        if let existing = items.first(where: { $0.url(in: root).standardizedFileURL == url.standardizedFileURL }) {
            let refreshed = try await storage.refresh(existing)
            if let index = items.firstIndex(where: { $0.id == existing.id }) { items[index] = refreshed }
            return refreshed
        }
        let item = try await storage.ingest(url, title: title ?? CaptureNaming.name())
        items.insert(item, at: 0)
        return item
    }

    func rename(_ item: CaptureItem, to title: String) async throws {
        let updated = try await storage.rename(item, to: title)
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
    }

    func trash(_ item: CaptureItem) async throws {
        let directory = item.directory(in: root)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([directory]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        items.removeAll { $0.id == item.id }
    }

    func applyRetention(days: Int) async {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in items where item.createdAt < cutoff {
            do { try await trash(item) }
            catch { self.error = error.localizedDescription; break }
        }
    }
}

enum CaptureNaming {
    static func name(date: Date = Date(), template: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: date)
        let pattern = template ?? UserDefaults.standard.string(forKey: "filenameTemplate") ?? "Glint {date} at {time}"
        let name = pattern.replacingOccurrences(of: "{date}", with: day).replacingOccurrences(of: "{time}", with: time)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "Glint \(day) at \(time)" : String(safe.prefix(160))
    }
}
