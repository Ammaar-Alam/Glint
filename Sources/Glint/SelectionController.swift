import AppKit
import ScreenCaptureKit
import SwiftUI

struct FrozenDisplayFrame {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage
}

enum CaptureSelection {
    case region(CGRect, CaptureMode)
    case window(SCWindow)
    indirect case record(CaptureSelection, RecordingOptions)
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

    // a bar just under an area, above it when the screen ends, inside its bottom when neither fits
    static func attach(_ size: CGSize, to area: CGRect, within bounds: CGRect) -> CGPoint {
        let x = min(max(area.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        if area.minY - size.height >= bounds.minY { return CGPoint(x: x, y: area.minY - size.height) }
        if area.maxY + size.height <= bounds.maxY { return CGPoint(x: x, y: area.maxY) }
        return CGPoint(x: x, y: max(bounds.minY, area.minY))
    }

    static func displayLocalRect(_ rect: CGRect, displayFrame: CGRect) -> CGRect {
        rect.intersection(displayFrame).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }

    // moves the grabbed edges, -1 the min edge and 1 the max, no edges moves the whole rect
    static func adjusted(_ rect: CGRect, edges: (x: Int, y: Int), by delta: CGVector, ratio: CGFloat? = nil) -> CGRect {
        if edges.x == 0 && edges.y == 0 { return rect.offsetBy(dx: delta.dx, dy: delta.dy) }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.x < 0 { minX += delta.dx } else if edges.x > 0 { maxX += delta.dx }
        if edges.y < 0 { minY += delta.dy } else if edges.y > 0 { maxY += delta.dy }
        var result = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        guard let ratio, ratio.isFinite, ratio > 0 else { return result }
        if edges.x != 0 {
            let height = result.width / ratio
            if edges.y <= 0 { result.origin.y = result.maxY - height }
            result.size.height = height
        } else { result.size.width = result.height * ratio }
        return result
    }
}


@MainActor
final class SelectionController {
    private static var active: SelectionController?
    // below the menu level so the bar's menus open above the overlay
    private static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 2)
    private var panels: [SelectionPanel] = []
    private var views: [SelectionView] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private var candidates: [SCWindow] = []
    private let bar: CaptureBarModel
    private var mode: CaptureMode {
        get { bar.mode }
        set { bar.mode = newValue }
    }
    private var allInOne: Bool { bar.allInOne }
    private var frozenFrames: [FrozenDisplayFrame] = []
    private var snapshots: (() async -> [FrozenDisplayFrame])?
    private var snapshotTask: Task<Void, Never>?
    private var toolbarSize = CGSize.zero
    private var toolbarVisible = false
    private var moveObserver: NSObjectProtocol?
    // where the bar was dragged to, as a share of the screen so it holds across displays
    private static let placementKey = "captureBarPlacement"
    private var showsLoupe = false
    private var toolbar: SelectionPanel?
    private var isWindowSelection: Bool { mode == .window }
    private var start: CGPoint?
    private var drag: (origin: CGRect, from: CGPoint, edges: (x: Int, y: Int))?
    private var selection: CGRect?
    private var selectedWindow: SCWindow?
    private var windowSelectionLocked = false
    private var regionSelectionLocked = false
    private var previousApplication: NSRunningApplication?
    private var lastPointer: CGPoint = .zero
    private let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height

    private init(allInOne: Bool, allowsRecording: Bool) {
        bar = CaptureBarModel(allInOne: allInOne, allowsRecording: allowsRecording)
    }

    static func selectCapture(mode: CaptureMode, windows: [SCWindow], frozenFrames: [FrozenDisplayFrame] = [],
                              allowsRecording: Bool = false, recording: RecordingFormat? = nil, showsLoupe: Bool = true,
                              snapshots: (() async -> [FrozenDisplayFrame])? = nil) async -> CaptureSelection? {
        guard active == nil else { return nil }
        let controller = SelectionController(allInOne: mode == .allInOne || recording != nil, allowsRecording: allowsRecording || recording != nil)
        controller.mode = mode == .allInOne ? .area : mode
        if let recording {
            controller.bar.recording = true
            controller.bar.options.format = recording
            controller.mode = controller.bar.options.mode.captureMode
        }
        controller.frozenFrames = frozenFrames
        controller.bar.timerApplies = frozenFrames.isEmpty
        controller.showsLoupe = showsLoupe
        controller.snapshots = snapshots
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
                    // takes keys and pointer moves without waiting for the app to activate, which a hotkey can't force
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.level = Self.overlayLevel
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.hasShadow = false
                    panel.isReleasedWhenClosed = false
                    panel.hidesOnDeactivate = false
                    panel.acceptsMouseMovedEvents = true
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                    let backdrop = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
                    backdrop.wantsLayer = true
                    let view = SelectionView(frame: backdrop.bounds)
                    view.autoresizingMask = [.width, .height]
                    view.screenFrame = screen.frame
                    view.isWindowSelection = isWindowSelection
                    let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    view.displayID = identifier
                    view.backgroundImage = frozenFrames.first { $0.displayID == identifier }?.image
                    if showsLoupe { view.loupeImage = view.backgroundImage }
                    view.onMove = { [weak self] point, modifiers in self?.move(to: point, modifiers: modifiers) }
                    view.onDown = { [weak self] point in self?.mouseDown(at: point) }
                    view.onUp = { [weak self] point, modifiers in self?.mouseUp(at: point, modifiers: modifiers) }
                    view.onCancel = { [weak self] in self?.finish(nil) }
                    view.onKey = { [weak self] event in self?.handleKey(event) }
                    backdrop.addSubview(view)
                    panel.contentView = backdrop
                    panel.makeFirstResponder(view)
                    panels.append(panel)
                    views.append(view)
                    panel.orderFrontRegardless()
                }
                NSApp.activate(ignoringOtherApps: true)
                let point = NSEvent.mouseLocation
                lastPointer = point
                focusOverlay()
                // plain shortcuts capture on release, only the all-in-one bar has choices to make
                if allInOne { showToolbar() }
                move(to: point, modifiers: [])
                loadSnapshots()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    private func focusOverlay() {
        (panels.first { $0.frame.contains(lastPointer) } ?? panels.first)?.makeKey()
    }

    // the loupe samples a still of each display so following the pointer never waits on a capture
    private func loadSnapshots() {
        guard showsLoupe, let snapshots else { return }
        snapshotTask = Task { [weak self] in
            let frames = await snapshots()
            guard let self, !Task.isCancelled, continuation != nil else { return }
            for view in views {
                view.loupeImage = frames.first { $0.displayID == view.displayID }?.image
                view.refresh()
            }
        }
    }

    private func grip(at point: CGPoint) -> (x: Int, y: Int)? {
        guard allInOne, regionSelectionLocked, !isWindowSelection, mode != .fullScreen, let rect = selection else { return nil }
        let slop: CGFloat = 6
        guard rect.insetBy(dx: -slop, dy: -slop).contains(point) else { return nil }
        let x = abs(point.x - rect.minX) <= slop ? -1 : abs(point.x - rect.maxX) <= slop ? 1 : 0
        let y = abs(point.y - rect.minY) <= slop ? -1 : abs(point.y - rect.maxY) <= slop ? 1 : 0
        return (x, y)
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
        } else if let edges = grip(at: point), let selection {
            drag = (selection, point, edges)
            updateCursor(at: point)
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
        } else if let drag {
            let delta = CGVector(dx: point.x - drag.from.x, dy: point.y - drag.from.y)
            let ratio = modifiers.contains(.shift) ? drag.origin.width / max(1, drag.origin.height) : nil
            selection = CaptureGeometry.adjusted(drag.origin, edges: drag.edges, by: delta, ratio: ratio)
        } else if let start {
            selection = CaptureGeometry.rectangle(from: start, to: point, ratio: modifiers.contains(.shift) ? 1 : nil)
        }
        updateCursor(at: point)
        updateViews(pointer: point)
    }

