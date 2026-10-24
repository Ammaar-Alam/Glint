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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialSize(for: url)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "\(url.deletingPathExtension().lastPathComponent) — Glint"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // an empty unified toolbar gives the title bar the height of the editor's top bar
        window.toolbar = NSToolbar(identifier: "ImageEditor")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = StaticHostingView(rootView: ImageEditorView(model: model, actions: EditorActions(
            export: { [weak self] in self?.exportImage() }, saveProject: { [weak self] in self?.saveProject() },
            printImage: { [weak self] in self?.printImage() }, pin: { [weak self] in self?.pinImage() },
            capture: { [weak self] in self?.captureImage() }, done: { [weak self] in self?.finishEditing() },
            share: { [weak self] in self?.share() }, flatten: { [weak self] in await self?.flattenedFile() })))
        model.onSaveProject = { [weak self] in self?.saveProject() }
        window.center()
    }

    // sized around the capture, within most of the screen and never below what the bars need
    private static func initialSize(for url: URL) -> NSSize {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let chrome = NSSize(width: 2 * 76, height: 52 + 44 + 2 * 56)
        var image = NSSize(width: 1200, height: 800)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 {
            image = NSSize(width: width / screen.backingScaleFactor, height: height / screen.backingScaleFactor)
        }
        let room = NSSize(width: screen.visibleFrame.width * 0.8 - chrome.width, height: screen.visibleFrame.height * 0.85 - chrome.height)
        let scale = min(1, room.width / image.width, room.height / image.height)
        return NSSize(width: max(900, (image.width * scale + chrome.width).rounded()), height: max(560, (image.height * scale + chrome.height).rounded()))
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
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

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
        if model.document != nil {
            do { _ = try model.finishedContents() }
            catch { model.errorMessage = error.localizedDescription; return false }
        }
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
        Task { if let url = await flattenedFile() { onPin(url) } }
    }

    // the edited image as a png named after the capture, for pin, share and drag
    func flattenedFile() async -> URL? {
        guard !model.busy, model.document != nil else { return nil }
        do {
            let contents = try model.finishedContents()
            let name = model.inputURL.deletingPathExtension().lastPathComponent
            model.busy = true
            defer { model.busy = false }
            return try await Task.detached(priority: .userInitiated) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(name).appendingPathExtension("png")
                try ImageFile.write(ImageRenderer.render(contents), to: url)
                return url
            }.value
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func share() {
        guard let view = window?.contentView else { return }
        Task {
            guard let url = await flattenedFile() else { return }
            let anchor = NSRect(x: view.bounds.maxX - 150, y: view.isFlipped ? view.bounds.maxY - 36 : 8, width: 28, height: 28)
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
        }
    }

    // saves edits back to the capture, a plain screenshot gets an edited copy so the original stays intact
    func finishEditing() {
        guard !model.busy, model.document != nil else { return }
        do { _ = try model.finishedContents() }
        catch { model.errorMessage = error.localizedDescription; return }
        guard model.hasUnsavedChanges else { close(); return }
        Task {
            do {
                let destination = try model.projectURL ?? {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    return folder.appendingPathComponent(model.inputURL.deletingPathExtension().lastPathComponent).appendingPathExtension("glint")
                }()
                try await model.saveProject(to: destination)
                // edits made while saving keep the editor open
                guard !model.hasUnsavedChanges else { return }
                closingAfterSave = true
                close()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func captureImage() {
        guard !model.busy, let onCapture else { return }
        do { _ = try model.finishedContents() }
        catch { model.errorMessage = error.localizedDescription; return }
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
        Task {
            do {
                let contents = try model.finishedContents()
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

struct EditorActions {
    let export: () -> Void
    let saveProject: () -> Void
    let printImage: () -> Void
    let pin: () -> Void
    let capture: () -> Void
    let done: () -> Void
    let share: () -> Void
    let flatten: () async -> URL?
}

extension AnnotationColor {
    static let palette: [AnnotationColor] = [
        .coral, AnnotationColor(red: 1, green: 0.58, blue: 0.1), AnnotationColor(red: 1, green: 0.82, blue: 0.1),
        AnnotationColor(red: 0.2, green: 0.78, blue: 0.35), AnnotationColor(red: 0.13, green: 0.82, blue: 0.92),
        AnnotationColor(red: 0.2, green: 0.45, blue: 1), AnnotationColor(red: 0.62, green: 0.35, blue: 0.95), .white, .ink
    ]
    static let paletteNames = ["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "White", "Black"]
}

private enum EditorTools {
    static let color: Set<AnnotationTool> = [.arrow, .doubleArrow, .curvedArrow, .line, .rectangle, .ellipse, .pen, .text, .counter, .highlight, .redact]
    // tools that share one strip button, the button keeps the last variant used
    static let families: [AnnotationTool: [AnnotationTool]] = [
        .arrow: [.arrow, .doubleArrow, .line], .rectangle: [.rectangle, .ellipse], .pixelate: [.blur, .pixelate, .redact]
    ]
    static let memory: [AnnotationTool: String] = [.arrow: "arrowTool", .rectangle: "shapeTool", .pixelate: "redactTool"]
    static let strip: [AnnotationTool] = [.select, .arrow, .rectangle, .pen, .text, .counter, .highlight, .spotlight, .pixelate]
    static let withOptions: Set<AnnotationTool> = [.arrow, .rectangle, .pen, .text, .counter, .highlight, .pixelate]

    static func members(_ key: AnnotationTool) -> [AnnotationTool] { families[key] ?? [key] }

    static func family(of tool: AnnotationTool) -> AnnotationTool { families.first { $0.value.contains(tool) }?.key ?? tool }

    static func remembered(_ key: AnnotationTool) -> AnnotationTool {
        memory[key].flatMap { UserDefaults.standard.string(forKey: $0) }.flatMap(AnnotationTool.init(rawValue:)) ?? key
    }

    static func remember(_ tool: AnnotationTool) {
        if let key = memory[family(of: tool)] { UserDefaults.standard.set(tool.rawValue, forKey: key) }
    }

    static func symbol(_ key: AnnotationTool, active: AnnotationTool) -> String {
        if key == .pixelate { return "checkerboard.rectangle" }
        return members(key).contains(active) ? active.symbol : remembered(key).symbol
    }
}

private struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    let actions: EditorActions
    @State private var sizePopover: ImageSizePopover?
    @Namespace private var toolSelection

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    ImageCanvas(model: model)
                    if model.document == nil, model.errorMessage == nil { ProgressView().controlSize(.large) }
                }
                .overlay(alignment: .leading) { ColorColumn(model: model).padding(.leading, 14) }
                .overlay(alignment: .top) {
                    Group {
                        if model.cropDraft != nil { cropBar }
                        else if let key = optionsKey { ToolOptionsBar(model: model, key: key).id(key) }
                    }
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
                if model.showsBackgroundPanel {
                    Divider()
                    BackgroundPanel(model: model).frame(width: 280).transition(.move(edge: .trailing))
                }
            }
            Divider()
            bottomBar
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeOut(duration: 0.18), value: model.showsBackgroundPanel)
        .animation(.easeOut(duration: 0.18), value: model.cropDraft != nil)
        .animation(.easeOut(duration: 0.16), value: optionsKey)
        .alert("Couldn’t finish", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // room for the window controls
            Color.clear.frame(width: 64, height: 1)
            HStack(spacing: 4) {
                Button { select(.crop) } label: { Image(systemName: "crop") }
                    .buttonStyle(ToolButtonStyle(selected: model.tool == .crop, prominent: true)).help("Crop  C")
                Button { model.importImage() } label: { Image(systemName: "photo.badge.plus") }
                    .buttonStyle(ToolButtonStyle()).help("Add Image")
                Button { model.showsBackgroundPanel.toggle() } label: { Image(systemName: "square.on.square.dashed") }
                    .buttonStyle(ToolButtonStyle(selected: model.showsBackgroundPanel)).help("Background")
            }
            Spacer(minLength: 8)
            toolStrip
            Spacer(minLength: 8)
            Button("Save As…", action: actions.export)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("e", modifiers: [.command])
            Button("Done", action: actions.done)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        // only the empty bar moves the window, so controls keep their drags
        .background { Rectangle().fill(.bar).gesture(WindowDragGesture()) }
        // menu items ignore keyboard shortcuts, so hidden buttons carry them
        .background(Group {
            Button("Print", action: actions.printImage).keyboardShortcut("p", modifiers: .command)
            Button("Copy", action: model.copyImage).keyboardShortcut("c", modifiers: [.command, .shift])
        }.hidden())
        .disabled(model.document == nil || model.busy)
    }

    // the strip never changes shape, the active tool's options float over the canvas
    private var toolStrip: some View {
        HStack(spacing: 2) {
            ForEach(EditorTools.strip) { key in
                let selected = EditorTools.members(key).contains(model.tool)
                Button { if !selected { select(EditorTools.remembered(key)) } } label: { Image(systemName: EditorTools.symbol(key, active: model.tool)) }
                    .buttonStyle(ToolButtonStyle(selected: selected, size: CGSize(width: 34, height: 30), prominent: true, drawsSelection: false))
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Color.glint)
                                .matchedGeometryEffect(id: "tool", in: toolSelection)
                        }
                    }
                    .help(Self.help(key))
                    .accessibilityLabel(key == .pixelate ? "Redact" : key.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control + 3, style: .continuous))
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.tool)
        .fixedSize()
    }

    // the tool whose options show, from the selection when there is one
    private var optionsKey: AnnotationTool? {
        let tools = model.selectedIDs.isEmpty ? [model.tool] : model.selectedAnnotations.map(\.tool)
        let keys = Set(tools.map(EditorTools.family(of:)))
        guard keys.count == 1, let key = keys.first, EditorTools.withOptions.contains(key) else { return nil }
        return key
    }

    private static func help(_ key: AnnotationTool) -> String {
        let name = key == .pixelate ? "Redact" : key == .rectangle ? "Shapes" : key == .arrow ? "Arrows" : key.title
        let shortcut = key.keyboardKey.map { "  \($0.uppercased())" } ?? ""
        return name + shortcut
    }

    // a new tool starts fresh, so its options show instead of the last mark's
    private func select(_ tool: AnnotationTool) {
        if tool != .select { model.select(nil) }
        model.tool = tool
        model.canvas?.window?.makeFirstResponder(model.canvas)
    }

    private static let cropRatios: [(String, Double)] = [("Free", 0), ("Square", 1), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2)]

    private var cropBar: some View {
        Island {
            FlatPicker(selection: $model.cropAspectRatio, options: Self.cropRatios)
            Button("Reset") { model.resetCrop() }.buttonStyle(ToolButtonStyle(size: CGSize(width: 54, height: 28))).font(.system(size: 12, weight: .medium))
            BarDivider()
            Button("Cancel") { model.cancelCrop() }.buttonStyle(SecondaryButtonStyle())
            Button("Apply") { select(.select) }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(ToolButtonStyle()).help("Undo").disabled(!model.undoManager.canUndo)
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(ToolButtonStyle()).help("Redo").disabled(!model.undoManager.canRedo)
            zoomMenu
            if let size = model.document?.outputSize {
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            DragHandle(flatten: actions.flatten)
            Spacer()
            Button(action: actions.share) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(ToolButtonStyle()).help("Share")
            Button(action: actions.pin) { Image(systemName: "pin") }
                .buttonStyle(ToolButtonStyle()).help("Pin").disabled(!model.canPin)
            Button(action: model.copyImage) { Image(systemName: "doc.on.doc") }
                .buttonStyle(ToolButtonStyle()).help("Copy  ⇧⌘C")
            moreMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
        .disabled(model.document == nil || model.busy)
    }

    private var zoomMenu: some View {
        Menu {
            Button("Fit") { model.canvas?.fitToWindow() }
            ForEach([0.5, 1.0, 2.0], id: \.self) { level in
                Button("\(Int(level * 100))%") { model.canvas?.setZoom(level) }
            }
            Divider()
            Button("Zoom In") { model.canvas?.zoom(by: 1.25) }
            Button("Zoom Out") { model.canvas?.zoom(by: 0.8) }
        } label: {
            Text(model.zoomLabel).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.button)
        .buttonStyle(ToolButtonStyle(size: CGSize(width: 58, height: 28)))
        .fixedSize()
        .help("Zoom")
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
                Button("Add Beside…") { model.importImage(beside: true) }
                Button("Capture Into Image", action: actions.capture).disabled(!model.canCapture)
            }
            Section {
                Button("Save Project…", action: actions.saveProject)
                Button("Print…", action: actions.printImage)
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
}

// options for the active tool or the selected marks, floating at the top of the canvas
private struct ToolOptionsBar: View {
    @ObservedObject var model: ImageEditorModel
    let key: AnnotationTool

    private var active: Set<AnnotationTool> { model.selectedIDs.isEmpty ? [model.tool] : Set(model.selectedAnnotations.map(\.tool)) }

    var body: some View {
        Island {
            if key == .arrow {
                ForEach(Self.arrows, id: \.name) { preset in
                    let selected = active.contains(preset.tool) && (preset.tool == .line || model.style.arrowStyle == preset.style)
                    Button { chooseArrow(preset.tool, style: preset.style) } label: {
                        ArrowPreview(tool: preset.tool, style: preset.style, color: model.style.color).frame(width: 26, height: 18)
                    }
                    .buttonStyle(ToolButtonStyle(selected: selected, size: CGSize(width: 36, height: 28)))
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                }
                BarDivider()
            } else if let variants = EditorTools.families[key] {
                ForEach(variants) { variant in
                    Button { choose(variant) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: variant == .redact ? "rectangle.fill" : variant.symbol)
                            Text(Self.label(variant))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(ToolButtonStyle(selected: active.contains(variant), size: CGSize(width: 0, height: 28)))
                    .fixedSize()
                }
                if key != .pixelate || !active.contains(.redact) { BarDivider() }
            }
            switch key {
            case .arrow, .pen:
                slider(symbol: "lineweight", help: "Thickness", in: 1...40)
            case .rectangle:
                slider(symbol: "lineweight", help: "Thickness", in: 1...40)
                Button { setFilled(!model.style.filled) } label: { Image(systemName: model.style.filled ? "square.fill" : "square") }
                    .buttonStyle(ToolButtonStyle(selected: model.style.filled)).help("Fill")
            case .pixelate:
                if !active.contains(.redact) { slider(symbol: "aqi.medium", help: "Strength", in: 2...40) }
            case .text:
                stepper
                BarDivider()
                Button { let bold = !model.style.bold; model.setStyle { $0.bold = bold } } label: { Image(systemName: "bold") }
                    .buttonStyle(ToolButtonStyle(selected: model.style.bold)).help("Bold")
                Button { let italic = !model.style.italic; model.setStyle { $0.italic = italic } } label: { Image(systemName: "italic") }
                    .buttonStyle(ToolButtonStyle(selected: model.style.italic)).help("Italic")
            case .counter: stepper
            case .highlight:
                Button { model.smartHighlight.toggle() } label: {
                    HStack(spacing: 5) { Image(systemName: "text.viewfinder"); Text("Snap to text") }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                }
                .buttonStyle(ToolButtonStyle(selected: model.smartHighlight, size: CGSize(width: 0, height: 28)))
                .fixedSize()
            default: EmptyView()
            }
        }
    }

    private static let arrows: [(name: String, tool: AnnotationTool, style: ArrowStyle)] = [
        ("Tapered", .arrow, .tapered), ("Solid", .arrow, .solid), ("Open", .arrow, .open), ("Double", .doubleArrow, .solid), ("Line", .line, .solid)
    ]

    private func chooseArrow(_ tool: AnnotationTool, style: ArrowStyle) {
        model.tool = tool
        model.beginAdjusting()
        defer { model.endAdjusting() }
        model.setStyle { $0.arrowStyle = style }
        EditorTools.remember(tool)
        let family = Set(EditorTools.members(.arrow) + [.curvedArrow])
        model.mutate("Change Style") { document in
            for index in document.annotations.indices where model.selectedIDs.contains(document.annotations[index].id) && family.contains(document.annotations[index].tool) {
                var item = document.annotations[index]
                if item.points.count == 3, let start = item.points.first, let end = item.points.last { item.points = [start, end] }
                item.tool = tool
                item.arrowStyle = tool == .line ? nil : style
                document.annotations[index] = item
            }
        }
    }

    private static func label(_ tool: AnnotationTool) -> String {
        switch tool {
        case .rectangle: return "Box"
        case .ellipse: return "Oval"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .redact: return "Solid"
        default: return tool.title
        }
    }

    // switching a variant also converts selected marks of the same family
    private func choose(_ variant: AnnotationTool) {
        model.tool = variant
        EditorTools.remember(variant)
        let family = Set(EditorTools.members(key))
        model.mutate("Change Style") { document in
            for index in document.annotations.indices where model.selectedIDs.contains(document.annotations[index].id) && family.contains(document.annotations[index].tool) {
                document.annotations[index].tool = variant
            }
        }
    }

    private func slider(symbol: String, help: String, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, model.style.lineWidth)) }, set: { setLineWidth($0.rounded()) }), in: range) { editing in
                if editing { model.beginAdjusting() } else { model.endAdjusting() }
            }
            .controlSize(.small)
            .frame(width: 110)
            Text("\(Int(model.style.lineWidth))").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .help(help)
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            Button { setFontSize(model.style.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 30, height: 28))).help("Smaller")
            Text("\(Int(model.style.fontSize))").font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(width: 32)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: model.style.fontSize)
            Button { setFontSize(model.style.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 30, height: 28))).help("Larger")
        }
    }

    private func setLineWidth(_ width: Double) { model.setStyle { $0.lineWidth = width } }
    private func setFilled(_ filled: Bool) { model.setStyle { $0.filled = filled } }
    private func setFontSize(_ size: Double) {
        let size = min(512, max(6, size))
        model.setStyle { $0.fontSize = size }
    }
}

