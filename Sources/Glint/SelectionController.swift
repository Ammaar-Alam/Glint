import AppKit
import ScreenCaptureKit

struct FrozenDisplayFrame {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage
}

enum CaptureSelection {
    case region(CGRect, CaptureMode)
    case window(SCWindow)
    case record
}

enum CaptureGeometry {
    static func quartzPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func quartzRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        quartzRect(fromCocoa: rect, primaryHeight: primaryHeight)
    }

    static func rectangle(from start: CGPoint, to end: CGPoint, square: Bool = false) -> CGRect {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = min(abs(dx), abs(dy))
        let end = square ? CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side)) : end
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func rectangle(from start: CGPoint, to end: CGPoint, ratio: CGFloat?) -> CGRect {
        guard let ratio, ratio.isFinite, ratio > 0 else { return rectangle(from: start, to: end) }
        let width = min(abs(end.x - start.x), abs(end.y - start.y) * ratio)
        let adjusted = CGPoint(x: start.x + (end.x < start.x ? -width : width),
                               y: start.y + (end.y < start.y ? -width / ratio : width / ratio))
        return rectangle(from: start, to: adjusted)
    }

    static func displayLocalRect(_ rect: CGRect, displayFrame: CGRect) -> CGRect {
        rect.intersection(displayFrame).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }
}

