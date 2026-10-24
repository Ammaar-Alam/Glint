import AppKit
import Combine
import SwiftUI

@MainActor
final class ImageCanvasView: NSView {
    let model: ImageEditorModel
    private var observation: AnyCancellable?
    private var gestureSnapshot: ImageDocument?
    private var dragOperation: DragOperation?
    private var startPoint = CGPoint.zero
    private var currentPoint = CGPoint.zero
    private var lastWindowPoint = CGPoint.zero
    private var spacePressed = false
    private var textEditor: AnnotationTextView?
    private var textContainer: NSScrollView?
    private var editingAnnotation: ImageAnnotation?
    // stays fitted to the window until the user zooms
    private var fitsWindow = true
    private var lastFittedSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []

    private enum DragOperation {
        // crop handles are 0 to 3 for corners, 4 to 7 for edges, -1 moves the frame, 8 draws a new one
        case draw(UUID), move, resize(Int, CGRect), marquee, crop(Int, CGRect), pan
    }

    init(model: ImageEditorModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        model.canvas = self
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityLabel("Image canvas")
        setAccessibilityRole(.image)
        setAccessibilityHelp("Choose a tool to annotate. Use V to select, drag corner handles to resize, and Space to pan.")
        observation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    var magnification: CGFloat { zoom }
    private var canvasRect: CGRect { CGRect(origin: CGPoint(x: 40, y: 40), size: model.displayDocument?.canvasSize ?? .zero) }

    func updateCanvasSize() {
        guard let document = model.displayDocument else { return }
        let newSize = CGSize(width: document.canvasSize.width + 80, height: document.canvasSize.height + 80)
        let resized = frame.size != newSize
        if resized { setFrameSize(newSize) }
        // refit only when the canvas grew or shrank, and never mid slider drag
        if resized || frame.size != lastFittedSize, fitsWindow, window != nil, !model.isAdjusting {
            lastFittedSize = frame.size
            fitToWindow()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let scroll = enclosingScrollView, window != nil {
            scroll.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.fitsWindow == true { self?.fitToWindow() } }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitsWindow = false }
            })
        }
        updateCanvasSize()
    }

    func fitToWindow() {
        updateCanvasSizeWithoutFitting()
        guard let scroll = enclosingScrollView, model.document != nil else { return }
        fitsWindow = true
        // screen margins clear the color column on the left, mirrored on the right to stay centered
        guard let size = model.displayDocument?.canvasSize, size.width > 0, size.height > 0 else { return }
        let room = CGSize(width: scroll.contentSize.width - 2 * 76, height: scroll.contentSize.height - 2 * 40)
        let level = min(room.width / size.width, room.height / size.height)
        scroll.setMagnification(min(scroll.maxMagnification, max(scroll.minMagnification, level)), centeredAt: CGPoint(x: bounds.midX, y: bounds.midY))
        updateZoomLabel()
    }

    private func updateCanvasSizeWithoutFitting() {
        guard let document = model.displayDocument else { return }
        setFrameSize(CGSize(width: document.canvasSize.width + 80, height: document.canvasSize.height + 80))
    }

    func zoom(by factor: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        fitsWindow = false
        scroll.setMagnification(min(scroll.maxMagnification, max(scroll.minMagnification, zoom * factor)),
                                centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        updateZoomLabel()
        model.refreshPreview()
    }

    func setZoom(_ level: CGFloat) {
        fitsWindow = false
        enclosingScrollView?.setMagnification(level, centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        updateZoomLabel()
        model.refreshPreview()
    }

    func actualSize() {
        fitsWindow = false
        enclosingScrollView?.setMagnification(1, centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        updateZoomLabel()
        model.refreshPreview()
    }

    func updateZoomLabel() { model.zoomLabel = "\(Int((zoom * 100).rounded()))%" }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.backdrop.setFill()
        dirtyRect.fill()
        guard let document = model.displayDocument, let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = canvasRect
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -3 / zoom), blur: 24 / zoom, color: CGColor(gray: 0, alpha: 0.28))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(imageRect)
        context.restoreGState()
        context.saveGState()
        context.clip(to: imageRect)
        context.setFillColor(CGColor(gray: 0.88, alpha: 1))
        context.fill(imageRect)
        let tile: CGFloat = 16
        let visible = dirtyRect.intersection(imageRect)
        if !visible.isNull {
            context.setFillColor(CGColor(gray: 0.96, alpha: 1))
            let xStart = Int(floor((visible.minX - imageRect.minX) / tile))
            let yStart = Int(floor((visible.minY - imageRect.minY) / tile))
            let xEnd = Int(ceil((visible.maxX - imageRect.minX) / tile))
            let yEnd = Int(ceil((visible.maxY - imageRect.minY) / tile))
            for y in yStart...yEnd {
                for x in xStart...xEnd where (x + y) % 2 == 0 {
                    context.fill(CGRect(x: imageRect.minX + CGFloat(x) * tile, y: imageRect.minY + CGFloat(y) * tile, width: tile, height: tile))
                }
            }
        }
        if let preview = model.preview { ImageRenderer.drawImage(preview, in: imageRect, context: context) }
        context.restoreGState()
        // a hairline keeps light captures from melting into the backdrop
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
        context.setLineWidth(1 / zoom)
        context.stroke(imageRect.insetBy(dx: -0.5 / zoom, dy: -0.5 / zoom))

        if let draft = model.cropDraft { drawCrop(draft, document: document, imageRect: imageRect, context: context) }
        if let bounds = model.selectionBounds, textEditor == nil, model.cropDraft == nil {
            let points = corners(of: bounds).map { canvasPoint($0, document: document) }
            context.saveGState()
            context.setStrokeColor(NSColor.glint.cgColor)
            context.setLineWidth(1.5 / zoom)
            context.beginPath()
            context.move(to: points[0])
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.closePath()
            context.strokePath()
            for point in points {
                let handle = CGRect(x: point.x - 4 / zoom, y: point.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(handle)
                context.stroke(handle)
            }
            context.restoreGState()
        }
        if let operation = dragOperation {
            switch operation {
            case .marquee:
                let selection = rectBetween(startPoint, currentPoint).applying(document.originalToCanvas).offsetBy(dx: 40, dy: 40)
                context.saveGState()
                context.setStrokeColor(NSColor.glint.cgColor)
                context.setLineWidth(1.5 / zoom)
                context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
                context.stroke(selection)
                context.restoreGState()
            default: break
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spacePressed ? .openHand : model.tool == .select ? .arrow : .crosshair)
    }

    private func originalPoint(_ event: NSEvent, document: ImageDocument) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - 40, y: point.y - 40).applying(document.originalToCanvas.inverted())
    }

    private func canvasPoint(_ point: CGPoint, document: ImageDocument) -> CGPoint {
        let mapped = point.applying(document.originalToCanvas)
        return CGPoint(x: mapped.x + 40, y: mapped.y + 40)
    }

    private func cropHandles(_ rect: CGRect) -> [CGPoint] {
        corners(of: rect) + [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                             CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    // a dragged crop edge, corner or frame, kept inside the image and to the chosen ratio
    private func cropRect(handle: Int, start: CGRect, bounds: CGRect, square: Bool) -> CGRect {
        let dx = currentPoint.x - startPoint.x, dy = currentPoint.y - startPoint.y
        if handle == -1 {
            let x = min(max(start.minX + dx, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + dy, bounds.minY), bounds.maxY - start.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: start.size)
        }
        let chosen = square ? 1 : model.cropAspectRatio
        let ratio = chosen > 0 ? (model.document?.quarterTurns ?? 0) % 2 == 0 ? chosen : 1 / chosen : nil
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case 0: minX += dx; minY += dy
        case 1: maxX += dx; minY += dy
        case 2: maxX += dx; maxY += dy
        case 3: minX += dx; maxY += dy
        case 4: minY += dy
        case 5: maxX += dx
        case 6: maxY += dy
        case 7: minX += dx
        default:
            // a new frame grows away from where the drag began
            return Self.fitCrop(rectBetween(startPoint, currentPoint), anchor: CGPoint(x: currentPoint.x < startPoint.x ? 1 : 0, y: currentPoint.y < startPoint.y ? 1 : 0),
                           ratio: ratio, widthLeads: true, bounds: bounds)
        }
        let rect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(8, abs(maxX - minX)), height: max(8, abs(maxY - minY)))
        // the side opposite the dragged handle stays put, edges keep the other axis centered
        let fx: CGFloat = [0, 3, 7].contains(handle) ? (minX < maxX ? 1 : 0) : [1, 2, 5].contains(handle) ? (maxX > minX ? 0 : 1) : 0.5
        let fy: CGFloat = [0, 1, 4].contains(handle) ? (minY < maxY ? 1 : 0) : [2, 3, 6].contains(handle) ? (maxY > minY ? 0 : 1) : 0.5
        return Self.fitCrop(rect, anchor: CGPoint(x: fx, y: fy), ratio: ratio, widthLeads: ![4, 6].contains(handle), bounds: bounds)
    }

    // applies the ratio around a fixed point, then shrinks both sides together until it fits the image
    static func fitCrop(_ rect: CGRect, anchor: CGPoint, ratio: Double?, widthLeads: Bool, bounds: CGRect) -> CGRect {
        let point = CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
        var size = rect.size
        if let ratio { if widthLeads { size.height = size.width / ratio } else { size.width = size.height * ratio } }
        var scale: CGFloat = 1
        if anchor.x > 0 { scale = min(scale, (point.x - bounds.minX) / (anchor.x * size.width)) }
        if anchor.x < 1 { scale = min(scale, (bounds.maxX - point.x) / ((1 - anchor.x) * size.width)) }
        if anchor.y > 0 { scale = min(scale, (point.y - bounds.minY) / (anchor.y * size.height)) }
        if anchor.y < 1 { scale = min(scale, (bounds.maxY - point.y) / ((1 - anchor.y) * size.height)) }
        size = CGSize(width: size.width * max(0, scale), height: size.height * max(0, scale))
        return CGRect(x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height, width: size.width, height: size.height).intersection(bounds)
    }

    // the dimmed outside, a thin frame with thirds and bold handles
    private func drawCrop(_ draft: CGRect, document: ImageDocument, imageRect: CGRect, context: CGContext) {
        let frame = draft.applying(document.originalToCanvas).offsetBy(dx: 40, dy: 40)
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.5))
        context.addRect(imageRect)
        context.addRect(frame)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.4))
        context.setLineWidth(1 / zoom)
        for third in [1.0 / 3, 2.0 / 3] {
            context.move(to: CGPoint(x: frame.minX + frame.width * third, y: frame.minY))
            context.addLine(to: CGPoint(x: frame.minX + frame.width * third, y: frame.maxY))
            context.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * third))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * third))
        }
        context.strokePath()
        context.setStrokeColor(.white)
        context.setLineWidth(1.5 / zoom)
        context.stroke(frame)
        let arm = min(22 / zoom, frame.width / 3, frame.height / 3), weight = 4 / zoom
        context.setLineWidth(weight)
        context.setLineCap(.round)
        for (corner, sx, sy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                                 (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0), (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0)] {
            context.move(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
            context.addLine(to: corner)
            context.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
        }
        for (center, horizontal) in [(CGPoint(x: frame.midX, y: frame.minY), true), (CGPoint(x: frame.midX, y: frame.maxY), true),
                                     (CGPoint(x: frame.minX, y: frame.midY), false), (CGPoint(x: frame.maxX, y: frame.midY), false)] {
            context.move(to: horizontal ? CGPoint(x: center.x - arm / 2, y: center.y) : CGPoint(x: center.x, y: center.y - arm / 2))
            context.addLine(to: horizontal ? CGPoint(x: center.x + arm / 2, y: center.y) : CGPoint(x: center.x, y: center.y + arm / 2))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    override func mouseDown(with event: NSEvent) {
        if textEditor != nil { finishText(cancelled: false) }
        window?.makeFirstResponder(self)
        guard !model.busy, let document = model.document else { return }
        let point = originalPoint(event, document: document)
        startPoint = point
        currentPoint = point
        lastWindowPoint = event.locationInWindow
        gestureSnapshot = document
        if spacePressed { dragOperation = .pan; NSCursor.closedHand.set(); return }
        if let draft = model.cropDraft, let shown = model.displayDocument {
            let point = originalPoint(event, document: shown)
            startPoint = point
            currentPoint = point
            let reach = 12 / zoom
            if let handle = cropHandles(draft).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < reach }) {
                dragOperation = .crop(handle, draft)
            } else { dragOperation = .crop(draft.contains(point) ? -1 : 8, draft) }
            return
        }

        if model.tool == .select {
            if let selection = model.selectionBounds,
               let handle = corners(of: selection).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 9 / zoom }) {
                dragOperation = .resize(handle, selection)
                return
            }
            let hit = document.renderingAnnotations.last { $0.bounds.insetBy(dx: -6 / zoom, dy: -6 / zoom).contains(point) }
            if event.clickCount == 2, let hit, hit.tool == .text {
                model.select(hit.id)
                beginText(hit, at: point)
                return
            }
            if let hit {
                if !model.selectedIDs.contains(hit.id) || event.modifierFlags.contains(.shift) {
                    model.select(hit.id, extending: event.modifierFlags.contains(.shift))
                }
                dragOperation = .move
            } else {
                model.select(nil, extending: event.modifierFlags.contains(.shift))
                dragOperation = .marquee
            }
            needsDisplay = true
            return
        }
        guard document.cropRect.contains(point) else { return }
        // clicking an existing mark of the active tool picks it up instead of stacking a new one
        if model.tool != .crop, let hit = document.renderingAnnotations.last(where: { $0.tool == model.tool && $0.hitTest(point, tolerance: 6 / zoom) }) {
            model.select(hit.id)
            dragOperation = .move
            needsDisplay = true
            return
        }
        model.selectedIDs = []
        if model.tool == .image { model.importImage(); return }
        if model.tool == .text { beginText(nil, at: point); return }
        var annotation = model.newAnnotation(tool: model.tool, at: point)
        if model.tool == .counter {
            let side = max(32, model.fontSize * 1.6)
            annotation.rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            model.mutate("Add Counter") { $0.annotations.append(annotation) }
            model.selectedIDs = [annotation.id]
            return
        }
        if [.pen, .arrow, .doubleArrow, .curvedArrow, .line].contains(model.tool) { annotation.points = [point, point] }
        var next = document
        next.annotations.append(annotation)
        model.updateGesture(next)
        dragOperation = .draw(annotation.id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let operation = dragOperation, let snapshot = gestureSnapshot else { return }
        currentPoint = originalPoint(event, document: snapshot)
        let shift = event.modifierFlags.contains(.shift)
        switch operation {
        case .pan:
            guard let scroll = enclosingScrollView else { return }
            let delta = CGPoint(x: event.locationInWindow.x - lastWindowPoint.x, y: event.locationInWindow.y - lastWindowPoint.y)
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: CGPoint(x: origin.x - delta.x / zoom, y: origin.y + delta.y / zoom))
            scroll.reflectScrolledClipView(scroll.contentView)
            lastWindowPoint = event.locationInWindow
        case .draw(let id):
            guard var next = model.document, let index = next.annotations.firstIndex(where: { $0.id == id }) else { return }
            var end = currentPoint
            let tool = next.annotations[index].tool
            if tool == .pen {
                let last = next.annotations[index].points.last ?? startPoint
                if hypot(end.x - last.x, end.y - last.y) > 0.5 && next.annotations[index].points.count < 100_000 {
                    next.annotations[index].points.append(end)
                }
            } else if [.arrow, .doubleArrow, .curvedArrow, .line].contains(tool) {
                if shift {
                    let distance = hypot(end.x - startPoint.x, end.y - startPoint.y)
                    let angle = (atan2(end.y - startPoint.y, end.x - startPoint.x) / (.pi / 4)).rounded() * (.pi / 4)
                    end = CGPoint(x: startPoint.x + distance * cos(angle), y: startPoint.y + distance * sin(angle))
                }
                if tool == .curvedArrow {
                    next.annotations[index].points = [startPoint, CGPoint(x: end.x, y: startPoint.y), end]
                } else { next.annotations[index].points = [startPoint, end] }
            } else {
                if shift {
                    let length = max(abs(end.x - startPoint.x), abs(end.y - startPoint.y))
                    end = CGPoint(x: startPoint.x + (end.x >= startPoint.x ? length : -length),
                                  y: startPoint.y + (end.y >= startPoint.y ? length : -length))
                }
                next.annotations[index].rect = rectBetween(startPoint, end)
            }
            model.updateGesture(next)
        case .move:
            var next = snapshot
            var dx = currentPoint.x - startPoint.x, dy = currentPoint.y - startPoint.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            for index in next.annotations.indices where model.selectedIDs.contains(next.annotations[index].id) {
                next.annotations[index].move(dx: dx, dy: dy)
            }
            model.updateGesture(next)
        case .resize(let handle, let bounds):
            let opposite = corners(of: bounds)[(handle + 2) % 4]
            var end = currentPoint
            if shift {
                let ratio = bounds.width / max(1, bounds.height)
                let width = abs(end.x - opposite.x)
                end.y = opposite.y + (end.y >= opposite.y ? width / ratio : -width / ratio)
            }
            var newBounds = rectBetween(opposite, end)
            newBounds.size.width = max(2, newBounds.width)
            newBounds.size.height = max(2, newBounds.height)
            var next = snapshot
            for index in next.annotations.indices where model.selectedIDs.contains(next.annotations[index].id) {
                next.annotations[index].resize(from: bounds, to: newBounds)
            }
            model.updateGesture(next)
        case .crop(let handle, let start):
            guard let shown = model.displayDocument else { return }
            currentPoint = originalPoint(event, document: shown)
            model.setCropDraft(cropRect(handle: handle, start: start, bounds: ImageEditorModel.cropBounds(shown), square: shift))
            needsDisplay = true
        case .marquee: needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let operation = dragOperation, let snapshot = gestureSnapshot else { return }
        switch operation {
        case .draw(let id):
            if let item = model.document?.annotations.first(where: { $0.id == id }),
               max(item.bounds.width, item.bounds.height) < 2 {
                model.cancelGesture(restoring: snapshot)
            } else {
                if model.document?.annotations.first(where: { $0.id == id })?.tool == .highlight,
                   !event.modifierFlags.contains(.command) { model.snapHighlight(id) }
                model.finishGesture(from: snapshot, action: "Add Annotation")
                if model.document?.annotations.contains(where: { $0.id == id }) == true { model.selectedIDs = [id] }
            }
        case .move: model.finishGesture(from: snapshot, action: "Move")
        case .resize: model.finishGesture(from: snapshot, action: "Resize")
        case .crop: break
        case .marquee:
            let rect = rectBetween(startPoint, currentPoint)
            model.selectedIDs.formUnion(snapshot.annotations.filter { rect.intersects($0.bounds) }.map(\.id))
        case .pan: NSCursor.openHand.set()
        }
        dragOperation = nil
        gestureSnapshot = nil
        needsDisplay = true
    }

    private func beginText(_ existing: ImageAnnotation?, at point: CGPoint) {
        guard let document = model.document else { return }
        var annotation = existing ?? model.newAnnotation(tool: .text, at: point)
        if existing == nil {
            annotation.rect.size = CGSize(width: min(400, max(100, document.cropRect.maxX - point.x)), height: max(100, model.fontSize * 4))
        }
        editingAnnotation = annotation
        let frame = annotation.rect.applying(document.originalToCanvas).offsetBy(dx: 40, dy: 40)
        // typing happens in place over the image, outlined but not boxed in white
        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.wantsLayer = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.glint.cgColor
        scroll.layer?.cornerRadius = 4
        let text = AnnotationTextView(frame: CGRect(origin: .zero, size: frame.size))
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: annotation.fontSize, weight: annotation.bold ? .bold : .regular)
        text.textColor = annotation.color.nsColor
        text.drawsBackground = false
        text.insertionPointColor = annotation.color.nsColor
        text.string = annotation.text
        text.textContainerInset = CGSize(width: 4, height: 4)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.finish = { [weak self] cancelled in self?.finishText(cancelled: cancelled) }
        scroll.documentView = text
        addSubview(scroll)
        textContainer = scroll
        textEditor = text
        window?.makeFirstResponder(text)
        text.selectAll(nil)
        model.status = "⌘ Return to finish · Escape to cancel"
    }

    private func finishText(cancelled: Bool) {
        guard let editor = textEditor, var annotation = editingAnnotation else { return }
        if !cancelled, !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotation.text = editor.string
            let used = editor.layoutManager?.usedRect(for: editor.textContainer!) ?? .zero
            annotation.rect.size.height = max(annotation.fontSize * 1.4, used.height + 12)
            model.mutate("Edit Text") { document in
                if let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) { document.annotations[index] = annotation }
                else { document.annotations.append(annotation) }
            }
            model.selectedIDs = [annotation.id]
        }
        textContainer?.removeFromSuperview()
        textContainer = nil
        textEditor = nil
        editingAnnotation = nil
        model.status = ""
        window?.makeFirstResponder(self)
    }

    func commitEditing() {
        finishText(cancelled: false)
        // a pending crop counts once the image leaves the editor
        if model.tool == .crop { model.tool = .select }
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if command {
            switch key {
            case "z": shift ? model.undoManager.redo() : model.undoManager.undo()
            case "a": model.selectedIDs = Set(model.document?.annotations.map(\.id) ?? [])
            case "c": model.copySelection()
            case "x": model.copySelection(cut: true)
            case "v": model.paste()
            case "d": model.duplicateSelection()
            case "s": model.onSaveProject?()
            case "=", "+": zoom(by: 1.25)
            case "-": zoom(by: 0.8)
            case "0": fitToWindow()
            case "1": actualSize()
            default: super.keyDown(with: event)
            }
            return
        }
        if model.cropDraft != nil, [36, 76, 53].contains(event.keyCode) {
            if event.keyCode == 53 { model.cancelCrop() } else { model.tool = .select }
            return
        }
        switch event.keyCode {
        case 51, 117: model.deleteSelection()
        case 53:
            if let snapshot = gestureSnapshot { model.cancelGesture(restoring: snapshot) }
            gestureSnapshot = nil
            dragOperation = nil
            model.selectedIDs = []
            model.tool = .select
        case 123: model.nudgeSelection(dx: shift ? -10 : -1, dy: 0)
        case 124: model.nudgeSelection(dx: shift ? 10 : 1, dy: 0)
        case 125: model.nudgeSelection(dx: 0, dy: shift ? 10 : 1)
        case 126: model.nudgeSelection(dx: 0, dy: shift ? -10 : -1)
        default:
            if key == " " { spacePressed = true; NSCursor.openHand.set() }
            else if let digit = Int(key), AnnotationColor.palette.indices.contains(digit - 1) {
                model.setColor(AnnotationColor.palette[digit - 1])
            }
            else if let tool = AnnotationTool.allCases.first(where: { $0.keyboardKey == key }) {
                if tool == .crop { model.select(nil) }
                model.tool = tool
                window?.invalidateCursorRects(for: self)
            } else { super.keyDown(with: event) }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { spacePressed = false; window?.invalidateCursorRects(for: self) }
        else { super.keyUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document = model.document else { return nil }
        let point = originalPoint(event, document: document)
        if let item = document.renderingAnnotations.last(where: { $0.bounds.contains(point) }), !model.selectedIDs.contains(item.id) { model.select(item.id) }
        let menu = NSMenu()
        for (title, action) in [("Duplicate", #selector(duplicate)), ("Bring to Front", #selector(bringToFront)),
                                ("Send to Back", #selector(sendToBack)), ("Delete", #selector(deleteItems))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = !model.selectedIDs.isEmpty
            menu.addItem(item)
        }
        return menu
    }

    @objc private func duplicate() { model.duplicateSelection() }
    @objc private func bringToFront() { model.bringSelectionToFront() }
    @objc private func sendToBack() { model.sendSelectionToBack() }
    @objc private func deleteItems() { model.deleteSelection() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { model.busy ? [] : .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !model.busy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let document = model.document else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: location.x - 40, y: location.y - 40).applying(document.originalToCanvas.inverted())
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.forEach { model.addImage(url: $0, at: point) }
            return !urls.isEmpty
        }
        return false
    }
}

private final class AnnotationTextView: NSTextView {
    var finish: ((Bool) -> Void)?
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.finish?(false) } }
        return resigned
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(true) }
        else if event.keyCode == 36, event.modifierFlags.contains(.command) { finish?(false) }
        else { super.keyDown(with: event) }
    }
}

struct ImageCanvas: NSViewRepresentable {
    @ObservedObject var model: ImageEditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 8
        scroll.drawsBackground = true
        scroll.backgroundColor = .backdrop
        scroll.contentView = CenteringClipView()
        scroll.documentView = ImageCanvasView(model: model)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? ImageCanvasView)?.needsDisplay = true
    }
}

// keeps a document smaller than the viewport centered
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}
