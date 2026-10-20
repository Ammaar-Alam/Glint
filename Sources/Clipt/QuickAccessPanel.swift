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
        hasShadow = true
        animationBehavior = .none
        title = "Recent Captures"
        setAccessibilityLabel("Recent Captures")
    }

    func present(_ item: CaptureItem) {
        if isVisible && (frame.contains(NSEvent.mouseLocation) || isDraggingCapture || NSEvent.pressedMouseButtons != 0) {
            pendingCaptures.removeAll { $0.id == item.id }
            pendingCaptures.append(item)
            schedulePendingCaptures()
            return
        }
        captures[item.id] = item
        shelf.insert(item.id)
        lastInteraction = Date()
        rebuild()
        orderFrontRegardless()
        startDismissTimer()
    }

    private func schedulePendingCaptures() {
        guard pendingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDraggingCapture, NSEvent.pressedMouseButtons == 0,
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
        shelf.dismissAll()
        rebuild()
    }

    func reopenLast() {
        guard let id = shelf.lastDismissed, let item = captures[id],
              FileManager.default.fileExists(atPath: item.url(in: library.root).path) else { return }
        present(item)
    }

    private func rebuild() {
        guard !shelf.ids.isEmpty else {
            orderOut(nil)
            dismissTimer?.invalidate()
            dismissTimer = nil
            return
        }
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for id in shelf.ids.prefix(4) {
            guard let item = captures[id] else { continue }
            let row = makeRow(item)
            rows.addArrangedSubview(row)
        }
        if shelf.ids.count > 1 {
            let actions = NSStackView()
            actions.spacing = 12
            let history = ActionButton(title: shelf.ids.count > 4 ? "View all \(shelf.ids.count)" : "History", symbol: "clock") { [weak self] in self?.onHistory?() }
            let close = ActionButton(title: "Dismiss all", symbol: "xmark") { [weak self] in self?.dismissAll() }
            actions.addArrangedSubview(history)
            actions.addArrangedSubview(close)
            rows.addArrangedSubview(actions)
        }
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        rows.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rows.topAnchor.constraint(equalTo: background.topAnchor),
            rows.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        contentView = background
        let height = CGFloat(min(shelf.ids.count, 4)) * 114 + 20 + (shelf.ids.count > 1 ? 32 : 0)
        let width: CGFloat = 330
        let screen = (isVisible ? self.screen : nil) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let position = UserDefaults.standard.string(forKey: "shelfPosition") ?? "bottomLeft"
        let x = position.contains("Right") ? visible.maxX - width - 16 : visible.minX + 16
        let y = position.hasPrefix("top") ? visible.maxY - height - 16 : visible.minY + 16
        setFrame(CGRect(x: x, y: y, width: width, height: min(height, visible.height - 32)), display: true)
    }

    private func makeRow(_ item: CaptureItem) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.spacing = 6
        row.alignment = .leading
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let heading = NSStackView()
        heading.spacing = 8
        let thumbnail = CaptureDragView(url: item.shareURL(in: library.root))
        thumbnail.image = NSImage(contentsOf: item.thumbnail(in: library.root)) ?? NSImage(systemSymbolName: item.kind.isVideo ? "video" : "photo", accessibilityDescription: nil)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        thumbnail.setAccessibilityLabel(item.kind == .videoProject ? "\(item.title), click to edit and export" : "\(item.title), drag to share or click to edit")
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([thumbnail.widthAnchor.constraint(equalToConstant: 118), thumbnail.heightAnchor.constraint(equalToConstant: 72)])
        thumbnail.onOpen = { [weak self] in self?.interact { self?.onEdit?(item) } }
        thumbnail.onDrag = { [weak self] dragging in
            self?.isDraggingCapture = dragging
            self?.lastInteraction = Date()
        }
        let title = NSTextField(wrappingLabelWithString: item.title)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.maximumNumberOfLines = 3
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dismiss = ActionButton(title: "", symbol: "xmark", help: "Dismiss") { [weak self] in self?.dismiss(item) }
        heading.addArrangedSubview(thumbnail)
        heading.addArrangedSubview(title)
        heading.addArrangedSubview(dismiss)
        heading.widthAnchor.constraint(equalToConstant: 310).isActive = true
        row.addArrangedSubview(heading)

        let actions = NSStackView()
        actions.spacing = 14
        if item.kind != .videoProject {
            actions.addArrangedSubview(ActionButton(title: "Copy", symbol: "doc.on.doc") { [weak self] in self?.interact { self?.onCopy?(item) } })
        }
        actions.addArrangedSubview(ActionButton(title: "Edit", symbol: "pencil") { [weak self] in self?.interact { self?.onEdit?(item) } })
        actions.addArrangedSubview(ActionButton(title: item.kind == .videoProject ? "Export" : "Save", symbol: "square.and.arrow.down") { [weak self] in self?.interact { self?.onSave?(item) } })
        if !item.kind.isVideo {
            actions.addArrangedSubview(ActionButton(title: "Pin", symbol: "pin") { [weak self] in self?.interact { self?.onPin?(item) } })
        }
        row.addArrangedSubview(actions)
        row.heightAnchor.constraint(equalToConstant: 106).isActive = true
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
final class ActionButton: NSButton {
    private var actionHandler: () -> Void

    init(title: String, symbol: String, help: String? = nil, action: @escaping () -> Void) {
        actionHandler = action
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        bezelStyle = .inline
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        contentTintColor = .labelColor
        target = self
        self.action = #selector(invoke)
        toolTip = help ?? title
        setAccessibilityLabel(help ?? title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        if title.isEmpty { widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true }
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func invoke() { actionHandler() }
}

@MainActor
final class CaptureDragView: NSImageView, NSDraggingSource {
    let url: URL?
    var onOpen: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    private var downEvent: NSEvent?
    private var startedDragging = false

    init(url: URL?) { self.url = url; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