// the real renderer drawing a small sample, so the choice looks exactly like the result
private struct ArrowPreview: View {
    let tool: AnnotationTool
    let style: ArrowStyle
    let color: AnnotationColor

    var body: some View {
        Canvas { context, size in
            let sample = ImageAnnotation(tool: tool, rect: .zero, points: [CGPoint(x: 5, y: size.height - 5), CGPoint(x: size.width - 5, y: 5)],
                                         color: color, lineWidth: 2.5, arrowStyle: style)
            context.withCGContext { ImageRenderer.drawAnnotation(sample, context: $0, imageBounds: CGRect(origin: .zero, size: size)) }
        }
    }
}

// always within reach on the canvas edge, 1 to 9 pick these from the keyboard
private struct ColorColumn: View {
    @ObservedObject var model: ImageEditorModel
    @State private var expanded = false

    private var active: Bool {
        let tools: Set<AnnotationTool> = model.selectedIDs.isEmpty ? [model.tool] : Set(model.selectedAnnotations.map(\.tool))
        return !tools.isDisjoint(with: EditorTools.color)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(spacing: 4) {
                ForEach(Array(AnnotationColor.palette.enumerated()), id: \.offset) { index, color in
                    ColorDot(color: color.nsColor, selected: model.style.color == color, size: 18) { model.setStyle { $0.color = color } }
                        .help("\(AnnotationColor.paletteNames[index])  \(index + 1)")
                        .accessibilityLabel(AnnotationColor.paletteNames[index])
                }
                Divider().frame(width: 18).padding(.vertical, 2)
                Button { expanded.toggle() } label: {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 18, height: 18)
                        .overlay(Image(systemName: expanded ? "chevron.left" : "chevron.right").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white).shadow(radius: 1))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("More Colors")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            if expanded {
                ColorPickerPanel(color: model.style.color.nsColor, onChange: { color in model.setStyle { $0.color = AnnotationColor(color) } },
                                 onEditing: { editing in editing ? model.beginAdjusting() : model.endAdjusting() })
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .leading).combined(with: .opacity), removal: .opacity))
            }
        }
        .opacity(active ? 1 : 0.4)
        .disabled(!active || model.document == nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: expanded)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