    private func updateCursor(at point: CGPoint) {
        if let drag, drag.edges != (0, 0) { return }
        guard let edges = grip(at: point) else {
            (isWindowSelection ? NSCursor.pointingHand : NSCursor.crosshair).set()
            return
        }
        let position: NSCursor.FrameResizePosition? = switch (edges.x, edges.y) {
        case (-1, 1): .topLeft
        case (0, 1): .top
        case (1, 1): .topRight
        case (-1, 0): .left
        case (1, 0): .right
        case (-1, -1): .bottomLeft
        case (0, -1): .bottom
        case (1, -1): .bottomRight
        default: nil
        }
        if let position { NSCursor.frameResize(position: position, directions: .all).set() }
        else { (drag == nil ? NSCursor.openHand : NSCursor.closedHand).set() }
    }

    private func showToolbar() {
        let panel = SelectionPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 72), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar = panel
        panel.title = "Capture"
        panel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // drag the bar by its background, it stays wherever it was left
        panel.isMovableByWindowBackground = true
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel, NSApp.currentEvent?.type == .leftMouseDragged, let screen = panel.screen else { return }
                let bounds = screen.visibleFrame
                UserDefaults.standard.set([(panel.frame.midX - bounds.minX) / bounds.width, (panel.frame.midY - bounds.minY) / bounds.height], forKey: Self.placementKey)
            }
        }
        bar.onMode = { [weak self] in self?.changeMode($0) }
        bar.onRecording = { [weak self] recording in
            guard let self else { return }
            bar.recording = recording
            if recording, ![.area, .fullScreen, .window].contains(mode) { changeMode(.area) }
            else { updateViews(pointer: lastPointer) }
        }
        bar.onCapture = { [weak self] in self?.captureSelection() }
        bar.onCancel = { [weak self] in self?.finish(nil) }
        bar.onResize = { [weak self] in self?.placeToolbar($0) }
        let host = FirstMouseHostingView(rootView: CaptureBar(model: bar))
        panel.contentView = host
        // placed while invisible, then fades in where it belongs instead of sliding across the screen
        panel.alphaValue = 0
        placeToolbar(host.fittingSize)
        panel.orderFrontRegardless()
    }

    private func placeToolbar(_ size: CGSize) {
        toolbarSize = size
        layoutToolbar(hidden: false)
    }

    // the bar rides under the chosen area like a part of it, and steps away while the area is being drawn
    private func layoutToolbar(hidden: Bool) {
        guard let toolbar, toolbarSize.width > 0 else { return }
        // a drawn area keeps the bar under it, otherwise it waits in the middle or where it was dragged
        let area = mode == .area || mode == .scrolling ? selection : nil
        let anchor = area.map { CGPoint(x: $0.midX, y: $0.midY) } ?? lastPointer
        let frame = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.screens[0]).visibleFrame
        let placed = (UserDefaults.standard.array(forKey: Self.placementKey) as? [Double]).flatMap { $0.count == 2 ? $0 : nil }
        let origin: CGPoint
        if let placed {
            let x = min(max(frame.minX + frame.width * placed[0] - toolbarSize.width / 2, frame.minX), frame.maxX - toolbarSize.width)
            let y = min(max(frame.minY + frame.height * placed[1] - toolbarSize.height / 2, frame.minY), frame.maxY - toolbarSize.height)
            origin = CGPoint(x: x, y: y)
        } else if let area {
            origin = CaptureGeometry.attach(toolbarSize, to: area, within: frame)
        } else {
            origin = CGPoint(x: frame.midX - toolbarSize.width / 2, y: frame.midY - toolbarSize.height / 2)
        }
        let target = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: toolbarSize)
        // each change animates once, pointer moves in between leave a running fade alone
        if hidden {
            guard toolbarVisible else { return }
            toolbarVisible = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                toolbar.animator().alphaValue = 0
            }
            return
        }
        let appearing = !toolbarVisible
        guard appearing || toolbar.frame != target else { return }
        toolbarVisible = true
        // an invisible bar jumps straight to its spot and only fades
        if appearing { toolbar.setFrame(target, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.16 : 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            if !appearing { toolbar.animator().setFrame(target, display: true) }
            toolbar.animator().alphaValue = 1
        }
    }

    private func changeMode(_ newMode: CaptureMode) {
        // a drawn area stays put when switching to another area-based mode
        let areaModes: [CaptureMode] = [.area, .scrolling, .text]
        let keepsArea = areaModes.contains(mode) && areaModes.contains(newMode)
        mode = newMode
        selectedWindow = nil
        windowSelectionLocked = false
        if !keepsArea {
            regionSelectionLocked = false
            selection = nil
        }
        start = nil
        drag = nil
        move(to: lastPointer, modifiers: [])
    }

    private func captureSelection() {
        let target: CaptureSelection
        if isWindowSelection, let selectedWindow { target = .window(selectedWindow) }
        else if !isWindowSelection, let selection, selection.width >= 2, selection.height >= 2 {
            target = .region(CaptureGeometry.quartzRect(fromCocoa: selection, primaryHeight: primaryHeight), mode)
        } else { NSSound.beep(); return }
        guard bar.recording else { finish(target); return }
        var options = bar.options
        options.mode = mode == .window ? .window : mode == .fullScreen ? .fullScreen : .area
        options.save()
        finish(.record(target, options))
    }

    private func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        if drag != nil {
            move(to: point, modifiers: modifiers)
            drag = nil
            if let rect = selection, rect.width < 2 || rect.height < 2 { selection = nil; regionSelectionLocked = false }
            updateCursor(at: point)
            updateViews(pointer: point)
            return
        }
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
        else { updateCursor(at: point); updateViews(pointer: point) }
    }

    private func updateViews(pointer: CGPoint) {
        let selecting = selection == nil || start != nil || (drag.map { $0.edges != (0, 0) } ?? false)
        for view in views {
            view.selection = selection?.offsetBy(dx: -view.screenFrame.minX, dy: -view.screenFrame.minY)
            view.pointer = CGPoint(x: pointer.x - view.screenFrame.minX, y: pointer.y - view.screenFrame.minY)
            view.caption = selectedWindow?.title.flatMap { $0.isEmpty ? nil : $0 } ?? selectedWindow?.owningApplication?.applicationName
            view.isWindowSelection = isWindowSelection
            view.showsHandles = allInOne && regionSelectionLocked && !isWindowSelection && mode != .fullScreen
            view.showsFrozenBackground = mode != .window && mode != .scrolling && !bar.recording
            view.showsMagnifier = showsLoupe && selecting && !isWindowSelection && mode != .fullScreen && view.screenFrame.contains(pointer)
            view.refresh()
        }
        layoutToolbar(hidden: start != nil || drag != nil)
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
        snapshotTask?.cancel()
        snapshotTask = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
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

private extension RecordingMode {
    var captureMode: CaptureMode {
        switch self {
        case .area: return .area
        case .window: return .window
        case .fullScreen: return .fullScreen
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// plain layers for everything that spans the screen so a pointer move costs a few frame changes
@MainActor
final class SelectionView: NSView {
    var screenFrame: CGRect = .zero
    var displayID: CGDirectDisplayID?
    var selection: CGRect?
    var pointer: CGPoint = .zero
    var caption: String?
    var isWindowSelection = false
    var showsHandles = false
    var backgroundImage: CGImage? { didSet { applyBackground() } }
    var showsFrozenBackground = true { didSet { if showsFrozenBackground != oldValue { applyBackground() } } }
    var loupeImage: CGImage?
    var showsMagnifier = false
    var onMove: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onDown: ((CGPoint) -> Void)?
    var onUp: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    var onKey: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?
    private let shades = (0..<4).map { _ in CALayer() }
    private let edge = CALayer()
    private let outline = CALayer()
    private let crosshair = (0..<2).map { _ in CALayer() }
    private let handles = (0..<8).map { _ in CALayer() }
    private let label = PillView()
    private let loupe = LoupeView()

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isWindowSelection ? .pointingHand : .crosshair) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shade in shades { shade.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor }
        outline.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        outline.borderWidth = 1
        for line in crosshair { line.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor }
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            handle.cornerRadius = 4
            handle.backgroundColor = .white
            handle.shadowColor = .black
            handle.shadowOpacity = 0.5
            handle.shadowRadius = 1.5
            handle.shadowOffset = CGSize(width: 0, height: -0.5)
        }
        for sublayer in shades + [outline, edge] + crosshair + handles { layer?.addSublayer(sublayer) }
        addSubview(label)
        addSubview(loupe)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture selection")
        setAccessibilityHelp("Use arrow keys to move, Shift and arrow keys to resize, Tab to switch screens, Return to capture, or Escape to cancel.")
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyBackground()
    }

    // the still screen lives in the parent's layer
    private func applyBackground() {
        superview?.layer?.contents = showsFrozenBackground ? backgroundImage : nil
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

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let area = bounds
        let hole = selection.map { $0.intersection(area) } ?? .null
        if hole.isNull || hole.isEmpty {
            shades[0].frame = area
            for shade in shades.dropFirst() { shade.frame = .zero }
        } else {
            shades[0].frame = CGRect(x: 0, y: hole.maxY, width: area.width, height: area.maxY - hole.maxY)
            shades[1].frame = CGRect(x: 0, y: 0, width: area.width, height: hole.minY)
            shades[2].frame = CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height)
            shades[3].frame = CGRect(x: hole.maxX, y: hole.minY, width: area.width - hole.maxX, height: hole.height)
        }
        let selected = selection.flatMap { $0.isEmpty ? nil : $0 }
        edge.isHidden = selected == nil
        outline.isHidden = selected == nil || isWindowSelection
        for line in crosshair { line.isHidden = selected != nil || isWindowSelection }
        for handle in handles { handle.isHidden = selected == nil || !showsHandles }
        label.isHidden = selected == nil
        if let selected {
            if isWindowSelection {
                edge.frame = selected
                edge.borderWidth = 2
                edge.borderColor = NSColor.glint.cgColor
                edge.backgroundColor = NSColor.glint.withAlphaComponent(0.14).cgColor
            } else {
                edge.frame = selected.insetBy(dx: -1, dy: -1)
                edge.borderWidth = 1
                edge.borderColor = .white
                edge.backgroundColor = nil
                outline.frame = selected.insetBy(dx: -2, dy: -2)
            }
            var index = 0
            for x in [selected.minX, selected.midX, selected.maxX] {
                for y in [selected.minY, selected.midY, selected.maxY] where !(x == selected.midX && y == selected.midY) {
                    handles[index].position = CGPoint(x: x, y: y)
                    index += 1
                }
            }
            label.text = isWindowSelection ? caption ?? "\(Int(selected.width)) × \(Int(selected.height))"
                : "\(Int(selected.width.rounded())) × \(Int(selected.height.rounded()))"
            let size = label.fittingSize
            let origin: CGPoint
            if isWindowSelection {
                origin = CGPoint(x: selected.midX - size.width / 2, y: selected.midY - size.height / 2)
            } else {
                let above = selected.maxY + 8 + size.height <= area.height
                origin = CGPoint(x: selected.minX, y: above ? selected.maxY + 8 : selected.maxY - size.height - 8)
            }
            label.frame = CGRect(origin: CGPoint(x: max(8, min(origin.x, area.width - size.width - 8)).rounded(), y: max(8, origin.y).rounded()), size: size)
        } else {
            crosshair[0].frame = CGRect(x: pointer.x.rounded(), y: 0, width: 1, height: area.height)
            crosshair[1].frame = CGRect(x: 0, y: pointer.y.rounded() - 1, width: area.width, height: 1)
        }
        loupe.isHidden = !showsMagnifier || loupeImage == nil
        if !loupe.isHidden, let loupeImage {
            let size = loupe.frame.size == .zero ? LoupeView.size : loupe.frame.size
            let gap: CGFloat = 8
            let x = pointer.x + gap + size.width > area.width ? pointer.x - gap - size.width : pointer.x + gap
            let y = pointer.y - gap - size.height < 0 ? pointer.y + gap : pointer.y - gap - size.height
            loupe.frame = CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
            let scaleX = CGFloat(loupeImage.width) / max(1, area.width)
            let scaleY = CGFloat(loupeImage.height) / max(1, area.height)
            loupe.show(loupeImage, at: CGPoint(x: floor(pointer.x * scaleX), y: floor((area.height - pointer.y) * scaleY)),
                       coordinate: CGPoint(x: screenFrame.minX + pointer.x, y: screenFrame.maxY - pointer.y))
        }
        if let selected { setAccessibilityValue("\(Int(selected.width)) by \(Int(selected.height))") }
    }
}

