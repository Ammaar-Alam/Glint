import AppKit
import XCTest
@testable import Glint

@MainActor
final class EditorHitTests: XCTestCase {
    private func openEditor() async throws -> ImageEditorWindowController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        try ImageFile.write(try XCTUnwrap(context.makeImage()), to: url)
        let editor = ImageEditorWindowController(url: url) { _ in }
        editor.showWindow(nil)
        for _ in 0..<50 where editor.model.document == nil { try await Task.sleep(for: .milliseconds(50)) }
        return editor
    }

    // sliders in the editor bar must receive their own drags instead of moving the window
    func testTopBarSliderReceivesMouseDown() async throws {
        let editor = try await openEditor()
        defer { editor.model.shutdown(); editor.window?.orderOut(nil) }
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

    func testPendingCropAppliesWhenLeavingTheEditor() async throws {
        let editor = try await openEditor()
        defer { editor.model.shutdown(); editor.window?.orderOut(nil) }
        editor.model.tool = .crop
        editor.model.setCropDraft(CGRect(x: 20, y: 30, width: 200, height: 100))
        editor.model.canvas?.commitEditing()
        XCTAssertEqual(editor.model.document?.cropRect, CGRect(x: 20, y: 30, width: 200, height: 100))
        XCTAssertNil(editor.model.cropDraft)
        XCTAssertTrue(editor.model.hasUnsavedChanges)
    }

    func testRatioCropShrinksEvenlyAtTheImageEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        // a square dragged from the top left corner well past the bottom
        let square = ImageCanvasView.fitCrop(CGRect(x: 0, y: 0, width: 380, height: 380), anchor: .zero, ratio: 1, widthLeads: true, bounds: bounds)
        XCTAssertEqual(square, CGRect(x: 0, y: 0, width: 300, height: 300))
        // a new 16:9 frame drawn up and left from the bottom right
        let wide = ImageCanvasView.fitCrop(CGRect(x: 0, y: 200, width: 400, height: 100), anchor: CGPoint(x: 1, y: 1), ratio: 16.0 / 9, widthLeads: true, bounds: bounds)
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(wide.maxX, 400, accuracy: 0.001)
        XCTAssertEqual(wide.maxY, 300, accuracy: 0.001)
    }

    func testSelectingAnArrowAdoptsItsStyle() async throws {
        let editor = try await openEditor()
        defer { editor.model.shutdown(); editor.window?.orderOut(nil) }
        editor.model.arrowStyle = .tapered
        let legacy = ImageAnnotation(tool: .arrow, rect: .zero, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 60)])
        editor.model.mutate("Add") { $0.annotations.append(legacy) }
        editor.model.select(legacy.id)
        XCTAssertEqual(editor.model.arrowStyle, .open)
    }

    func testStyleChangesReachTextBeingTyped() async throws {
        let editor = try await openEditor()
        defer { editor.model.shutdown(); editor.window?.orderOut(nil) }
        let window = try XCTUnwrap(editor.window)
        editor.model.tool = .text
        let canvas = try XCTUnwrap(editor.model.canvas)
        let point = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        let typing = try XCTUnwrap(window.firstResponder as? NSTextView)
        typing.insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        typing.selectAll(nil)
        editor.model.changeStyle { $0.fontSize = 60; $0.italic = true; $0.bold = false }
        XCTAssertEqual(typing.font?.pointSize, 60)
        XCTAssertTrue(typing.font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        canvas.commitEditing()
        let text = try XCTUnwrap(editor.model.document?.annotations.first { $0.tool == .text })
        XCTAssertEqual(text.text, "Hello")
        XCTAssertEqual(text.fontSize, 60)
        XCTAssertTrue(text.italic)
        XCTAssertFalse(text.bold)
    }
}