@MainActor
final class SelectionController {
    private static var active: SelectionController?
    private var panels: [SelectionPanel] = []
    private var views: [SelectionView] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private var candidates: [SCWindow] = []
    private var mode: CaptureMode = .area
    private var allInOne = false
    private var allowsRecording = false
    private var frozenFrames: [FrozenDisplayFrame] = []
    private var magnifierProvider: ((CGRect) async -> CGImage?)?
    private var magnifierTask: Task<Void, Never>?
    private var toolbar: SelectionPanel?
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ratioPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField(string: "320")
    private let heightField = NSTextField(string: "200")
    private var fixedSize: CGSize?
    private var aspectRatio: CGFloat?
    private let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("3:2", 1.5)]
    private let modes: [CaptureMode] = [.area, .window, .fullScreen, .text, .scrolling]
    private var isWindowSelection: Bool { mode == .window }
    private var start: CGPoint?
    private var selection: CGRect?
    private var selectedWindow: SCWindow?
    private var windowSelectionLocked = false
    private var regionSelectionLocked = false
    private var previousApplication: NSRunningApplication?
    private var lastPointer: CGPoint = .zero
    private let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height

    // Quartz display points use the primary display's upper-left as their origin
    static func selectRegion() async -> CGRect? {
        guard active == nil else { return nil }
        let controller = SelectionController()
        if case .region(let rect, _) = await controller.run() { return rect }
        return nil
    }

    static func selectWindow(from windows: [SCWindow]) async -> SCWindow? {
        guard active == nil else { return nil }
        let controller = SelectionController()
        controller.mode = .window
        controller.configureCandidates(windows)
        if case .window(let window) = await controller.run() { return window }
        return nil
    }

    static func selectCapture(mode: CaptureMode, windows: [SCWindow], frozenFrames: [FrozenDisplayFrame] = [],
                              allowsRecording: Bool = false, magnifier: ((CGRect) async -> CGImage?)? = nil) async -> CaptureSelection? {
        guard active == nil else { return nil }
        let controller = SelectionController()
        controller.mode = mode == .allInOne ? .area : mode
        controller.allInOne = mode == .allInOne
        controller.allowsRecording = allowsRecording
        controller.frozenFrames = frozenFrames
        controller.magnifierProvider = magnifier
        controller.configureCandidates(windows)
        return await controller.run()
    }

    private func configureCandidates(_ windows: [SCWindow]) {
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        candidates = windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 2 && $0.frame.height > 2 &&
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.sorted { (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max) }
    }

    private func run() async -> CaptureSelection? {
        Self.active = self
        previousApplication = NSWorkspace.shared.frontmostApplication
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !NSScreen.screens.isEmpty else { finish(nil); return }
                for screen in NSScreen.screens {
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.level = .screenSaver
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.hasShadow = false
                    panel.isReleasedWhenClosed = false
                    panel.hidesOnDeactivate = false
                    panel.acceptsMouseMovedEvents = true
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                    let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                    view.screenFrame = screen.frame
                    view.isWindowSelection = isWindowSelection
                    if let identifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        view.backgroundImage = frozenFrames.first { $0.displayID == identifier.uint32Value }?.image
                    }
                    view.onMove = { [weak self] point, modifiers in self?.move(to: point, modifiers: modifiers) }
                    view.onDown = { [weak self] point in self?.mouseDown(at: point) }
                    view.onUp = { [weak self] point, modifiers in self?.mouseUp(at: point, modifiers: modifiers) }
                    view.onCancel = { [weak self] in self?.finish(nil) }
                    view.onKey = { [weak self] event in self?.handleKey(event) }
                    panel.contentView = view
                    panel.makeFirstResponder(view)
                    panels.append(panel)
                    views.append(view)
                    panel.orderFrontRegardless()
                }
                NSApp.activate(ignoringOtherApps: true)
                let point = NSEvent.mouseLocation
                lastPointer = point
                (panels.first { $0.frame.contains(point) } ?? panels.first)?.makeKey()
                showToolbar()
                move(to: point, modifiers: [])
                startMagnifier()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    private func mouseDown(at point: CGPoint) {
        if isWindowSelection {
            windowSelectionLocked = false
            move(to: point, modifiers: [])
            if !allInOne, let selectedWindow { finish(.window(selectedWindow)) }
            else { windowSelectionLocked = true }
        } else if mode == .fullScreen {
            move(to: point, modifiers: [])
            captureSelection()
        } else {
            start = point
            regionSelectionLocked = false
            selection = CGRect(origin: point, size: .zero)
            move(to: point, modifiers: [])
        }
    }

    private func move(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        lastPointer = point
        if isWindowSelection {
            if !windowSelectionLocked {
                let quartzPoint = CaptureGeometry.quartzPoint(fromCocoa: point, primaryHeight: primaryHeight)
                selectedWindow = candidates.first { $0.frame.contains(quartzPoint) }
            }
            selection = selectedWindow.map { CaptureGeometry.cocoaRect(fromQuartz: $0.frame, primaryHeight: primaryHeight) }
        } else if mode == .fullScreen {
            selection = NSScreen.screens.first { $0.frame.contains(point) }?.frame
        } else if let fixedSize, !regionSelectionLocked || start != nil {
            selection = CGRect(x: point.x, y: point.y - fixedSize.height, width: fixedSize.width, height: fixedSize.height)
        } else if let start {
            selection = CaptureGeometry.rectangle(from: start, to: point, ratio: modifiers.contains(.shift) ? 1 : aspectRatio)
        }
        updateViews(pointer: point)
    }

    private func showToolbar() {
        let width: CGFloat = allInOne ? (allowsRecording ? 760 : 674) : (isWindowSelection ? 260 : 570)
        let panel = SelectionPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: 52),
                                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar = panel
        panel.title = "Capture"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let row = NSStackView()
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        if allInOne {
            for mode in modes { modePicker.addItem(withTitle: mode.title.replacingOccurrences(of: "Capture ", with: "")) }
            modePicker.selectItem(at: modes.firstIndex(of: mode) ?? 0)
            modePicker.target = self
            modePicker.action = #selector(changeMode)
            modePicker.widthAnchor.constraint(equalToConstant: 130).isActive = true
            row.addArrangedSubview(modePicker)
        }
        if allInOne || !isWindowSelection {
            for (name, field) in [("W", widthField), ("H", heightField)] {
                row.addArrangedSubview(NSTextField(labelWithString: name))
                field.target = self
                field.action = #selector(changeDimensions(_:))
                field.alignment = .right
                field.widthAnchor.constraint(equalToConstant: 64).isActive = true
                field.setAccessibilityLabel(name == "W" ? "Capture width" : "Capture height")
                row.addArrangedSubview(field)
            }
            ratioPicker.addItems(withTitles: ratios.map(\.0))
            ratioPicker.target = self
            ratioPicker.action = #selector(changeRatio)
            ratioPicker.widthAnchor.constraint(equalToConstant: 82).isActive = true
            ratioPicker.setAccessibilityLabel("Aspect ratio")
            row.addArrangedSubview(ratioPicker)
        }
        if allInOne && allowsRecording {
            row.addArrangedSubview(NSButton(title: "Record…", target: self, action: #selector(requestRecording)))
        }
        let capture = NSButton(title: "Capture", target: self, action: #selector(captureSelection))
        capture.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.keyEquivalent = "\u{1b}"
        row.addArrangedSubview(capture)
        row.addArrangedSubview(cancel)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 52))
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        panel.contentView = content
        let frame = NSScreen.screens.first(where: { $0.frame.contains(lastPointer) })?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - width / 2, y: frame.maxY - panel.frame.height - 20))
        updateToolbar()
        panel.orderFrontRegardless()
    }

    private func updateToolbar() {
        let enabled = !isWindowSelection && mode != .fullScreen
        widthField.isEnabled = enabled
        heightField.isEnabled = enabled
        ratioPicker.isEnabled = enabled
    }

    @objc private func changeMode() {
        guard modes.indices.contains(modePicker.indexOfSelectedItem) else { return }
        mode = modes[modePicker.indexOfSelectedItem]
        selectedWindow = nil
        windowSelectionLocked = false
        regionSelectionLocked = false
        selection = nil
        start = nil
        updateToolbar()
        move(to: lastPointer, modifiers: [])
    }

    @objc private func changeDimensions(_ sender: NSTextField) {
        var width = widthField.doubleValue
        var height = heightField.doubleValue
        if let aspectRatio {
            if sender === widthField { height = width / aspectRatio }
            else { width = height * aspectRatio }
        }
        guard width.isFinite, height.isFinite, (2...32_768).contains(width), (2...32_768).contains(height) else { NSSound.beep(); return }
        regionSelectionLocked = selection != nil
        fixedSize = CGSize(width: width.rounded(), height: height.rounded())
        let origin = selection?.origin ?? CGPoint(x: lastPointer.x, y: lastPointer.y - height)
        selection = CGRect(origin: origin, size: fixedSize!)
        updateViews(pointer: lastPointer)
    }

    @objc private func changeRatio() {
        guard ratios.indices.contains(ratioPicker.indexOfSelectedItem) else { return }
        aspectRatio = ratios[ratioPicker.indexOfSelectedItem].1
        fixedSize = nil
        if let ratio = aspectRatio, var rect = selection {
            rect.size.height = rect.width / ratio
            selection = rect
        }
        updateViews(pointer: lastPointer)
    }

    @objc private func requestRecording() { finish(.record) }
    @objc private func cancelSelection() { finish(nil) }

    @objc private func captureSelection() {
        if isWindowSelection, let selectedWindow { finish(.window(selectedWindow)) }
        else if let selection, selection.width >= 2, selection.height >= 2 {
            finish(.region(CaptureGeometry.quartzRect(fromCocoa: selection, primaryHeight: primaryHeight), mode))
        } else { NSSound.beep() }
    }

    private func startMagnifier() {
        guard UserDefaults.standard.bool(forKey: "showMagnifier"), magnifierProvider != nil || !frozenFrames.isEmpty else { return }
        magnifierTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.continuation != nil else { return }
                if !isWindowSelection && mode != .fullScreen {
                    let point = CaptureGeometry.quartzPoint(fromCocoa: lastPointer, primaryHeight: primaryHeight)
                    let rect = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
                    let image: CGImage?
                    if !frozenFrames.isEmpty && mode != .scrolling {
                        image = try? await CaptureFrame.frozenRegion(rect, frames: frozenFrames)
                    } else { image = await magnifierProvider?(rect) }
                    guard !Task.isCancelled, continuation != nil else { return }
                    for view in views { view.magnifierImage = image; view.needsDisplay = true }
                }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
        }
    }

    private func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard !isWindowSelection else { return }
        move(to: point, modifiers: modifiers)
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            start = nil
            self.selection = nil
            updateViews(pointer: point)
            return
        }
        start = nil
        regionSelectionLocked = true
        if !allInOne { finish(.region(CaptureGeometry.quartzRect(fromCocoa: selection, primaryHeight: primaryHeight), mode)) }
    }

    private func updateViews(pointer: CGPoint) {
        for view in views {
            view.selection = selection?.offsetBy(dx: -view.screenFrame.minX, dy: -view.screenFrame.minY)
            view.pointer = CGPoint(x: pointer.x - view.screenFrame.minX, y: pointer.y - view.screenFrame.minY)
            view.caption = selectedWindow?.title.flatMap { $0.isEmpty ? nil : $0 } ?? selectedWindow?.owningApplication?.applicationName
            view.isWindowSelection = isWindowSelection
            view.showsFrozenBackground = mode != .window && mode != .scrolling
            view.showsMagnifier = magnifierTask != nil && !isWindowSelection && mode != .fullScreen && view.screenFrame.contains(pointer)
            if let selection { view.setAccessibilityValue("\(Int(selection.width)) by \(Int(selection.height))") }
            view.needsDisplay = true
        }
        if let selection, !(toolbar?.firstResponder is NSTextView) {
            widthField.integerValue = Int(selection.width)
            heightField.integerValue = Int(selection.height)
        }
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            captureSelection()
            return
        }
        guard [48, 123, 124, 125, 126].contains(event.keyCode) else { return }
        if mode == .fullScreen && event.keyCode != 48 { return }
        if isWindowSelection {
            guard !candidates.isEmpty else { return }
            let current = selectedWindow.flatMap { selected in candidates.firstIndex { $0.windowID == selected.windowID } } ?? -1
            let increment = event.keyCode == 123 || event.keyCode == 126 || event.modifierFlags.contains(.shift) ? -1 : 1
            selectedWindow = candidates[(current + increment + candidates.count) % candidates.count]
            windowSelectionLocked = true
            selection = selectedWindow.map { CaptureGeometry.cocoaRect(fromQuartz: $0.frame, primaryHeight: primaryHeight) }
        } else {
            let screens = NSScreen.screens
            guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first else { return }
            var rect = selection ?? CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 100, width: 320, height: 200)
            if event.keyCode == 48 {
                let current = screens.firstIndex { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? 0
                let next = screens[(current + 1) % screens.count].frame
                rect.size = CGSize(width: min(rect.width, next.width), height: min(rect.height, next.height))
                rect.origin = CGPoint(x: next.midX - rect.width / 2, y: next.midY - rect.height / 2)
            } else {
                let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
                let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
                let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
                if event.modifierFlags.contains(.shift) {
                    rect.size.width = max(2, rect.width + dx)
                    rect.size.height = max(2, rect.height + dy)
                } else { rect = rect.offsetBy(dx: dx, dy: dy) }
            }
            selection = rect
            regionSelectionLocked = true
        }
        let point = selection.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        updateViews(pointer: point)
    }

    private func finish(_ result: CaptureSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        magnifierTask?.cancel()
        magnifierTask = nil
        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        Self.active = nil
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
        continuation.resume(returning: result)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    var screenFrame: CGRect = .zero
    var selection: CGRect?
    var pointer: CGPoint = .zero
    var caption: String?
    var isWindowSelection = false
    var backgroundImage: CGImage?
    var showsFrozenBackground = true
    var magnifierImage: CGImage?
    var showsMagnifier = false
    var onMove: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onDown: ((CGPoint) -> Void)?
    var onUp: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    var onKey: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isWindowSelection ? .pointingHand : .crosshair) }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseMoved(with event: NSEvent) { onMove?(screenPoint(for: event), event.modifierFlags) }
    override func mouseDragged(with event: NSEvent) { onMove?(screenPoint(for: event), event.modifierFlags) }
    override func mouseEntered(with event: NSEvent) { onMove?(screenPoint(for: event), event.modifierFlags) }
    override func mouseDown(with event: NSEvent) { onDown?(screenPoint(for: event)) }
    override func mouseUp(with event: NSEvent) { onUp?(screenPoint(for: event), event.modifierFlags) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { onKey?(event) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture selection")
        setAccessibilityHelp("Use arrow keys to move, Shift and arrow keys to resize, Tab to switch screens, Return to capture, or Escape to cancel.")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        if showsFrozenBackground, let backgroundImage { NSGraphicsContext.current?.cgContext.draw(backgroundImage, in: bounds) }
        let dim = NSBezierPath(rect: bounds)
        if let selection, selection.intersects(bounds) { dim.appendRect(selection.intersection(bounds)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.22).setFill()
        dim.fill()
        if let selection, !selection.isEmpty {
            if isWindowSelection {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(rect: selection).fill()
            }
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
        } else if !isWindowSelection {
            let crosshair = NSBezierPath()
            crosshair.move(to: CGPoint(x: pointer.x, y: 0))
            crosshair.line(to: CGPoint(x: pointer.x, y: bounds.height))
            crosshair.move(to: CGPoint(x: 0, y: pointer.y))
            crosshair.line(to: CGPoint(x: bounds.width, y: pointer.y))
            NSColor.white.withAlphaComponent(0.55).setStroke()
            crosshair.lineWidth = 0.5
            crosshair.stroke()
        }
        if showsMagnifier, let magnifierImage, let context = NSGraphicsContext.current?.cgContext {
            let rect = CGRect(x: max(12, min(pointer.x + 20, bounds.width - 124)),
                              y: max(12, min(pointer.y + 20, bounds.height - 124)), width: 108, height: 108)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.clip()
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(rect)
            context.interpolationQuality = .none
            context.draw(magnifierImage, in: rect)
            context.restoreGState()
            NSColor.white.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            border.lineWidth = 2
            border.stroke()
            let center = NSBezierPath()
            center.move(to: CGPoint(x: rect.midX - 8, y: rect.midY)); center.line(to: CGPoint(x: rect.midX + 8, y: rect.midY))
            center.move(to: CGPoint(x: rect.midX, y: rect.midY - 8)); center.line(to: CGPoint(x: rect.midX, y: rect.midY + 8))
            NSColor.black.setStroke(); center.lineWidth = 3; center.stroke()
            NSColor.white.setStroke(); center.lineWidth = 1; center.stroke()
        }
        let label: String
        if isWindowSelection { label = caption ?? "Choose a window · Esc to cancel" }
        else if let selection, selection.width > 0 { label = "\(Int(selection.width)) × \(Int(selection.height))" }
        else { label = "Drag to capture · Shift for square · Esc to cancel" }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: max(12, min(pointer.x + 16, bounds.width - size.width - 24)), y: max(12, min(pointer.y - 36, bounds.height - 36)))
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: CGSize(width: size.width + 16, height: size.height + 12)), xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + 6), withAttributes: attributes)
    }
}
