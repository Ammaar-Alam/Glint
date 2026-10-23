import AppKit
import Carbon

@MainActor
final class PinnedImagePanel: NSPanel, NSWindowDelegate {
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?
    private let image: NSImage
    private let imageView = PinnedImageView()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(image: NSImage) {
        self.image = image
        let scale = min(1, 500 / max(image.size.width, image.size.height))
        let size = NSSize(width: max(80, image.size.width * scale), height: max(60, image.size.height * scale))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        title = "Pinned Capture"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 80, height: 60)
        contentAspectRatio = image.size
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.onOpacity = { [weak self] delta in
            guard let self else { return }
            self.alphaValue = min(1, max(0.15, self.alphaValue + delta))
        }
        contentView = imageView
        imageView.menu = NSMenu()
        let copy = HandlerMenuItem("Copy") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([self.image])
        }
        imageView.menu?.addItem(copy)
        imageView.menu?.addItem(HandlerMenuItem("Edit") { [weak self] in self?.onEdit?() })
        imageView.menu?.addItem(HandlerMenuItem("Lock Position") { [weak self] in self?.ignoresMouseEvents = true })
        imageView.menu?.addItem(HandlerMenuItem("Reset Opacity") { [weak self] in self?.alphaValue = 1 })
        imageView.menu?.addItem(.separator())
        imageView.menu?.addItem(HandlerMenuItem("Close") { [weak self] in self?.close() })
        delegate = self
        center()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    override func keyDown(with event: NSEvent) {
        var origin = frame.origin
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: close()
        case 123: origin.x -= step; setFrameOrigin(origin)
        case 124: origin.x += step; setFrameOrigin(origin)
        case 125: origin.y -= step; setFrameOrigin(origin)
        case 126: origin.y += step; setFrameOrigin(origin)
        default:
            if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" { resize(by: 1.1) }
            else if event.charactersIgnoringModifiers == "-" { resize(by: 1 / 1.1) }
            else { super.keyDown(with: event) }
        }
    }

    private func resize(by factor: CGFloat) {
        let size = NSSize(width: max(80, frame.width * factor), height: max(60, frame.height * factor))
        setFrame(NSRect(origin: frame.origin, size: size), display: true)
    }
}

@MainActor
private final class PinnedImageView: NSImageView {
    var onOpacity: ((CGFloat) -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func scrollWheel(with event: NSEvent) { onOpacity?(event.scrollingDeltaY * 0.005) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { window?.close() } }
}

@MainActor
final class HandlerMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: key)
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    func show(_ shortcut: KeyboardShortcut?) {
        guard let shortcut else { return }
        keyEquivalent = shortcut.key.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        keyEquivalentModifierMask = mask
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func invoke() { handler() }
}
