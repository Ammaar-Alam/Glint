import AppKit
import XCTest
@testable import Glint

// sliders in the editor bar must receive their own drags instead of moving the window
@MainActor
final class EditorHitTests: XCTestCase {
    func testTopBarSliderReceivesMouseDown() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        try ImageFile.write(try XCTUnwrap(context.makeImage()), to: url)
        let editor = ImageEditorWindowController(url: url) { _ in }
        defer { editor.model.shutdown(); editor.window?.orderOut(nil) }
        editor.showWindow(nil)
        for _ in 0..<50 where editor.model.document == nil { try await Task.sleep(for: .milliseconds(50)) }
        editor.model.tool = .pixelate
        try await Task.sleep(for: .milliseconds(400))
        let window = try XCTUnwrap(editor.window)
        let frame = try XCTUnwrap(window.contentView?.superview)
        // the middle of the top bar holds the tools and the strength slider
        let point = frame.convert(NSPoint(x: window.frame.width / 2 + 120, y: window.frame.height - 26), from: nil)
        let hit = try XCTUnwrap(frame.hitTest(point))
        XCTAssertTrue(hit.isDescendant(of: window.contentView!), "a press in the top bar lands in \(type(of: hit))")
        XCTAssertFalse(hit.mouseDownCanMoveWindow, "\(type(of: hit)) lets a press move the window")
    }
}
