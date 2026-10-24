import XCTest
import CoreGraphics
import UniformTypeIdentifiers
@testable import Glint

final class SettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "glint-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // half transparent red so format conversion and flattening are visible
    private func png(in folder: URL, width: Int = 8, height: Int = 6) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = folder.appendingPathComponent("source.png")
        try ImageFile.write(context.makeImage()!, to: url)
        return url
    }

    func testMigrationKeepsLegacyChoices() {
        let fresh = defaults()
        CaptureAction.migrate(fresh)
        XCTAssertEqual(CaptureAction.enabled(recording: false, in: fresh), [.popup])
        XCTAssertEqual(CaptureAction.enabled(recording: true, in: fresh), [.editor])

        let editor = defaults()
        editor.set("editor", forKey: "afterCapture")
        editor.set(true, forKey: "autoCopy")
        CaptureAction.migrate(editor)
        XCTAssertEqual(CaptureAction.enabled(recording: false, in: editor), [.editor, .copy])
        XCTAssertEqual(CaptureAction.enabled(recording: true, in: editor), [.editor])

        let save = defaults()
        save.set("save", forKey: "afterCapture")
        CaptureAction.migrate(save)
        XCTAssertEqual(CaptureAction.enabled(recording: false, in: save), [.save])

        // later choices survive another launch
        save.set(true, forKey: CaptureAction.key(.popup, recording: false))
        save.set(false, forKey: CaptureAction.key(.save, recording: false))
        CaptureAction.migrate(save)
        XCTAssertEqual(CaptureAction.enabled(recording: false, in: save), [.popup])
    }

    func testUniqueNamesNeverReplaceFiles() throws {
        let folder = try folder()
        XCTAssertEqual(CaptureFolder.uniqueURL(in: folder, name: "Glint 2026-10-23 at 10.00.00", pathExtension: "png").lastPathComponent,
                       "Glint 2026-10-23 at 10.00.00.png")
        try Data("first".utf8).write(to: folder.appendingPathComponent("Shot.png"))
        try Data("second".utf8).write(to: folder.appendingPathComponent("Shot 2.png"))
        XCTAssertEqual(CaptureFolder.uniqueURL(in: folder, name: "Shot", pathExtension: "png").lastPathComponent, "Shot 3.png")
        XCTAssertEqual(CaptureFolder.uniqueURL(in: folder, name: "Shot", pathExtension: "jpeg").lastPathComponent, "Shot.jpeg")

        let source = try png(in: try self.folder())
        let saved = try CaptureFolder.saveImage(source, named: "Shot", format: .png, in: folder)
        XCTAssertEqual(saved.lastPathComponent, "Shot 3.png")
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: source))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Shot.png"), encoding: .utf8), "first")
        XCTAssertThrowsError(try CaptureFolder.saveImage(source, named: "Shot", format: .png, in: folder.appendingPathComponent("missing")))
    }

    func testSavedFormatsAndOpaqueJPEG() throws {
        let folder = try folder()
        let source = try png(in: try self.folder())
        for format in ScreenshotFormat.allCases {
            let url = try CaptureFolder.saveImage(source, named: "Shot", format: format, in: folder)
            XCTAssertEqual(UTType(filenameExtension: url.pathExtension), format.type)
            let image = try ImageFile.read(url)
            XCTAssertEqual(image.width, 8)
            XCTAssertEqual(image.height, 6)
        }
        let flattened = CaptureFolder.opaque(try ImageFile.read(source))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(flattened, in: CGRect(x: -7, y: 0, width: 8, height: 6))
        XCTAssertEqual(pixel, [255, 255, 255, 255])
    }

    func testDefaultBackgroundWrapsCaptureInProject() throws {
        let folder = try folder()
        let source = try png(in: folder)
        var background = ImageBackground()
        background.enabled = true
        background.padding = 10
        let project = try EditorDefaults.styledProject(source, background: background, presetDirectory: folder)
        defer { try? FileManager.default.removeItem(at: project) }
        XCTAssertEqual(project.pathExtension, "glint")
        let contents = try ImageProject.load(project)
        XCTAssertEqual(contents.document.background, background)
        XCTAssertEqual(contents.document.sourceSize, CGSize(width: 8, height: 6))
        XCTAssertEqual(try ImageRenderer.render(contents).width, 28)

        background.imageID = UUID()
        XCTAssertThrowsError(try EditorDefaults.styledProject(source, background: background, presetDirectory: folder))
    }

    func testDefaultPresetMustStillExist() throws {
        let standard = UserDefaults.standard
        let keys = ["imageBackgroundPresets", "defaultBackgroundPreset"]
        let saved = keys.map { standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) } }
        var preset = ImageBackground()
        preset.enabled = true
        standard.set(try JSONEncoder().encode(preset), forKey: "defaultBackgroundPreset")
        standard.set(try JSONEncoder().encode([ImageBackground]()), forKey: "imageBackgroundPresets")
        XCTAssertNil(EditorDefaults.backgroundPreset)
        standard.set(try JSONEncoder().encode([preset]), forKey: "imageBackgroundPresets")
        XCTAssertEqual(EditorDefaults.backgroundPreset, preset)
    }

    @MainActor
    func testPopupScaleChangesHowManyCardsFit() {
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 1000, footer: true, scale: 1), 4)
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 1000, footer: true, scale: 1.5), 4)
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 600, footer: true, scale: 1.5), 2)
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 600, footer: true, scale: 0.75), 4)
        // 14 * 2 inset, two 201 point cards and the footer stay inside 600 points
        XCTAssertLessThanOrEqual(14 * 2 + 2 * 201 + 10 + 24 + 10, 600)
    }

    func testFolderDestinationsAreReservedUntilWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try CaptureFolder.destination(in: folder, name: "Shot", pathExtension: "mp4")
        let second = try CaptureFolder.destination(in: folder, name: "Shot", pathExtension: "mp4")
        XCTAssertEqual(first.lastPathComponent, "Shot.mp4")
        XCTAssertEqual(second.lastPathComponent, "Shot 2.mp4")
        CaptureFolder.release(first)
        CaptureFolder.release(second)
        XCTAssertEqual(try CaptureFolder.destination(in: folder, name: "Shot", pathExtension: "mp4").lastPathComponent, "Shot.mp4")
        CaptureFolder.release(folder.appendingPathComponent("Shot.mp4"))
    }

    @MainActor
    func testAnimatedGIFsKeepTheirFormatWhenSaved() {
        let gif = CaptureItem(id: UUID(), createdAt: Date(), title: "Demo", filename: "Demo.gif", kind: .image)
        XCTAssertNil(AppDelegate.screenshotFormat(for: gif, source: URL(fileURLWithPath: "/tmp/Demo.gif")))
        let still = CaptureItem(id: UUID(), createdAt: Date(), title: "Shot", filename: "Shot.png", kind: .image)
        XCTAssertNotNil(AppDelegate.screenshotFormat(for: still, source: URL(fileURLWithPath: "/tmp/Shot.png")))
    }
}
