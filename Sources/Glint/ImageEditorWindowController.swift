import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class ImageEditorWindowController: NSWindowController, NSWindowDelegate, EditorClosing {
    let model: ImageEditorModel
    var onPin: ((URL) -> Void)? { didSet { model.canPin = onPin != nil } }
    var onCapture: (() async -> URL?)? { didSet { model.canCapture = onCapture != nil } }
    private var closingAfterSave = false
    private var evaluatingClose = false

    init(url: URL, onExport: @escaping (URL) -> Void) {
        model = ImageEditorModel(url: url, onExport: onExport)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "\(url.deletingPathExtension().lastPathComponent) — Glint"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // an empty unified toolbar gives the title bar the height of the editor's top bar
        window.toolbar = NSToolbar(identifier: "ImageEditor")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1000, height: 620)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ImageEditorView(model: model,
            export: { [weak self] in self?.exportImage() }, save: { [weak self] in self?.saveProject() },
            printImage: { [weak self] in self?.printImage() }, pin: { [weak self] in self?.pinImage() },
            capture: { [weak self] in self?.captureImage() }))
        model.onSaveProject = { [weak self] in self?.saveProject() }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingAfterSave { return true }
        Task {
            if await prepareToClose() { closingAfterSave = true; close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { model.shutdown() }

    func prepareToClose() async -> Bool {
        guard !evaluatingClose, let window else { return false }
        evaluatingClose = true
        defer { evaluatingClose = false }
        if model.busy {
            let alert = NSAlert()
            alert.messageText = "An image operation is in progress"
            alert.informativeText = "Let it finish before closing this editor."
            await alert.beginSheetModal(for: window)
            return false
        }
        model.canvas?.commitEditing()
        guard model.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your edits?"
        alert.informativeText = "Save an editable project to keep working later."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        let response = await alert.beginSheetModal(for: window)
        if response == .alertSecondButtonReturn { return true }
        if response == .alertFirstButtonReturn {
            do { return try await saveProjectInteractively() }
            catch { model.errorMessage = error.localizedDescription }
        }
        return false
    }

    func saveProject(completion: (() -> Void)? = nil) {
        guard !model.busy, model.document != nil else { return }
        Task {
            do { if try await saveProjectInteractively() { completion?() } }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func saveProjectInteractively() async throws -> Bool {
        guard !model.busy, let window else { return false }
        let destination: URL
        if let existing = model.projectURL { destination = existing }
        else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(exportedAs: "app.glint.image-project", conformingTo: .package)]
            panel.nameFieldStringValue = model.inputURL.deletingPathExtension().lastPathComponent + ".glint"
            panel.message = "Projects keep original pixels and editable annotations. Export an image when sharing redacted content."
            panel.canCreateDirectories = true
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
            destination = url
        }
        try await model.saveProject(to: destination)
        return true
    }

    func exportImage() {
        guard !model.busy, let window, model.document != nil else { return }
        Task {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = model.inputURL.deletingPathExtension().lastPathComponent + ".png"
            let selector = ImageExportFormatSelector(panel: panel)
            panel.accessoryView = selector.view
            panel.allowedContentTypes = [selector.type]
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do { try await model.export(to: url, type: selector.type) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func pinImage() {
        guard !model.busy, let onPin else { return }
        model.canvas?.commitEditing()
        Task {
            do {
                let contents = try model.snapshot()
                model.busy = true
                defer { model.busy = false }
                let url = try await Task.detached(priority: .userInitiated) {
                    let url = ImageFile.temporaryURL()
                    try ImageFile.write(ImageRenderer.render(contents), to: url)
                    return url
                }.value
                onPin(url)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func captureImage() {
        guard !model.busy, let onCapture else { return }
        model.canvas?.commitEditing()
        model.busy = true
        window?.orderOut(nil)
        Task {
            let url = await onCapture()
            model.busy = false
            showWindow(nil)
            if let url { model.addImage(url: url, beside: true, ownsTemporary: true) }
        }
    }

    private func printImage() {
        guard !model.busy, let window else { return }
        model.canvas?.commitEditing()
        Task {
            do {
                let contents = try model.snapshot()
                model.busy = true
                defer { model.busy = false }
                let image = try await Task.detached(priority: .userInitiated) { try ImageRenderer.render(contents) }.value
                let view = ImagePrintView(image: image)
                let info = NSPrintInfo.shared.copy() as! NSPrintInfo
                info.horizontalPagination = .fit
                info.verticalPagination = .automatic
                info.isHorizontallyCentered = true
                let operation = NSPrintOperation(view: view, printInfo: info)
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private final class ImagePrintView: NSView {
    let image: CGImage
    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ImageRenderer.drawImage(image, in: bounds, context: context)
    }
}

@MainActor
private final class ImageExportFormatSelector: NSObject {
    let view = NSStackView()
    private let popup = NSPopUpButton()
    private let panel: NSSavePanel
    private let formats: [(String, UTType)]
    var type: UTType { formats[popup.indexOfSelectedItem].1 }

    init(panel: NSSavePanel) {
        self.panel = panel
        let supported = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        formats = [("PNG", UTType.png), ("JPEG", .jpeg), ("HEIC", .heic), ("TIFF", .tiff), ("WebP", .webP)]
            .filter { supported.contains($0.1.identifier) }
        super.init()
        popup.addItems(withTitles: formats.map(\.0))
        popup.target = self
        popup.action = #selector(changed)
        view.orientation = .horizontal
        view.spacing = 8
        view.addArrangedSubview(NSTextField(labelWithString: "Format:"))
        view.addArrangedSubview(popup)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
    }

    @objc private func changed() {
        panel.allowedContentTypes = [type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + (type.preferredFilenameExtension ?? "png")
    }
}

private enum ImageSizePopover: String, Identifiable {
    case image, canvas
    var id: String { rawValue }
}

private struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    let export: () -> Void
    let save: () -> Void
    let printImage: () -> Void
    let pin: () -> Void
    let capture: () -> Void
    @State private var sizePopover: ImageSizePopover?

    private static let toolGroups: [[AnnotationTool]] = [
        [.select], [.arrow, .curvedArrow, .line, .rectangle, .ellipse, .pen],
        [.text, .counter, .highlight], [.spotlight, .pixelate, .blur, .redact], [.crop, .image]
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    ImageCanvas(model: model)
                    if model.document == nil, model.errorMessage == nil { ProgressView().controlSize(.large) }
                }
                .overlay(alignment: .top) {
                    if model.document != nil, ToolOptions.isVisible(for: model) {
                        ToolOptions(model: model).padding(.top, 14).transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .overlay(alignment: .bottomLeading) { info.padding(14) }
                .overlay(alignment: .bottomTrailing) { zoomControls.padding(14) }
                if model.showsBackgroundPanel {
                    Divider()
                    BackgroundPanel(model: model).frame(width: 280).transition(.move(edge: .trailing))
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeOut(duration: 0.18), value: model.showsBackgroundPanel)
        .animation(.easeOut(duration: 0.15), value: ToolOptions.isVisible(for: model))
        .alert("Couldn’t finish", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            // room for the window controls
            Color.clear.frame(width: 64, height: 1)
            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(ToolButtonStyle()).help("Undo").disabled(!model.undoManager.canUndo)
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(ToolButtonStyle()).help("Redo").disabled(!model.undoManager.canRedo)
            Spacer(minLength: 12)
            toolStrip
            Spacer(minLength: 12)
            Button { model.showsBackgroundPanel.toggle() } label: { Image(systemName: "square.on.square.dashed") }
                .buttonStyle(ToolButtonStyle(selected: model.showsBackgroundPanel)).help("Background")
            moreMenu
            Button("Copy") { model.copyImage() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Export", action: export)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("e", modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
        .gesture(WindowDragGesture())
        .disabled(model.document == nil || model.busy)
    }

    private var toolStrip: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.toolGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 16).padding(.horizontal, 3) }
                ForEach(group) { tool in
                    Button {
                        if tool == .image { model.importImage() }
                        else {
                            if tool == .crop { model.select(nil) }
                            model.tool = tool
                            model.canvas?.window?.makeFirstResponder(model.canvas)
                        }
                    } label: { Image(systemName: tool.symbol) }
                    .buttonStyle(ToolButtonStyle(selected: model.tool == tool))
                    .help(tool.title + (tool.keyboardKey.map { "  \($0.uppercased())" } ?? ""))
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control + 3, style: .continuous))
        .fixedSize()
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("Rotate") { model.rotate() }
                Button("Flip Horizontal") { model.mutate("Flip Horizontal") { $0.flipHorizontal.toggle() } }
                Button("Flip Vertical") { model.mutate("Flip Vertical") { $0.flipVertical.toggle() } }
                Button("Resize…") { sizePopover = .image }
                Button("Canvas Size…") { sizePopover = .canvas }
            }
            Section {
                Button("Insert Image…") { model.importImage() }
                Button("Add Beside…") { model.importImage(beside: true) }
                Button("Capture Into Image", action: capture).disabled(!model.canCapture)
            }
            Section {
                Button("Pin", action: pin).disabled(!model.canPin)
                Button("Print…", action: printImage).keyboardShortcut("p", modifiers: .command)
                Button("Save Project…", action: save)
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ToolButtonStyle())
            .fixedSize()
            .help("More")
            .popover(item: $sizePopover) { item in
                switch item {
                case .image: ImageResizeView(model: model).padding(18)
                case .canvas: ImageCanvasSizeView(model: model).padding(18)
                }
            }
    }

    private var info: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.mini) }
            if let size = model.document?.outputSize {
                Text("\(Int(size.width)) × \(Int(size.height))").monospacedDigit()
            }
            if !model.status.isEmpty { Text(model.status).lineLimit(1) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .opacity(model.document == nil ? 0 : 1)
    }

    private var zoomControls: some View {
        Island {
            Button { model.canvas?.zoom(by: 0.8) } label: { Image(systemName: "minus") }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 26, height: 24))).help("Zoom Out")
            Button(model.zoomLabel) { model.canvas?.actualSize() }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 50, height: 24)))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .help("Actual Size")
            Button { model.canvas?.zoom(by: 1.25) } label: { Image(systemName: "plus") }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 26, height: 24))).help("Zoom In")
            Button { model.canvas?.fitToWindow() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 26, height: 24))).help("Fit")
        }
        .opacity(model.document == nil ? 0 : 1)
    }
}