// drag the finished image into any app, rendered as the drag begins
private struct DragHandle: View {
    let flatten: () async -> URL?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.point.up.left.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.glint)
            Text("Drag image").font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .overlay(DragSource(flatten: flatten))
        .help("Drag into any app to share the image")
    }
}

private struct DragSource: NSViewRepresentable {
    let flatten: () async -> URL?
    func makeNSView(context: Context) -> DragSourceView { DragSourceView(flatten: flatten) }
    func updateNSView(_ view: DragSourceView, context: Context) { view.flatten = flatten }
}

@MainActor
final class DragSourceView: NSView, NSDraggingSource {
    var flatten: () async -> URL?
    private var downEvent: NSEvent?
    private var file: URL?
    private var dragging = false
    private var moved = false

    init(flatten: @escaping () async -> URL?) {
        self.flatten = flatten
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    // the current edits render on press, the drag starts once the file exists and the pointer has moved
    override func mouseDown(with event: NSEvent) {
        downEvent = event
        file = nil
        moved = false
        Task {
            let url = await flatten()
            guard downEvent === event else { return }
            file = url
            if moved { startDrag() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        moved = true
        startDrag()
    }

    private func startDrag() {
        guard !dragging, let file, let downEvent else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(contentsOf: file))
        beginDraggingSession(with: [item], event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) { downEvent = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        downEvent = nil
    }
}

private struct BackgroundPanel: View {
    @ObservedObject var model: ImageEditorModel
    @State private var wallpaperRequest: UUID?


    private static let ratios: [(title: String, ratio: Double)] = [("Auto", 0), ("1:1", 1), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3)]
    private var background: ImageBackground { model.document?.background ?? ImageBackground() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Background").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("Background", isOn: binding(\.enabled)).toggleStyle(FlatToggleStyle()).labelsHidden()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(0..<Wallpaper.count, id: \.self) { index in
                        swatch(selected: background.enabled && background.imageID == Wallpaper.id(index)) { applyWallpaper(index) } content: {
                            Image(nsImage: Wallpaper.thumbnails[index]).resizable().aspectRatio(contentMode: .fill)
                        }
                        .help(Wallpaper.names[index])
                        .accessibilityLabel(Wallpaper.names[index])
                    }
                    Button { model.chooseBackgroundImage() } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .overlay(Image(systemName: "photo.badge.plus").foregroundStyle(.secondary))
                            .frame(height: 40)
                            .padding(2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose Image")
                }
                saved
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Text("Fill")
                        Spacer()
                        ColorWellButton(color: background.color.nsColor) { setColor(\.color, $0) }
                        if background.gradient {
                            ColorWellButton(color: background.secondColor.nsColor) { setColor(\.secondColor, $0) }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                        Button { model.mutate("Background") { $0.background.gradient.toggle() } } label: { Image(systemName: "circle.lefthalf.filled") }
                            .buttonStyle(ToolButtonStyle(selected: background.gradient, size: CGSize(width: 28, height: 26))).help("Gradient")
                    }
                    .animation(.snappy(duration: 0.2), value: background.gradient)
                    if let id = background.imageID, Wallpaper.index(of: id) == nil {
                        Button("Remove Image") { model.mutate("Remove Background Image") { $0.background.imageID = nil } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    slider("Padding", value: binding(\.padding), range: 0...300)
                    slider("Inset", value: Binding(get: { background.inset ?? 0 }, set: { value in model.mutate("Inset") { $0.background.inset = value } }), range: 0...100) {
                        if (background.inset ?? 0) > 0 {
                            ColorWellButton(color: (background.insetColor ?? .white).nsColor) { value in
                                model.mutate("Inset Color") { $0.background.insetColor = AnnotationColor(value) }
                            }
                            .frame(height: 16)
                        }
                    }
                    slider("Corners", value: binding(\.cornerRadius), range: 0...100)
                    slider("Shadow", value: binding(\.shadow), range: 0...100)
                }
                VStack(alignment: .leading, spacing: 10) {
                    section("Layout")
                    HStack(spacing: 2) {
                        ForEach(Self.ratios, id: \.title) { title, ratio in
                            Button(title) { model.mutate("Background") { $0.background.aspectRatio = ratio } }
                                .buttonStyle(ToolButtonStyle(selected: background.aspectRatio == ratio, size: CGSize(width: 44, height: 26)))
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    HStack(spacing: 2) {
                        alignButton("align.horizontal.left", "Left") { model.alignContent(x: -1) }
                        alignButton("align.horizontal.right", "Right") { model.alignContent(x: 1) }
                        alignButton("align.vertical.top", "Top") { model.alignContent(y: -1) }
                        alignButton("align.vertical.bottom", "Bottom") { model.alignContent(y: 1) }
                        alignButton("scope", "Center") { model.alignContent(x: 0, y: 0) }
                    }
                }
            }
            .font(.system(size: 12))
            .padding(16)
        }
        // scrolled content stays under the editor's top bar
        .clipped()
        .background(.bar, ignoresSafeAreaEdges: [])
        .disabled(model.document == nil || model.busy)
    }

    // looks you keep, drawn as a small framed capture so they read as styles, not plain colors
    private var saved: some View {
        let isSaved = model.backgroundPresets.contains(background)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                section("Saved")
                Spacer()
                Button { withAnimation(.snappy(duration: 0.25)) { model.saveBackgroundPreset() } } label: {
                    Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "checkmark" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSaved ? Color.secondary : Color.glint)
                .disabled(isSaved || !background.enabled)
                .help("Save this look")
            }
            if model.backgroundPresets.isEmpty {
                Text("Keep a look to use it on any capture").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Array(model.backgroundPresets.enumerated()), id: \.offset) { index, preset in
                        swatch(selected: background == preset, height: 48) {
                            wallpaperRequest = nil
                            model.applyBackgroundPreset(preset)
                        } content: { StylePreview(style: preset) }
                        .contextMenu { Button("Remove") { withAnimation(.snappy(duration: 0.25)) { model.removeBackgroundPreset(at: index) } } }
                        .accessibilityLabel("Saved style \(index + 1)")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: model.backgroundPresets.count)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func applyWallpaper(_ index: Int) {
        var next = background
        next.enabled = true
        next.imageID = Wallpaper.id(index)
        let directory = ImageEditorModel.presetDirectory
        // a slower first pick must not land after a newer one
        let token = UUID()
        wallpaperRequest = token
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try Wallpaper.file(index, in: directory) }.value
                guard wallpaperRequest == token else { return }
                model.applyBackgroundPreset(next)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func swatch<Content: View>(selected: Bool, height: CGFloat = 40, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.glint : .clear, lineWidth: 2))
                .animation(.easeOut(duration: 0.15), value: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func slider<Accessory: View>(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                accessory()
                Spacer()
                Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range) { editing in
                if editing { model.beginAdjusting() } else { model.endAdjusting() }
            }
            .controlSize(.small)
        }
    }

