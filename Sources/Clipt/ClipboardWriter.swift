import AppKit

@MainActor
final class ClipboardWriter {
    struct Request: Sendable {
        fileprivate let generation: Int
        fileprivate let changeCount: Int
    }

    static let general = ClipboardWriter(pasteboard: .general)
    private let pasteboard: NSPasteboard
    private var generation = 0

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    func begin() -> Request {
        generation += 1
        return Request(generation: generation, changeCount: pasteboard.changeCount)
    }

    @discardableResult
    func commit(_ request: Request, writing: (NSPasteboard) throws -> Void) rethrows -> Bool {
        guard request.generation == generation, request.changeCount == pasteboard.changeCount else { return false }
        pasteboard.clearContents()
        try writing(pasteboard)
        return true
    }
}
