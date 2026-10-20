import XCTest
import CoreGraphics
import ImageIO
@testable import Clipt

final class ImageEditorTests: XCTestCase {
    func testCropRotateFlipGeometryRoundTrips() throws {
        var document = ImageDocument(size: CGSize(width: 100, height: 60))
        document.cropRect = CGRect(x: 10, y: 5, width: 60, height: 40)
        document.quarterTurns = 1
        document.flipHorizontal = true
        document.background.enabled = true
        document.background.padding = 12
        document.outputScale = 2
        _ = try document.validated()

        XCTAssertEqual(document.contentSize, CGSize(width: 40, height: 60))
        XCTAssertEqual(document.outputSize, CGSize(width: 128, height: 168))
        let first = CGPoint(x: 10, y: 5).applying(document.originalToCanvas)
        XCTAssertEqual(first.x, 12, accuracy: 0.001)
        XCTAssertEqual(first.y, 12, accuracy: 0.001)
        for point in [CGPoint(x: 22, y: 18), CGPoint(x: 70, y: 45)] {
            let restored = point.applying(document.originalToCanvas).applying(document.originalToCanvas.inverted())
            XCTAssertEqual(restored.x, point.x, accuracy: 0.001)
            XCTAssertEqual(restored.y, point.y, accuracy: 0.001)
        }
    }