    private func alignButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ToolButtonStyle(size: CGSize(width: 32, height: 26))).help(title)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ImageBackground, T>) -> Binding<T> {
        Binding(get: { background[keyPath: keyPath] }, set: { value in model.mutate("Background") { $0.background[keyPath: keyPath] = value } })
    }

    // a picked fill replaces any wallpaper, which would otherwise hide it
    private func setColor(_ keyPath: WritableKeyPath<ImageBackground, AnnotationColor>, _ color: NSColor) {
        model.mutate("Background Color") {
            $0.background[keyPath: keyPath] = AnnotationColor(color)
            $0.background.imageID = nil
            $0.background.enabled = true
        }
    }
}

// a saved look as a tiny framed capture on its own backdrop
private struct StylePreview: View {
    let style: ImageBackground

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack {
                if let id = style.imageID, let index = Wallpaper.index(of: id) {
                    Image(nsImage: Wallpaper.thumbnails[index]).resizable().aspectRatio(contentMode: .fill)
                } else if style.imageID != nil {
                    Color.primary.opacity(0.12).overlay(Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.secondary))
                } else {
                    LinearGradient(colors: [Color(nsColor: style.color.nsColor), Color(nsColor: (style.gradient ? style.secondColor : style.color).nsColor)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                RoundedRectangle(cornerRadius: max(1.5, style.cornerRadius / 100 * 7), style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.1 + style.shadow / 100 * 0.25), radius: 1 + style.shadow / 100 * 3, y: 1)
                    .padding(min(height * 0.32, 4 + style.padding / 300 * height * 0.4))
            }
        }
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