private final class PillView: NSView {
    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
    ]
    var text = "" {
        didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var fittingSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: Self.attributes).width) + 14, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(text, in: bounds)
    }

    static func draw(_ text: String, in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

// nearest-neighbour crop of the display still, small enough to redraw on every move
private final class LoupeView: NSView {
    static let pixels = 15
    static let side: CGFloat = 120
    static let margin: CGFloat = 12
    static let size = CGSize(width: side + margin * 2, height: side + margin * 2 + 26)
    private var image: CGImage?
    private var center = CGPoint.zero
    private var coordinate = CGPoint.zero

    override var isOpaque: Bool { false }

    func show(_ image: CGImage, at center: CGPoint, coordinate: CGPoint) {
        guard image !== self.image || center != self.center else { return }
        self.image = image
        self.center = center
        self.coordinate = coordinate
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let count = Self.pixels
        let unit = Self.side / CGFloat(count)
        let loupe = CGRect(x: Self.margin, y: bounds.height - Self.margin - Self.side, width: Self.side, height: Self.side)
        let sample = CGRect(x: center.x - CGFloat(count / 2), y: center.y - CGFloat(count / 2), width: CGFloat(count), height: CGFloat(count))
        let clip = sample.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let shape = CGPath(roundedRect: loupe, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if !clip.isEmpty, let crop = image.cropping(to: clip) {
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: loupe.minX + (clip.minX - sample.minX) * unit,
                                          y: loupe.maxY - (clip.maxY - sample.minY) * unit,
                                          width: clip.width * unit, height: clip.height * unit))
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
        context.setLineWidth(1)
        for step in 1..<count {
            let offset = (CGFloat(step) * unit).rounded()
            context.move(to: CGPoint(x: loupe.minX + offset, y: loupe.minY))
            context.addLine(to: CGPoint(x: loupe.minX + offset, y: loupe.maxY))
            context.move(to: CGPoint(x: loupe.minX, y: loupe.minY + offset))
            context.addLine(to: CGPoint(x: loupe.maxX, y: loupe.minY + offset))
        }
        context.strokePath()
        let middle = CGRect(x: loupe.minX + CGFloat(count / 2) * unit, y: loupe.minY + CGFloat(count / 2) * unit, width: unit, height: unit)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        context.stroke(middle.insetBy(dx: -1, dy: -1), width: 1)
        context.setStrokeColor(.white)
        context.stroke(middle, width: 1)
        context.restoreGState()
        context.addPath(CGPath(roundedRect: loupe.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        context.setLineWidth(1)
        context.strokePath()
        let text = "\(Int(coordinate.x)), \(Int(coordinate.y))"
        let width = ceil((text as NSString).size(withAttributes: PillView.attributes).width) + 14
        PillView.draw(text, in: CGRect(x: (loupe.midX - width / 2).rounded(), y: loupe.minY - 26, width: width, height: 20))
    }
}

@MainActor @Observable
final class CaptureBarModel {
    let allInOne: Bool
    let allowsRecording: Bool
    var mode: CaptureMode = .area
    var recording = false
    var options = RecordingOptions.saved()
    // a frozen screen already ran its countdown before the bar opened
    var timerApplies = true
    @ObservationIgnored var onMode: (CaptureMode) -> Void = { _ in }
    @ObservationIgnored var onRecording: (Bool) -> Void = { _ in }
    @ObservationIgnored var onCapture: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onResize: (CGSize) -> Void = { _ in }

    init(allInOne: Bool, allowsRecording: Bool) {
        self.allInOne = allInOne
        self.allowsRecording = allowsRecording
    }
}

struct CaptureBar: View {
    @Bindable var model: CaptureBarModel
    @AppStorage("captureDelay") private var delay = 0

    private var modes: [CaptureMode] { model.recording ? [.area, .fullScreen, .window] : [.area, .fullScreen, .window, .scrolling, .text] }

    // pick what, then go; settings read as quiet values beside the one action
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 2) { ForEach(modes) { modeTile($0) } }
            Divider().padding(.vertical, 10)
            if model.recording {
                RecordingBarControls(options: $model.options)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            footer
        }
        .padding(12)
        .frame(width: 420)
        // the shadow belongs to the card alone, on the whole view it haloes every label
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .fixedSize()
        .padding(20)
        .animation(.snappy(duration: 0.2), value: model.recording)
        .animation(.snappy(duration: 0.16), value: model.mode)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.onResize($0) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.allowsRecording {
                Segmented {
                    kind("Screenshot", selected: !model.recording) { model.onRecording(false) }
                    kind("Record", selected: model.recording) { model.onRecording(true) }
                }
            }
            Spacer(minLength: 8)
            Button(action: model.onCancel) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 24, height: 24)))
                .help("Close")
                .accessibilityLabel("Close")
        }
        .padding(.bottom, 10)
    }

    private func modeTile(_ mode: CaptureMode) -> some View {
        Button { model.onMode(mode) } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(name(mode)).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ToolButtonStyle(selected: model.mode == mode, size: CGSize(width: 0, height: 50)))
        .help(name(mode))
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if model.recording {
                FlatPicker(selection: $model.options.format, options: [("Video", RecordingFormat.video), ("GIF", .gif)], quiet: true)
                FlatPicker(selection: $model.options.framesPerSecond, options: [("24 fps", 24), ("30 fps", 30), ("60 fps", 60)], quiet: true)
                FlatPicker(selection: $model.options.maximumDimension, options: [("1080p", 1920), ("1440p", 2560), ("4K", 3840)], quiet: true)
                FlatPicker(selection: $model.options.countdown, options: Self.countdowns, symbol: "timer", quiet: true).help("Countdown before recording starts")
            } else if model.timerApplies {
                FlatPicker(selection: $delay, options: Self.timers, symbol: "timer", quiet: true).help("Timer")
            }
            Spacer(minLength: 8)
            Button(action: model.onCapture) {
                if model.recording { Label("Record", systemImage: "record.circle") } else { Text("Capture") }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private static let timers: [(String, Int)] = [("No Timer", 0), ("3 Seconds", 3), ("5 Seconds", 5), ("10 Seconds", 10)]
    private static let countdowns: [(String, Int)] = [("Off", 0), ("3s", 3), ("5s", 5), ("10s", 10)]

    private func kind(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12) }
            .buttonStyle(ToolButtonStyle(selected: selected, size: CGSize(width: 0, height: 24), tint: .primary))
            .fixedSize()
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tool(_ symbol: String, help: String, selected: Bool = false, segment: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(segment ? ToolButtonStyle(selected: selected, size: CGSize(width: 30, height: 24), tint: .primary) : ToolButtonStyle(selected: selected))
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func name(_ mode: CaptureMode) -> String {
        switch mode {
        case .area: return "Area"
        case .fullScreen: return "Screen"
        case .window: return "Window"
        case .scrolling: return "Scrolling"
        case .text: return "Text"
        default: return mode.title
        }
    }
}
