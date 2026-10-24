import XCTest
import CoreGraphics
@testable import Glint

final class LibraryTests: XCTestCase {
    func testVideoProjectImportPublishesAfterComposedThumbnail() async throws {
        let root = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.glintvideo", isDirectory: false)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try await VideoTests.movie(at: source.appendingPathComponent("screen.mov"))
        var project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        project.edits.maximumDimension = 320
        try project.save(to: source)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let storage = CaptureStorage(root: library)
        let item = try await storage.ingest(source, title: "Recording")
        XCTAssertEqual(item.kind, .videoProject)
        let items = try await storage.load()
        XCTAssertEqual(items.map(\.id), [item.id])
        XCTAssertEqual(try ImageFile.read(item.thumbnail(in: library)).width, 320)
        XCTAssertEqual(try VideoProject.load(from: item.url(in: library)), project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("screen.mov").path))
    }

    func testCapturePersistsBeforeBecomingVisibleAndBadInputDoesNotCreateItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-library-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captures = root.appendingPathComponent("captures")
        let storage = CaptureStorage(root: captures)
        let source = root.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        try ImageFile.write(try XCTUnwrap(context.makeImage()), to: source)
        let item = try await storage.ingest(source, title: "Fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url(in: captures).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.thumbnail(in: captures).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let loaded = try await storage.load()
        XCTAssertEqual(loaded, [item])

        let bad = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: bad)
        do { _ = try await storage.ingest(bad, title: "Broken"); XCTFail("Invalid image accepted") }
        catch {}
        let afterFailure = try await storage.load()
        XCTAssertEqual(afterFailure, [item])
        let directories = try FileManager.default.contentsOfDirectory(atPath: captures.path)
        XCTAssertEqual(directories, [item.id.uuidString])
    }

    func testShelfDismissalDoesNotLoseOtherCapturesAndReopenDoesNotDuplicate() {
        let first = UUID(), second = UUID(), third = UUID()
        var shelf = ShelfState()
        shelf.insert(first); shelf.insert(second); shelf.insert(third)
        shelf.dismiss(second)
        XCTAssertEqual(shelf.ids, [third, first])
        shelf.reopen(); shelf.reopen()
        XCTAssertEqual(shelf.ids, [second, third, first])
        shelf.dismissAll()
        XCTAssertTrue(shelf.ids.isEmpty)
        shelf.reopen()
        XCTAssertEqual(shelf.ids, [second])
    }

    func testCardPresentedAfterEditorOpensIsTucked() {
        let id = UUID()
        var shelf = ShelfState()
        shelf.setEditing(id, true)
        XCTAssertTrue(shelf.tucked.isEmpty)
        shelf.insert(id)
        XCTAssertEqual(shelf.tucked, [id])
        shelf.dismiss(id)
        shelf.reopen()
        XCTAssertEqual(shelf.tucked, [id])
        shelf.setEditing(id, false)
        XCTAssertTrue(shelf.tucked.isEmpty)
    }

    func testEditReplacesPendingOriginalWithoutAddingAnotherCard() {
        let original = UUID(), edited = UUID()
        var shelf = ShelfState()
        shelf.setEditing(original, true)
        shelf.insert(original, deferred: true)
        shelf.replace(original, with: edited)
        XCTAssertEqual(shelf.pending, [edited])
        XCTAssertTrue(shelf.ids.isEmpty)
        XCTAssertEqual(shelf.editing, [edited])
        for id in shelf.takePending() { shelf.insert(id) }
        XCTAssertEqual(shelf.ids, [edited])
        XCTAssertEqual(shelf.tucked, [edited])
    }

    func testAfterCaptureEditorThenPopupEndsTucked() {
        XCTAssertEqual(CaptureAction.ordered(Set(CaptureAction.allCases)), [.copy, .save, .editor, .popup])
        XCTAssertEqual(CaptureAction.ordered([]), [])
        let id = UUID()
        var shelf = ShelfState()
        for action in CaptureAction.ordered([.editor, .popup]) {
            switch action {
            case .editor: shelf.setEditing(id, true)
            case .popup: shelf.insert(id)
            default: XCTFail("unexpected action")
            }
        }
        XCTAssertEqual(shelf.tucked, [id])
    }

    func testEditedCaptureTakesItsOriginalsPlace() {
        let first = UUID(), second = UUID(), edited = UUID(), gone = UUID(), fresh = UUID()
        var shelf = ShelfState()
        shelf.insert(first); shelf.insert(second)
        shelf.replace(first, with: edited)
        XCTAssertEqual(shelf.ids, [second, edited])
        // an original dismissed meanwhile lets the edit arrive as a new card
        shelf.replace(gone, with: fresh)
        XCTAssertEqual(shelf.ids, [fresh, second, edited])
    }

    func testExportReplacesFileAtomicallyAndFailureKeepsExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("saved.png")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        try ExportFile.copy(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertThrowsError(try ExportFile.copy(root.appendingPathComponent("missing.png"), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
    }

    func testCaptureNamesAndMetadataCannotEscapeTheirDirectory() {
        XCTAssertEqual(CaptureNaming.name(template: "../../private:shot"), "..-..-private-shot")
        XCTAssertFalse(CaptureNaming.name(template: "").isEmpty)
        let valid = CaptureItem(id: UUID(), createdAt: Date(), title: "A", filename: "capture.png", kind: .image)
        XCTAssertTrue(valid.hasSafeFilename)
        var invalid = valid
        invalid.filename = "../outside.png"
        XCTAssertFalse(invalid.hasSafeFilename)
    }

    func testTemporaryCleanupOnlyRemovesOwnedFiles() throws {
        let owned = ImageFile.temporaryURL()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let imported = outside.appendingPathComponent(owned.lastPathComponent)
        try Data("owned".utf8).write(to: owned)
        try Data("imported".utf8).write(to: imported)
        defer { try? FileManager.default.removeItem(at: owned); try? FileManager.default.removeItem(at: outside) }
        try ImageFile.removeTemporary(imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        try ImageFile.removeTemporary(owned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    @MainActor
    func testProjectsShareFullResolutionFlattenedImagesAndRefreshWithoutDuplicating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-share-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("private.glint")
        let context = try XCTUnwrap(CGContext(data: nil, width: 3200, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3200, height: 80))
        let source = try XCTUnwrap(context.makeImage())
        var document = ImageDocument(size: CGSize(width: 3200, height: 80))
        var redaction = ImageAnnotation(tool: .redact, rect: CGRect(x: 30, y: 20, width: 100, height: 40))
        redaction.color = AnnotationColor(red: 0, green: 0, blue: 0)
        document.annotations = [redaction]
        var contents = ImageProjectContents(document: document, source: source, insertedImages: [:])
        try ImageProject.save(contents, to: projectURL)
        let library = CaptureLibrary(root: root.appendingPathComponent("library"))
        let item = try await library.ingest(projectURL)
        let share = try XCTUnwrap(item.shareURL(in: library.root))
        XCTAssertEqual(share.pathExtension, "png")
        XCTAssertNotEqual(share, item.url(in: library.root))
        let flattened = try ImageFile.read(share)
        XCTAssertEqual(flattened.width, 3200)
        XCTAssertEqual(flattened.height, 80)
        let crop = try XCTUnwrap(flattened.cropping(to: CGRect(x: 40, y: 30, width: 1, height: 1)))
        let pixelContext = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixelContext.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(pixelContext.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0, 0, 0, 255])

        document.quarterTurns = 1
        contents = ImageProjectContents(document: document, source: source, insertedImages: [:])
        try ImageProject.save(contents, to: item.url(in: library.root))
        let refreshed = try await library.ingest(item.url(in: library.root))
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(refreshed.id, item.id)
        XCTAssertNotNil(refreshed.modifiedAt)
        XCTAssertEqual(try ImageFile.read(share).height, 3200)
        let reopened = try await library.ingest(projectURL)
        XCTAssertNotEqual(reopened.id, item.id)
        XCTAssertEqual(library.items.count, 2)
        XCTAssertEqual(try ImageFile.read(share).height, 3200)
        XCTAssertEqual(try ImageProject.load(item.url(in: library.root)).document.quarterTurns, 1)
        XCTAssertEqual(try ImageProject.load(reopened.url(in: library.root)).document.quarterTurns, 0)
        var video = item
        video.kind = .videoProject
        XCTAssertNil(video.shareURL(in: library.root))
    }

    @MainActor
    func testQuickAccessFitsShortScreens() {
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 1000, footer: true), 4)
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 500, footer: true), 3)
        XCTAssertEqual(QuickAccessPanel.cardsThatFit(height: 100, footer: false), 1)
        let three = 14 * 2 + 3 * 122 + 2 * 10 + 22 + 10
        XCTAssertLessThanOrEqual(three, 500)
    }
}