// floating options for the active tool or the current selection
private struct ToolOptions: View {
    @ObservedObject var model: ImageEditorModel
    @State private var showsStrokeSlider = false

    static let palette: [AnnotationColor] = [
        .coral, AnnotationColor(red: 1, green: 0.58, blue: 0.1), AnnotationColor(red: 1, green: 0.82, blue: 0.1),
        AnnotationColor(red: 0.2, green: 0.78, blue: 0.35), AnnotationColor(red: 0.13, green: 0.89, blue: 0.96),
        AnnotationColor(red: 0.2, green: 0.45, blue: 1), AnnotationColor(red: 0.62, green: 0.35, blue: 0.95), .white, .ink
    ]
    private static let colorTools: Set<AnnotationTool> = [.arrow, .curvedArrow, .line, .rectangle, .ellipse, .pen, .text, .counter, .highlight, .redact]
    private static let strokeTools: Set<AnnotationTool> = [.arrow, .curvedArrow, .line, .rectangle, .ellipse, .pen]
    private static let strokes: [Double] = [3, 5, 8, 14]
    private static let cropRatios: [(title: String, ratio: Double)] = [("Free", 0), ("1:1", 1), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2)]

    private var tools: Set<AnnotationTool> {
        model.selectedIDs.isEmpty ? [model.tool] : Set(model.selectedAnnotations.map(\.tool))
    }

    private static let strengthTools: Set<AnnotationTool> = [.pixelate, .blur]

    static func isVisible(for model: ImageEditorModel) -> Bool {
        if model.tool == .crop || !model.selectedIDs.isEmpty { return true }
        return colorTools.contains(model.tool) || strengthTools.contains(model.tool)
    }

    var body: some View {
        Island {
            if model.tool == .crop { cropOptions } else {
                if !tools.isDisjoint(with: Self.colorTools) { swatches }
                if !tools.isDisjoint(with: Self.strokeTools) { separator; strokeOptions }
                if !tools.isDisjoint(with: Self.strengthTools) { strengthOptions }
                if !tools.isDisjoint(with: [.rectangle, .ellipse]) {
                    Button { setFilled(!model.filled) } label: { Image(systemName: model.filled ? "square.fill" : "square") }
                        .buttonStyle(ToolButtonStyle(selected: model.filled)).help("Fill")
                }
                if !tools.isDisjoint(with: [.text, .counter]) { separator; textOptions }
                if model.tool == .highlight && model.selectedIDs.isEmpty {
                    separator
                    Button { model.smartHighlight.toggle() } label: { Image(systemName: "text.alignleft") }
                        .buttonStyle(ToolButtonStyle(selected: model.smartHighlight)).help("Snap to Text")
                }
                if !model.selectedIDs.isEmpty { separator; selectionActions }
            }
        }
        .fixedSize()
    }

    private var separator: some View { Divider().frame(height: 18).padding(.horizontal, 4) }

    private var swatches: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, color in
                Button { setColor(color) } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(model.color == color ? Color.primary.opacity(0.85) : .clear, lineWidth: 1.5))
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(Self.palette.firstIndex(of: color).map { $0 + 1 } ?? 0)")
            }
            ColorWellButton(color: Self.palette.contains(model.color) ? nil : model.color.nsColor) { setColor(AnnotationColor($0)) }
        }
    }

    private var strokeOptions: some View {
        HStack(spacing: 2) {
            ForEach(Self.strokes, id: \.self) { width in
                Button { setLineWidth(width) } label: {
                    Circle().frame(width: 3 + width * 0.75, height: 3 + width * 0.75)
                }
                .buttonStyle(ToolButtonStyle(selected: model.lineWidth == width, size: CGSize(width: 28, height: 28)))
                .help("\(Int(width)) pt")
            }
            Button("\(Int(model.lineWidth))") { showsStrokeSlider.toggle() }
                .buttonStyle(ToolButtonStyle(selected: !Self.strokes.contains(model.lineWidth), size: CGSize(width: 30, height: 28)))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .help("Stroke Width")
                .popover(isPresented: $showsStrokeSlider, arrowEdge: .bottom) {
                    Slider(value: Binding(get: { model.lineWidth }, set: { setLineWidth($0.rounded()) }), in: 1...40)
                        .frame(width: 180).padding(14)
                }
        }
    }

    // line width drives pixel size and blur radius
    private var strengthOptions: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.lineWidth }, set: { setLineWidth($0.rounded()) }), in: 1...40)
                .controlSize(.small)
                .frame(width: 140)
                .accessibilityLabel("Strength")
            Image(systemName: "circle.grid.3x3.fill").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .help("Strength")
    }

    private var textOptions: some View {
        HStack(spacing: 2) {
            Button { setFontSize(model.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(ToolButtonStyle()).help("Smaller")
            Text("\(Int(model.fontSize))").font(.system(size: 11, weight: .semibold).monospacedDigit()).frame(width: 26)
            Button { setFontSize(model.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(ToolButtonStyle()).help("Larger")
            Button { model.bold.toggle(); let value = model.bold; model.changeStyle { $0.bold = value } } label: { Image(systemName: "bold") }
                .buttonStyle(ToolButtonStyle(selected: model.bold)).help("Bold")
            Button { model.italic.toggle(); let value = model.italic; model.changeStyle { $0.italic = value } } label: { Image(systemName: "italic") }
                .buttonStyle(ToolButtonStyle(selected: model.italic)).help("Italic")
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 2) {
            Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(ToolButtonStyle()).help("Duplicate")
            Button { model.bringSelectionToFront() } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                .buttonStyle(ToolButtonStyle()).help("Bring to Front")
            Button { model.sendSelectionToBack() } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                .buttonStyle(ToolButtonStyle()).help("Send to Back")
            Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                .buttonStyle(ToolButtonStyle()).help("Delete")
        }
    }

    private var cropOptions: some View {
        HStack(spacing: 2) {
            ForEach(Self.cropRatios, id: \.title) { title, ratio in
                Button(title) { model.cropAspectRatio = ratio }
                    .buttonStyle(ToolButtonStyle(selected: model.cropAspectRatio == ratio, size: CGSize(width: 44, height: 28)))
                    .font(.system(size: 12, weight: .medium))
            }
            separator
            Button { model.resetCrop() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(ToolButtonStyle()).help("Reset Crop")
        }
    }

    private func setColor(_ color: AnnotationColor) { model.color = color; model.changeStyle { $0.color = color } }
    private func setLineWidth(_ width: Double) { model.lineWidth = width; model.changeStyle { $0.lineWidth = width } }
    private func setFilled(_ filled: Bool) { model.filled = filled; model.changeStyle { $0.filled = filled } }
    private func setFontSize(_ size: Double) {
        let size = min(512, max(6, size))
        model.fontSize = size
        model.changeStyle { $0.fontSize = size }
    }
}

private struct BackgroundPanel: View {
    @ObservedObject var model: ImageEditorModel

    private static let gradients: [(AnnotationColor, AnnotationColor)] = [
        (AnnotationColor(red: 0.04, green: 0.5, blue: 0.7), AnnotationColor(red: 0.13, green: 0.89, blue: 0.96)),
        (AnnotationColor(red: 1, green: 0.42, blue: 0.36), AnnotationColor(red: 0.99, green: 0.76, blue: 0.36)),
        (AnnotationColor(red: 0.52, green: 0.26, blue: 0.86), AnnotationColor(red: 0.96, green: 0.37, blue: 0.6)),
        (AnnotationColor(red: 0.14, green: 0.3, blue: 0.86), AnnotationColor(red: 0.32, green: 0.76, blue: 0.96)),
        (AnnotationColor(red: 0.16, green: 0.72, blue: 0.52), AnnotationColor(red: 0.68, green: 0.93, blue: 0.6)),
        (AnnotationColor(red: 0.98, green: 0.6, blue: 0.56), AnnotationColor(red: 0.99, green: 0.87, blue: 0.78)),
        (AnnotationColor(red: 0.15, green: 0.16, blue: 0.2), AnnotationColor(red: 0.34, green: 0.36, blue: 0.43)),
        (AnnotationColor(red: 0.9, green: 0.91, blue: 0.94), AnnotationColor(red: 0.99, green: 0.99, blue: 1))
    ]

    private static let ratios: [(title: String, ratio: Double)] = [("Auto", 0), ("1:1", 1), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3)]
    private var background: ImageBackground { model.document?.background ?? ImageBackground() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Background").font(.headline)
                    Spacer()
                    Toggle("Background", isOn: binding(\.enabled)).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(Self.gradients.enumerated()), id: \.offset) { index, pair in
                        tile(top: pair.0, bottom: pair.1, selected: background.enabled && background.imageID == nil && background.gradient && background.color == pair.0 && background.secondColor == pair.1) {
                            model.mutate("Background") {
                                $0.background.enabled = true
                                $0.background.gradient = true
                                $0.background.imageID = nil
                                $0.background.color = pair.0
                                $0.background.secondColor = pair.1
                            }
                        }
                        .accessibilityLabel("Gradient \(index + 1)")
                    }
                    ForEach(Array(model.backgroundPresets.enumerated()), id: \.offset) { index, preset in
                        tile(top: preset.color, bottom: preset.gradient ? preset.secondColor : preset.color, selected: background == preset) {
                            model.applyBackgroundPreset(preset)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.white).padding(4).shadow(radius: 1)
                        }
                        .contextMenu { Button("Remove") { model.removeBackgroundPreset(at: index) } }
                        .accessibilityLabel("Saved style \(index + 1)")
                    }
                    Button { model.chooseBackgroundImage() } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                            .frame(height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose Image")
                }
                Group {
                    HStack {
                        Text("Colors")
                        Spacer()
                        ColorWellButton(color: background.color.nsColor) { setColor(\.color, $0) }
                        if background.gradient {
                            ColorWellButton(color: background.secondColor.nsColor) { setColor(\.secondColor, $0) }
                        }
                        Button { model.mutate("Background") { $0.background.gradient.toggle() } } label: { Image(systemName: "circle.lefthalf.filled") }
                            .buttonStyle(ToolButtonStyle(selected: background.gradient)).help("Gradient")
                    }
                    if background.imageID != nil {
                        Button("Remove Image") { model.mutate("Remove Background Image") { $0.background.imageID = nil } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    slider("Padding", value: binding(\.padding), range: 0...300)
                    slider("Inset", value: Binding(get: { background.inset ?? 0 }, set: { value in model.mutate("Inset") { $0.background.inset = value } }), range: 0...100)
                    if (background.inset ?? 0) > 0 {
                        HStack {
                            Text("Inset Color")
                            Spacer()
                            ColorWellButton(color: (background.insetColor ?? .white).nsColor) { value in
                                model.mutate("Inset Color") { $0.background.insetColor = AnnotationColor(value) }
                            }
                        }
                    }
                    slider("Corners", value: binding(\.cornerRadius), range: 0...100)
                    slider("Shadow", value: binding(\.shadow), range: 0...100)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ratio")
                        HStack(spacing: 2) {
                            ForEach(Self.ratios, id: \.title) { title, ratio in
                                Button(title) { model.mutate("Background") { $0.background.aspectRatio = ratio } }
                                    .buttonStyle(ToolButtonStyle(selected: background.aspectRatio == ratio, size: CGSize(width: 44, height: 26)))
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Position")
                        HStack(spacing: 2) {
                            alignButton("align.horizontal.left", "Left") { model.alignContent(x: -1) }
                            alignButton("align.horizontal.right", "Right") { model.alignContent(x: 1) }
                            alignButton("align.vertical.top", "Top") { model.alignContent(y: -1) }
                            alignButton("align.vertical.bottom", "Bottom") { model.alignContent(y: 1) }
                            alignButton("scope", "Center") { model.alignContent(x: 0, y: 0) }
                        }
                    }
                    Button("Save Style") { model.saveBackgroundPreset() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .disabled(!background.enabled)
                .opacity(background.enabled ? 1 : 0.45)
            }
            .font(.system(size: 12))
            .padding(16)
        }
        .background(.bar, ignoresSafeAreaEdges: [])
        .disabled(model.document == nil || model.busy)
    }

    private func tile(top: AnnotationColor, bottom: AnnotationColor, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: top.nsColor), Color(nsColor: bottom.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.glint : .clear, lineWidth: 2))
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range).controlSize(.small)
        }
    }

    private func alignButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ToolButtonStyle(size: CGSize(width: 32, height: 26))).help(title)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ImageBackground, T>) -> Binding<T> {
        Binding(get: { background[keyPath: keyPath] }, set: { value in model.mutate("Background") { $0.background[keyPath: keyPath] = value } })
    }

    private func setColor(_ keyPath: WritableKeyPath<ImageBackground, AnnotationColor>, _ color: NSColor) {
        model.mutate("Background Color") { $0.background[keyPath: keyPath] = AnnotationColor(color) }
    }
}

