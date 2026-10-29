import XCTest
import CoreGraphics
import CoreImage
@testable import Glint

final class CaptureTests: XCTestCase {
    func testDisplayCoordinatesRoundTripAcrossDisplays() {
        let primaryHeight: CGFloat = 900
        let rect = CGRect(x: -1600, y: 250, width: 600, height: 420)
        let quartz = CaptureGeometry.quartzRect(fromCocoa: rect, primaryHeight: primaryHeight)
        XCTAssertEqual(quartz, CGRect(x: -1600, y: 230, width: 600, height: 420))
        XCTAssertEqual(CaptureGeometry.cocoaRect(fromQuartz: quartz, primaryHeight: primaryHeight), rect)
        XCTAssertEqual(CaptureGeometry.displayLocalRect(quartz, displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
                       CGRect(x: 320, y: 230, width: 600, height: 420))
        XCTAssertEqual(CaptureGeometry.rectangle(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 10, y: 20), square: true),
                       CGRect(x: 40, y: 20, width: 40, height: 40))
        XCTAssertEqual(CaptureGeometry.rectangle(from: .zero, to: CGPoint(x: 200, y: 90), ratio: 16.0 / 9),
                       CGRect(x: 0, y: 0, width: 160, height: 90))
    }

    func testSelectionHandlesMoveResizeAndKeepRatio() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(CaptureGeometry.adjusted(rect, edges: (0, 0), by: CGVector(dx: 10, dy: -5)), CGRect(x: 110, y: 95, width: 200, height: 100))
        XCTAssertEqual(CaptureGeometry.adjusted(rect, edges: (1, 1), by: CGVector(dx: 50, dy: 20)), CGRect(x: 100, y: 100, width: 250, height: 120))
        XCTAssertEqual(CaptureGeometry.adjusted(rect, edges: (-1, 0), by: CGVector(dx: 250, dy: 0)), CGRect(x: 300, y: 100, width: 50, height: 100))
        XCTAssertEqual(CaptureGeometry.adjusted(rect, edges: (1, 0), by: CGVector(dx: 100, dy: 0), ratio: 2), CGRect(x: 100, y: 50, width: 300, height: 150))
        XCTAssertEqual(CaptureGeometry.adjusted(rect, edges: (0, 1), by: CGVector(dx: 0, dy: 50), ratio: 2), CGRect(x: 100, y: 100, width: 300, height: 150))
    }

    func testRecordingOptionsKeepTheirStoredKeys() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Glint-options-\(UUID().uuidString)"))
        XCTAssertEqual(RecordingOptions.saved(defaults).countdown, 3)
        var options = RecordingOptions()
        options.mode = .window; options.format = .gif; options.countdown = 5; options.capturesMicrophone = true; options.framesPerSecond = 60
        options.save(defaults)
        XCTAssertEqual(defaults.string(forKey: "record.mode"), "Window")
        XCTAssertEqual(defaults.integer(forKey: "record.countdown"), 5)
        XCTAssertTrue(defaults.bool(forKey: "record.microphone"))
        let loaded = RecordingOptions.saved(defaults)
        XCTAssertEqual(loaded.mode, .window)
        XCTAssertEqual(loaded.framesPerSecond, 60)
        XCTAssertEqual(loaded.format, .video)
    }

    func testVerticalStitchPreservesPixelsAndDoesNotAppendUnchangedFrame() throws {
        let page = try pattern(width: 220, height: 950)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 220, height: 420)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 120, width: 220, height: 420)))
        let third = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 184, width: 220, height: 420)))
        var stitcher = try ScrollStitcher(image: first)
        XCTAssertEqual(try stitcher.append(first), .unchanged)
        XCTAssertEqual(try stitcher.append(second), .forward(120))
        XCTAssertEqual(try stitcher.append(third), .forward(64))
        XCTAssertEqual(try stitcher.append(second), .backward)
        XCTAssertEqual(stitcher.frameCount, 3)
        XCTAssertEqual(stitcher.length, 604)
        let output = try stitcher.render()
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 220, height: 604)))
        XCTAssertEqual(try pixels(output), try pixels(expected))
    }

    func testRepeatedRowsDoNotInventAnOverlap() throws {
        let width = 120
        let height = 400
        func bands(offset: Int) throws -> CGImage {
            let values = (0..<(width * height)).map { index in UInt8(((index / width + offset) / 8) % 2 == 0 ? 30 : 230) }
            return try grayImage(values, width: width, height: height)
        }
        let first = try ScrollRaster(image: bands(offset: 0))
        XCTAssertEqual(first.match(try ScrollRaster(image: bands(offset: 8))), .uncertain)
    }

    func testAutomaticScrollStopsAtEndAndDoesNotRestartAfterStopping() {
        var progress = AutoScrollProgress()
        XCTAssertFalse(progress.observe(.unchanged))
        progress.didScroll()
        XCTAssertFalse(progress.observe(.unchanged))
        XCTAssertFalse(progress.observe(.forward(30)))
        XCTAssertEqual(progress.unchangedFrames, 0)
        XCTAssertFalse(progress.observe(.unchanged))
        XCTAssertFalse(progress.observe(.unchanged))
        XCTAssertTrue(progress.observe(.unchanged))
        XCTAssertTrue(progress.observe(.forward(30)))
        var lost = AutoScrollProgress()
        lost.didScroll()
        XCTAssertTrue(lost.observe(.uncertain))
        XCTAssertEqual(AutoScrollProgress.step(for: 900), 120)
        XCTAssertEqual(AutoScrollProgress.step(for: 300), 60)
        XCTAssertEqual(AutoScrollProgress.step(for: 2), 1)
    }

    func testFixedHeaderAndFooterAppearOnlyOnce() throws {
        let page = try pattern(width: 220, height: 900)
        func viewport(at offset: Int) throws -> CGImage {
            let image = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: offset, width: 220, height: 420)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 220, height: 420, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 220, height: 420))
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 390, width: 220, height: 30))
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 220, height: 30))
            return try XCTUnwrap(context.makeImage())
        }
        var stitcher = try ScrollStitcher(image: viewport(at: 0))
        XCTAssertEqual(try stitcher.append(viewport(at: 120)), .forward(120))
        let output = try stitcher.render()
        let stitchedMiddle = try XCTUnwrap(output.cropping(to: CGRect(x: 0, y: 30, width: 220, height: 480)))
        let expectedMiddle = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 30, width: 220, height: 480)))
        XCTAssertEqual(try pixels(stitchedMiddle), try pixels(expectedMiddle))
    }

    func testQRPayloadIsRecognizedLocally() async throws {
        // the CI virtual machine ships without Core Image's Vision plugin
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Vision is unavailable on the CI image")
        let generator = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        generator.setValue(Data("Glint capture check".utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)))
        let image = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-OCR-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageFile.write(image, to: url)
        let recognized = try await OCRService.recognize(url: url)
        XCTAssertTrue(recognized.contains("Glint capture check"))
    }

    func testFrozenSelectionUsesOriginalPixelsAndRetinaCoordinates() async throws {
        let image = try pattern(width: 440, height: 840)
        let frame = FrozenDisplayFrame(displayID: 1, frame: CGRect(x: -220, y: 100, width: 220, height: 420), image: image)
        let output = try await CaptureFrame.frozenRegion(CGRect(x: -200, y: 150, width: 30, height: 40), frames: [frame])
        XCTAssertEqual(output.width, 60)
        XCTAssertEqual(output.height, 80)
        let expected = try XCTUnwrap(image.cropping(to: CGRect(x: 40, y: 100, width: 60, height: 80)))
        XCTAssertEqual(try pixels(output), try pixels(expected))
    }

    private func pattern(width: Int, height: Int) throws -> CGImage {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let hash = (UInt64(x + 1) &* 0x9E3779B1) ^ (UInt64(y + 1) &* 0x85EBCA77)
                values[y * width + x] = UInt8(truncatingIfNeeded: (hash ^ (hash >> 13)) >> 6)
            }
        }
        return try grayImage(values, width: width, height: height)
    }

    private func grayImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
    }

    func testBarsAttachUnderTheAreaThenAboveThenInside() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bar = CGSize(width: 300, height: 70)
        // room below, centered under the area
        XCTAssertEqual(CaptureGeometry.attach(bar, to: CGRect(x: 100, y: 300, width: 400, height: 200), within: screen), CGPoint(x: 150, y: 230))
        // the area touches the bottom, the bar goes above it
        XCTAssertEqual(CaptureGeometry.attach(bar, to: CGRect(x: 100, y: 20, width: 400, height: 200), within: screen), CGPoint(x: 150, y: 220))
        // the area fills the screen, the bar sits inside its bottom
        XCTAssertEqual(CaptureGeometry.attach(bar, to: screen, within: screen), CGPoint(x: 350, y: 0))
        // an area at the edge keeps the bar on screen
        XCTAssertEqual(CaptureGeometry.attach(bar, to: CGRect(x: 900, y: 300, width: 100, height: 100), within: screen).x, 700)
    }
}
