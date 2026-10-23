import AppKit

struct ShelfState {
    private(set) var ids: [UUID] = []
    private(set) var lastDismissed: UUID?

    mutating func insert(_ id: UUID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
    }

    mutating func dismiss(_ id: UUID) {
        ids.removeAll { $0 == id }
        lastDismissed = id
    }

    mutating func dismissAll() {
        lastDismissed = ids.first
        ids.removeAll()
    }

    mutating func reopen() {
        if let lastDismissed { insert(lastDismissed) }
    }
}

@MainActor
final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private(set) var shelf = ShelfState()
    private var captures: [UUID: CaptureItem] = [:]
    private let library: CaptureLibrary
    private var dismissTimer: Timer?
    private var lastInteraction = Date()
    private var isDraggingCapture = false
    private var pendingCaptures: [CaptureItem] = []
    private var pendingTimer: Timer?
    private var isCaptureSuppressed = false
    var onEdit: ((CaptureItem) -> Void)?
    var onCopy: ((CaptureItem) -> Void)?
    var onSave: ((CaptureItem) -> Void)?
    var onPin: ((CaptureItem) -> Void)?
    var onHistory: (() -> Void)?

    init(library: CaptureLibrary) {
        self.library = library
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        title = "Recent Captures"
        setAccessibilityLabel("Recent Captures")
    }

    func present(_ item: CaptureItem) {
        if isCaptureSuppressed || (isVisible && (frame.contains(NSEvent.mouseLocation) || isDraggingCapture || NSEvent.pressedMouseButtons != 0)) {
            pendingCaptures.removeAll { $0.id == item.id }
            pendingCaptures.append(item)
            if !isCaptureSuppressed { schedulePendingCaptures() }
            return
        }
        captures[item.id] = item
        shelf.insert(item.id)
        lastInteraction = Date()
        rebuild()
        show()
        startDismissTimer()
    }

    private func schedulePendingCaptures() {
        guard pendingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCaptureSuppressed, !self.isDraggingCapture, NSEvent.pressedMouseButtons == 0,
                      !self.isVisible || !self.frame.contains(NSEvent.mouseLocation) else { return }
                self.pendingTimer?.invalidate()
                self.pendingTimer = nil
                let pending = self.pendingCaptures
                self.pendingCaptures.removeAll()
                for item in pending { self.present(item) }
            }
        }
        pendingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss(_ item: CaptureItem) {
        shelf.dismiss(item.id)
        rebuild()
    }

    func dismissAll() {
        for item in pendingCaptures { captures[item.id] = item; shelf.insert(item.id) }
        pendingCaptures.removeAll()
        pendingTimer?.invalidate()
        pendingTimer = nil
        shelf.dismissAll()
        rebuild()
    }

    func reopenLast() {
        guard let id = shelf.lastDismissed, let item = captures[id],
              FileManager.default.fileExists(atPath: item.url(in: library.root).path) else { return }
        present(item)
    }

    func suppressForCapture() {
        isCaptureSuppressed = true
        dismissTimer?.invalidate()
        dismissTimer = nil
        pendingTimer?.invalidate()
        pendingTimer = nil
        orderOut(nil)
    }

    func restoreAfterCapture() {
        isCaptureSuppressed = false
        lastInteraction = Date()
        let pending = pendingCaptures
        pendingCaptures.removeAll()
        for item in pending {
            captures[item.id] = item
            shelf.insert(item.id)
        }
        rebuild()
        if !shelf.ids.isEmpty { show(); startDismissTimer() }
    }

    private static let cardSize = CGSize(width: 232, height: 146)
    private static let gap: CGFloat = 10
    // room for card shadows inside the transparent panel
    private static let inset: CGFloat = 14

    static func cardsThatFit(height: CGFloat, footer: Bool) -> Int {
        let footerHeight = footer ? HUDButton.compactHeight + gap : 0
        let fitting = Int((height - inset * 2 - footerHeight + gap) / (cardSize.height + gap))
        return max(1, min(4, fitting))
    }

    private func rebuild() {
        guard !shelf.ids.isEmpty, !isCaptureSuppressed else {
            orderOut(nil)
            dismissTimer?.invalidate()
            dismissTimer = nil
            return
        }
        let position = UserDefaults.standard.string(forKey: "shelfPosition") ?? "bottomLeft"
        let right = position.contains("Right")
        let bottom = !position.hasPrefix("top")
        let screen = (isVisible ? self.screen : nil) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        // show only as many cards as the screen fits, the footer opens the rest in history
        let shown = Self.cardsThatFit(height: visible.height, footer: shelf.ids.count > 1)
        var views: [NSView] = shelf.ids.prefix(shown).compactMap { id in captures[id].map(makeCard) }
        if shelf.ids.count > 1 { views.append(makeFooter(shown: shown)) }
        // newest card sits closest to the screen corner
        if bottom { views.reverse() }
        let width = Self.cardSize.width + Self.inset * 2
        let height = views.reduce(Self.inset * 2 - Self.gap) { $0 + $1.frame.height + Self.gap }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - Self.inset
        for view in views {
            y -= view.frame.height
            let x = right ? width - Self.inset - view.frame.width : Self.inset
            view.setFrameOrigin(NSPoint(x: x, y: y))
            container.addSubview(view)
            y -= Self.gap
        }
        contentView = container
        let x = right ? visible.maxX - width - 2 : visible.minX + 2
        let originY = bottom ? visible.minY + 2 : visible.maxY - min(height, visible.height) - 2
        setFrame(CGRect(x: x, y: originY, width: width, height: min(height, visible.height)), display: true)
    }

    private func show() {
        guard !isVisible else { orderFrontRegardless(); return }
        let target = frame
        let edge: CGFloat = (UserDefaults.standard.string(forKey: "shelfPosition") ?? "bottomLeft").contains("Right") ? 1 : -1
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { setFrame(target.offsetBy(dx: edge * 28, dy: 0), display: false) }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    private func makeCard(_ item: CaptureItem) -> NSView {
        let card = QuickAccessCard(size: Self.cardSize, url: item.shareURL(in: library.root))
        if let thumbnail = NSImage(contentsOf: item.thumbnail(in: library.root)) {
            card.thumbnail.image = thumbnail
        } else {
            card.thumbnail.image = NSImage(systemSymbolName: item.kind.isVideo ? "video" : "photo", accessibilityDescription: nil)
            card.thumbnail.layer?.contentsGravity = .center
        }
        card.thumbnail.setAccessibilityLabel(item.kind == .videoProject ? "\(item.title), click to edit and export" : "\(item.title), drag to share or click to edit")
        card.thumbnail.onOpen = { [weak self] in self?.interact { self?.onEdit?(item) } }
        card.thumbnail.onDrag = { [weak self] dragging in
            self?.isDraggingCapture = dragging
            self?.lastInteraction = Date()
        }
        var center: [HUDButton] = []
        if item.kind != .videoProject {
            center.append(HUDButton(title: "Copy") { [weak self] in self?.interact { self?.onCopy?(item) } })
        }
        center.append(HUDButton(title: item.kind == .videoProject ? "Export" : "Save") { [weak self] in self?.interact { self?.onSave?(item) } })
        card.setCenter(center)
        card.setCorner(.topLeft, HUDButton(symbol: "xmark", help: "Dismiss") { [weak self] in self?.dismiss(item) })
        card.setCorner(.topRight, HUDButton(symbol: "pencil", help: "Edit") { [weak self] in self?.interact { self?.onEdit?(item) } })
        if !item.kind.isVideo {
            card.setCorner(.bottomLeft, HUDButton(symbol: "pin.fill", help: "Pin") { [weak self] in self?.interact { self?.onPin?(item) } })
        }
        return card
    }

    private func makeFooter(shown: Int) -> NSView {
        let count = shelf.ids.count
        let row = NSStackView(views: [
            HUDButton(title: count > shown ? "Show All \(count)" : "History", compact: true) { [weak self] in self?.onHistory?() },
            HUDButton(title: "Close All", compact: true) { [weak self] in self?.dismissAll() }
        ])
        row.spacing = 6
        row.setFrameSize(row.fittingSize)
        return row
    }

    private func interact(_ action: () -> Void) {
        lastInteraction = Date()
        action()
    }

    private func startDismissTimer() {
        dismissTimer?.invalidate()
        let seconds = UserDefaults.standard.double(forKey: "shelfAutoDismiss")
        guard seconds > 0 else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.frame.contains(NSEvent.mouseLocation) || self.isDraggingCapture || self.isKeyWindow || NSEvent.pressedMouseButtons != 0 {
                    self.lastInteraction = Date()
                } else if Date().timeIntervalSince(self.lastInteraction) >= seconds {
                    self.dismissAll()
                }
            }
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func keyDown(with event: NSEvent) {
        guard let id = shelf.ids.first, let item = captures[id] else { return }
        if event.keyCode == 53 { dismissAll(); return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": onCopy?(item)
            case "s": onSave?(item)
            case "e": onEdit?(item)
            default: super.keyDown(with: event)
            }
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class QuickAccessCard: NSView {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    let thumbnail: CaptureDragView
    private let overlay = PassthroughView()
    private static let radius: CGFloat = 12

    init(size: CGSize, url: URL?) {
        thumbnail = CaptureDragView(url: url)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        let clip = NSView(frame: bounds)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.radius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 0.5
        clip.layer?.borderColor = NSColor.black.withAlphaComponent(0.22).cgColor
        thumbnail.frame = bounds
        overlay.frame = bounds
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        overlay.alphaValue = 0
        clip.addSubview(thumbnail)
        clip.addSubview(overlay)
        addSubview(clip)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    func setCenter(_ buttons: [HUDButton]) {
        let width = max(76, buttons.map(\.frame.width).max() ?? 0)
        for button in buttons { button.setFrameSize(NSSize(width: width, height: button.frame.height)) }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = 6
        stack.setFrameSize(stack.fittingSize)
        stack.setFrameOrigin(NSPoint(x: (bounds.width - stack.frame.width) / 2, y: (bounds.height - stack.frame.height) / 2))
        overlay.addSubview(stack)
    }

    func setCorner(_ corner: Corner, _ button: HUDButton) {
        let inset: CGFloat = 7
        let size = button.frame.size
        let x = corner == .topLeft || corner == .bottomLeft ? inset : bounds.width - size.width - inset
        let y = corner == .bottomLeft || corner == .bottomRight ? inset : bounds.height - size.height - inset
        button.setFrameOrigin(NSPoint(x: x, y: y))
        overlay.addSubview(button)
    }

    // a card rebuilt under a resting pointer gets no mouseEntered
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { overlay.alphaValue = 1 }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hovered ? 0.12 : 0.18
            overlay.animator().alphaValue = hovered ? 1 : 0
        }
    }
}

// lets drags and clicks reach the thumbnail everywhere except on buttons
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
final class HUDButton: NSButton {
    static let compactHeight: CGFloat = 22
    private let handler: () -> Void
    private var hovered = false { didSet { updateFill() } }

    init(title: String = "", symbol: String? = nil, help: String? = nil, compact: Bool = false, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        let label = help ?? title
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        target = self
        self.action = #selector(invoke)
        toolTip = label
        setAccessibilityLabel(label)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
            imagePosition = .imageOnly
            contentTintColor = .white
            setFrameSize(NSSize(width: 24, height: 24))
        } else {
            let font = NSFont.systemFont(ofSize: compact ? 11 : 12, weight: .semibold)
            attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
            setFrameSize(NSSize(width: ceil(attributedTitle.size().width) + (compact ? 20 : 30), height: compact ? Self.compactHeight : 26))
        }
        layer?.cornerRadius = frame.height / 2
        layer?.cornerCurve = .continuous
        updateFill()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { frame.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    @objc private func invoke() { handler() }

    private func updateFill() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(hovered ? 0.8 : 0.58).cgColor
    }
}

@MainActor
final class CaptureDragView: NSView, NSDraggingSource {
    let url: URL?
    var image: NSImage? { didSet { layer?.contents = image } }
    var onOpen: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    private var downEvent: NSEvent?
    private var startedDragging = false

    init(url: URL?) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func mouseDown(with event: NSEvent) { downEvent = event; startedDragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, let downEvent, let url,
              hypot(event.locationInWindow.x - downEvent.locationInWindow.x, event.locationInWindow.y - downEvent.locationInWindow.y) >= 4 else { return }
        startedDragging = true
        onDrag?(true)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !startedDragging { onOpen?() }
        downEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag?(false)
        downEvent = nil
        startedDragging = false
    }
}