    func testRasterOrientationAndSolidRedaction() throws {
        let source = try fixture(width: 20, height: 12)
        XCTAssertEqual(pixel(source, x: 2, y: 1), [20, 10, 128, 255])
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        let original = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [:]))
        XCTAssertEqual(pixel(original, x: 2, y: 1), pixel(source, x: 2, y: 1))
        XCTAssertEqual(pixel(original, x: 17, y: 10), pixel(source, x: 17, y: 10))

        var redaction = ImageAnnotation(tool: .redact, rect: CGRect(x: 4, y: 3, width: 8, height: 5))
        redaction.color = AnnotationColor(red: 0, green: 0, blue: 0, alpha: 0.1)
        document.annotations = [redaction]
        let rendered = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [:]))
        for y in 3..<8 {
            for x in 4..<12 { XCTAssertEqual(pixel(rendered, x: x, y: y), [0, 0, 0, 255]) }
        }
        XCTAssertEqual(pixel(rendered, x: 3, y: 3), pixel(source, x: 3, y: 3))
        XCTAssertEqual(pixel(rendered, x: 12, y: 7), pixel(source, x: 12, y: 7))
    }

    func testCroppedClockwiseRotationMapsPixels() throws {
        let source = try fixture(width: 20, height: 12)
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.cropRect = CGRect(x: 4, y: 2, width: 8, height: 6)
        document.quarterTurns = 1
        let rendered = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [:]))
        XCTAssertEqual(rendered.width, 6)
        XCTAssertEqual(rendered.height, 8)
        XCTAssertEqual(pixel(rendered, x: 5, y: 0), pixel(source, x: 4, y: 2))
        XCTAssertEqual(pixel(rendered, x: 0, y: 7), pixel(source, x: 11, y: 7))
    }

    func testProjectRoundTripAndAtomicOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.clipt")
        let source = try fixture(width: 20, height: 12)
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        var annotation = ImageAnnotation(tool: .image, rect: CGRect(x: 2, y: 2, width: 5, height: 4))
        let imageID = UUID()
        annotation.imageID = imageID
        document.annotations = [annotation]
        let inserted = try fixture(width: 5, height: 4)
        try ImageProject.save(ImageProjectContents(document: document, source: source, insertedImages: [imageID: inserted]), to: url)
        var loaded = try ImageProject.load(url)
        XCTAssertEqual(loaded.document, document)
        XCTAssertEqual(loaded.insertedImages[imageID]?.width, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("preview.png").path))

        document.quarterTurns = 2
        try ImageProject.save(ImageProjectContents(document: document, source: source, insertedImages: [imageID: inserted]), to: url)
        loaded = try ImageProject.load(url)
        XCTAssertEqual(loaded.document.quarterTurns, 2)
        XCTAssertEqual(pixel(loaded.source, x: 2, y: 1), pixel(source, x: 2, y: 1))
    }

    func testProjectRejectsInvalidGeometryAndEscapingAsset() throws {
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.cropRect = CGRect(x: 0, y: 0, width: 0, height: 12)
        XCTAssertThrowsError(try document.validated())
        document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.outputScale = .infinity
        XCTAssertThrowsError(try document.validated())

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Untrusted.clipt")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        document = ImageDocument(size: CGSize(width: 20, height: 12))
        try JSONEncoder().encode(document).write(to: package.appendingPathComponent("document.json"))
        let external = root.appendingPathComponent("private.png")
        try ImageFile.write(fixture(width: 20, height: 12), to: external)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("original.png"), withDestinationURL: external)
        XCTAssertThrowsError(try ImageProject.load(package))
    }

    func testAnnotationResizePreservesLineGeometry() {
        var arrow = ImageAnnotation(tool: .arrow, rect: .zero)
        arrow.points = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)]
        arrow.resize(from: arrow.bounds, to: CGRect(x: 50, y: 50, width: 40, height: 20))
        XCTAssertEqual(arrow.points, [CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 70)])
        arrow.move(dx: -10, dy: 5)
        XCTAssertEqual(arrow.points.last, CGPoint(x: 80, y: 75))
    }

    func testCanvasExpansionPreservesOriginalAndInsertedPixels() throws {
        let source = try fixture(width: 20, height: 12)
        let inserted = try fixture(width: 10, height: 12)
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.cropRect = CGRect(x: -5, y: 0, width: 40, height: 12)
        let id = UUID()
        var annotation = ImageAnnotation(tool: .image, rect: CGRect(x: 20, y: 0, width: 10, height: 12))
        annotation.imageID = id
        document.annotations = [annotation]
        let rendered = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [id: inserted]))
        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(pixel(rendered, x: 2, y: 2), [0, 0, 0, 0])
        XCTAssertEqual(pixel(rendered, x: 7, y: 2), pixel(source, x: 2, y: 2))
        XCTAssertEqual(pixel(rendered, x: 28, y: 2), pixel(inserted, x: 3, y: 2))
    }

    func testBackgroundImageAndContentAlignment() throws {
        let source = try fixture(width: 20, height: 12)
        let background = try fixture(width: 10, height: 10)
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.background.enabled = true
        document.background.padding = 5
        document.background.shadow = 0
        document.background.cornerRadius = 0
        document.background.contentOffset = CGPoint(x: -5, y: -5)
        let id = UUID()
        document.background.imageID = id
        let rendered = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [id: background]))
        XCTAssertEqual(document.contentOrigin, .zero)
        XCTAssertEqual(rendered.width, 30)
        XCTAssertEqual(rendered.height, 22)
        XCTAssertEqual(pixel(rendered, x: 2, y: 2), pixel(source, x: 2, y: 2))
        XCTAssertEqual(pixel(rendered, x: 29, y: 21).last, 255)
    }

    func testSmartHighlightMergesWordsWithoutJoiningLines() {
        let words = [CGRect(x: 10, y: 10, width: 20, height: 10), CGRect(x: 35, y: 10, width: 20, height: 10),
                     CGRect(x: 10, y: 30, width: 20, height: 10)]
        let highlights = ImageTextLayout.highlights(intersecting: CGRect(x: 15, y: 12, width: 40, height: 24), words: words)
        XCTAssertEqual(highlights, [CGRect(x: 8, y: 8, width: 49, height: 14), CGRect(x: 8, y: 28, width: 24, height: 14)])
        XCTAssertTrue(ImageTextLayout.highlights(intersecting: CGRect(x: 100, y: 100, width: 20, height: 20), words: words).isEmpty)
    }

    func testInsetAndTransparentImageDoNotPaintBlackBoxes() throws {
        let source = try fixture(width: 20, height: 12)
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.background.enabled = true
        document.background.gradient = false
        document.background.color = AnnotationColor(red: 0, green: 0, blue: 1)
        document.background.padding = 3
        document.background.inset = 2
        document.background.insetColor = .white
        document.background.cornerRadius = 0
        document.background.shadow = 0
        let bordered = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [:]))
        XCTAssertEqual(pixel(bordered, x: 1, y: 1), [0, 0, 255, 255])
        XCTAssertEqual(pixel(bordered, x: 10, y: 3), [255, 255, 255, 255])
        XCTAssertEqual(pixel(bordered, x: 5, y: 5), pixel(source, x: 0, y: 0))
        document.background.inset = 0
        document.background.shadow = 10
        let clear = try XCTUnwrap(ImageRenderer.bitmap(size: CGSize(width: 20, height: 12), scale: 1).makeImage())
        let rendered = try ImageRenderer.render(ImageProjectContents(document: document, source: clear, insertedImages: [:]))
        XCTAssertEqual(pixel(rendered, x: 10, y: 8), [0, 0, 255, 255])
    }

    func testImportHonorsEXIFOrientation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try fixture(width: 20, height: 12), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let contents = try ImageProject.load(url)
        XCTAssertEqual(contents.document.sourceSize, CGSize(width: 12, height: 20))
    }

    func testCountersStayAboveOtherAnnotations() throws {
        let source = try fixture(width: 20, height: 12)
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        var counter = ImageAnnotation(tool: .counter, rect: CGRect(x: 4, y: 2, width: 8, height: 8))
        counter.fontSize = 6
        var covering = ImageAnnotation(tool: .rectangle, rect: CGRect(x: 0, y: 0, width: 20, height: 12))
        covering.color = .ink
        covering.filled = true
        document.annotations = [counter, covering]
        let rendered = try ImageRenderer.render(ImageProjectContents(document: document, source: source, insertedImages: [:]))
        XCTAssertGreaterThan(pixel(rendered, x: 5, y: 5)[0], 200)
        XCTAssertLessThan(pixel(rendered, x: 5, y: 5)[1], 120)
    }

    @MainActor
    func testUndoAndRedoRestoreEditableDocument() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageFile.write(fixture(width: 20, height: 12), to: url)
        let model = ImageEditorModel(url: url, onExport: { _ in })
        defer { model.shutdown() }
        for _ in 0..<100 where model.document == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.document)
        model.undoManager.groupsByEvent = false
        model.undoManager.beginUndoGrouping()
        model.mutate("Redact") { document in
            document.annotations.append(ImageAnnotation(tool: .redact, rect: CGRect(x: 2, y: 2, width: 8, height: 6)))
        }
        model.undoManager.endUndoGrouping()
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.document?.annotations.count, 1)
        model.undoManager.undo()
        XCTAssertEqual(model.document?.annotations.count, 0)
        XCTAssertFalse(model.hasUnsavedChanges)
        model.undoManager.redo()
        XCTAssertEqual(model.document?.annotations.count, 1)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    @MainActor
    func testPreviewCoalescingFinishesWithNewestGesture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageFile.write(fixture(width: 20, height: 12), to: url)
        let model = ImageEditorModel(url: url, onExport: { _ in })
        defer { model.shutdown() }
        for _ in 0..<100 where model.document == nil { try await Task.sleep(for: .milliseconds(20)) }
        var document = try XCTUnwrap(model.document)
        for index in 0..<100 {
            var annotation = ImageAnnotation(tool: .redact, rect: CGRect(x: 2, y: 2, width: 8, height: 6))
            annotation.color = AnnotationColor(red: 0, green: Double(index) / 99, blue: 0)
            document.annotations = [annotation]
            model.updateGesture(document)
        }
        for _ in 0..<100 {
            if let preview = model.preview, pixel(preview, x: 4, y: 4) == [0, 255, 0, 255] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pixel(try XCTUnwrap(model.preview), x: 4, y: 4), [0, 255, 0, 255])
        model.shutdown()
        model.refreshPreview()
        await Task.yield()
        XCTAssertNil(model.preview)
        XCTAssertNil(model.document)
    }

    @MainActor
    func testClosingDuringLoadDoesNotRetainEditorModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageFile.write(fixture(width: 20, height: 12), to: url)
        var model: ImageEditorModel? = ImageEditorModel(url: url, onExport: { _ in })
        weak var weakModel = model
        model?.shutdown()
        model = nil
        XCTAssertNil(weakModel)
        weakModel = nil
    }

    func testProjectChecksAssetCountBeforeOpeningAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).clipt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        document.annotations = (0...ImageProject.maximumAssetCount).map { _ in
            var annotation = ImageAnnotation(tool: .image, rect: CGRect(x: 0, y: 0, width: 2, height: 2))
            annotation.imageID = UUID()
            return annotation
        }
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("document.json"))
        XCTAssertThrowsError(try ImageProject.load(root)) { error in
            XCTAssertEqual(error.localizedDescription, "This project contains too many image assets.")
        }
    }

    func testProjectChecksAggregatePixelBudgetBeforeDecodingAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).clipt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = ImageDocument(size: CGSize(width: 20, height: 12))
        var annotation = ImageAnnotation(tool: .image, rect: CGRect(x: 0, y: 0, width: 2, height: 2))
        let imageID = UUID(), backgroundID = UUID()
        annotation.imageID = imageID
        document.annotations = [annotation]
        document.background.imageID = backgroundID
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("document.json"))
        try ImageFile.write(fixture(width: 20, height: 12), to: root.appendingPathComponent("original.png"))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try fixture(width: 20, height: 12), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var bytes = [UInt8](data as Data)
        let start = try XCTUnwrap((0..<bytes.count - 8).first { bytes[$0] == 0xff && [0xc0, 0xc2].contains(bytes[$0 + 1]) })
        bytes[start + 5] = UInt8(10_000 >> 8); bytes[start + 6] = UInt8(10_000 & 0xff)
        bytes[start + 7] = UInt8(8_000 >> 8); bytes[start + 8] = UInt8(8_000 & 0xff)
        for id in [imageID, backgroundID] {
            try Data(bytes).write(to: root.appendingPathComponent("images/\(id.uuidString).png"))
        }
        XCTAssertThrowsError(try ImageProject.load(root)) { error in
            XCTAssertEqual(error.localizedDescription, "This project contains too many large images.")
        }
    }

    private func fixture(width: Int, height: Int) throws -> CGImage {
        var data = [UInt8]()
        for y in 0..<height {
            for x in 0..<width { data += [UInt8(x * 10), UInt8(y * 10), 128, 255] }
        }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let offset = y * image.width * 4 + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
