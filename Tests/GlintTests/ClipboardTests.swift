import AppKit
import XCTest
@testable import Glint

final class ClipboardTests: XCTestCase {
    @MainActor
    func testOlderEditorCopyCannotDefeatNewerPendingShelfCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: pasteboard)
        let editor = writer.begin()
        let shelf = writer.begin()
        XCTAssertFalse(writer.commit(editor) { _ = $0.setString("older editor result", forType: .string) })
        XCTAssertTrue(writer.commit(shelf) { _ = $0.setString("newer shelf result", forType: .string) })
        XCTAssertEqual(pasteboard.string(forType: .string), "newer shelf result")
    }

    @MainActor
    func testLateOlderResultCannotReplaceCompletedNewerCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: pasteboard)
        let first = writer.begin()
        let second = writer.begin()
        XCTAssertTrue(writer.commit(second) { _ = $0.setString("second", forType: .string) })
        XCTAssertFalse(writer.commit(first) { _ = $0.setString("first", forType: .string) })
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
    }

    @MainActor
    func testExternalClipboardChangePreventsPendingWriteAndCut() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: pasteboard)
        let request = writer.begin()
        pasteboard.clearContents()
        pasteboard.setString("external copy", forType: .string)
        var wrote = false
        let committed = writer.commit(request) { _ in wrote = true }
        XCTAssertFalse(committed)
        XCTAssertFalse(wrote)
        XCTAssertEqual(pasteboard.string(forType: .string), "external copy")
    }
}