private struct ImageResizeView: View {
    @ObservedObject var model: ImageEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var width = 1.0
    @State private var height = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize").font(.headline)
            HStack {
                TextField("Width", value: $width, format: .number).frame(width: 90)
                    .onChange(of: width) { _, value in
                        if let size = model.document?.canvasSize { height = (value * size.height / size.width).rounded() }
                    }
                Text("×")
                Text(height.formatted(.number.precision(.fractionLength(0)))).frame(width: 70, alignment: .leading)
                Text("px").foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
            Text("Proportions stay the same.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("50%") { width = (model.document?.canvasSize.width ?? 1) * 0.5 }
                Button("100%") { width = Double(model.document?.canvasSize.width ?? 1) }
                Spacer()
                Button("Apply") {
                    if let size = model.document?.canvasSize {
                        model.mutate("Resize") { $0.outputScale = width / size.width }
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(!width.isFinite || width < 1 || height < 1 || width * height > 80_000_000)
            }
        }
        .frame(width: 280)
        .onAppear {
            width = Double(model.document?.outputSize.width ?? 1)
            height = Double(model.document?.outputSize.height ?? 1)
        }
    }
}

private struct ImageCanvasSizeView: View {
    @ObservedObject var model: ImageEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var width = 1.0
    @State private var height = 1.0
    @State private var centerContent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Canvas Size").font(.headline)
            HStack {
                TextField("Width", value: $width, format: .number).frame(width: 90)
                Text("×")
                TextField("Height", value: $height, format: .number).frame(width: 90)
                Text("px").foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
            Toggle("Keep content centered", isOn: $centerContent)
            HStack {
                Spacer()
                Button("Apply") {
                    model.mutate("Canvas Size") { document in
                        let size = document.quarterTurns % 2 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
                        let origin = centerContent ? CGPoint(x: document.cropRect.midX - size.width / 2,
                                                            y: document.cropRect.midY - size.height / 2) : document.cropRect.origin
                        document.cropRect = CGRect(origin: origin, size: size).integral
                    }
                    model.canvas?.fitToWindow()
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(!width.isFinite || !height.isFinite || width < 1 || height < 1 || width * height > 80_000_000)
            }
        }
        .frame(width: 290)
        .onAppear {
            width = Double(model.document?.contentSize.width ?? 1)
            height = Double(model.document?.contentSize.height ?? 1)
        }
    }
}
