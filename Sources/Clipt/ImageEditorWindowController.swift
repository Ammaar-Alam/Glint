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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(url.deletingPathExtension().lastPathComponent) — Clipt"
        window.minSize = NSSize(width: 880, height: 600)
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
            panel.allowedContentTypes = [UTType(exportedAs: "app.clipt.image-project", conformingTo: .package)]
            panel.nameFieldStringValue = model.inputURL.deletingPathExtension().lastPathComponent + ".clipt"
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
            if let url { model.addImage(url: url, beside: true) }
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                tools
                Divider()
                ZStack {
                    ImageCanvas(model: model)
                    if model.document == nil, model.errorMessage == nil {
                        ProgressView("Opening image…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Divider()
                inspector
            }
            Divider()
            footer
        }
        .alert("Couldn’t finish", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo (⌘Z)").disabled(!model.undoManager.canUndo)
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)").disabled(!model.undoManager.canRedo)
            Divider().frame(height: 20)
            Button { model.rotate() } label: { Label("Rotate", systemImage: "rotate.right") }
            Menu {
                Button("Horizontal") { model.mutate("Flip Horizontal") { $0.flipHorizontal.toggle() } }
                Button("Vertical") { model.mutate("Flip Vertical") { $0.flipVertical.toggle() } }
            } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .fixedSize()
            Menu {
                Button("Resize Image…") { sizePopover = .image }
                Button("Canvas Size…") { sizePopover = .canvas }
                Divider()
                Button("Insert Image…") { model.importImage() }
                Button("Add Beside…") { model.importImage(beside: true) }
                Button("Capture Image", action: capture).disabled(!model.canCapture)
            } label: { Label("Canvas", systemImage: "arrow.up.left.and.arrow.down.right") }
                .fixedSize()
                .popover(item: $sizePopover) { item in
                    switch item {
                    case .image: ImageResizeView(model: model).padding(18)
                    case .canvas: ImageCanvasSizeView(model: model).padding(18)
                    }
                }
            Menu {
                Button("Crop") { model.tool = .crop }
                Button("Reset Crop") { model.resetCrop() }
            } label: { Label("Crop", systemImage: "crop") }.fixedSize()
            Spacer()
            Menu {
                Button("Pin", action: pin).disabled(!model.canPin)
                Button("Print…", action: printImage).keyboardShortcut("p", modifiers: .command)
            } label: { Image(systemName: "ellipsis.circle") }.fixedSize().help("More actions")
            Button("Save Project", action: save).help("Save editable annotations (⌘S)")
            Button { model.copyImage() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Export…", action: export).buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: [.command])
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .disabled(model.document == nil || model.busy)
    }

    private var tools: some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button {
                        if tool == .image { model.importImage() }
                        else { model.tool = tool; model.canvas?.window?.makeFirstResponder(model.canvas) }
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 38, height: 32)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(model.tool == tool ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(tool.title + (tool.keyboardKey.map { " (\($0.uppercased()))" } ?? ""))
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }.padding(8)
        }
        .frame(width: 54)
        .background(.bar)
        .disabled(model.document == nil || model.busy)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.selectedIDs.isEmpty ? model.tool.title : "Selection").font(.headline)
                    if model.tool == .crop {
                        Picker("Ratio", selection: $model.cropAspectRatio) {
                            Text("Free").tag(0.0)
                            Text("Square").tag(1.0)
                            Text("16:9").tag(16.0 / 9)
                            Text("9:16").tag(9.0 / 16)
                            Text("4:3").tag(4.0 / 3)
                            Text("3:2").tag(3.0 / 2)
                        }
                    }
                    if model.tool == .highlight { Toggle("Snap to text", isOn: $model.smartHighlight) }
                    ColorPicker("Color", selection: Binding(get: { Color(nsColor: model.color.nsColor) }, set: { value in
                        model.color = AnnotationColor(NSColor(value))
                        model.changeStyle { $0.color = model.color }
                    }), supportsOpacity: false)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Stroke"); Spacer(); Text("\(Int(model.lineWidth))").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: Binding(get: { model.lineWidth }, set: { value in
                            model.lineWidth = value
                            model.changeStyle { $0.lineWidth = value }
                        }), in: 1...40, step: 1)
                    }
                    Toggle("Fill shapes", isOn: Binding(get: { model.filled }, set: { value in
                        model.filled = value
                        model.changeStyle { $0.filled = value }
                    }))
                    if model.tool == .text || model.tool == .counter || model.selectedAnnotations.contains(where: { $0.tool == .text || $0.tool == .counter }) {
                        Divider()
                        HStack {
                            Text("Text size")
                            Spacer()
                            TextField("Size", value: Binding(get: { model.fontSize }, set: { value in
                                let size = min(512, max(6, value))
                                model.fontSize = size
                                model.changeStyle { $0.fontSize = size }
                            }), format: .number).frame(width: 55).textFieldStyle(.roundedBorder)
                        }
                        Toggle("Bold", isOn: Binding(get: { model.bold }, set: { value in model.bold = value; model.changeStyle { $0.bold = value } }))
                        Toggle("Italic", isOn: Binding(get: { model.italic }, set: { value in model.italic = value; model.changeStyle { $0.italic = value } }))
                    }
                    if !model.selectedIDs.isEmpty {
                        HStack {
                            Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                            Button { model.bringSelectionToFront() } label: { Image(systemName: "square.3.layers.3d.top.filled") }.help("Bring to front")
                            Button { model.sendSelectionToBack() } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }.help("Send to back")
                            Spacer()
                            Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete")
                        }
                    }
                    if model.tool == .redact { Text("Solid cover for private details.").font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                backgroundInspector
            }
            .padding(16)
        }
        .frame(width: 218)
        .background(.bar)
        .disabled(model.document == nil || model.busy)
    }

    private var backgroundInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Background", isOn: backgroundBinding(\.enabled)).font(.headline)
            if model.document?.background.enabled == true {
                HStack {
                    Button("Choose Image…") { model.chooseBackgroundImage() }
                    if model.document?.background.imageID != nil {
                        Button { model.mutate("Remove Background Image") { $0.background.imageID = nil } } label: { Image(systemName: "xmark.circle") }
                            .help("Remove background image")
                    }
                }
                ColorPicker("Color", selection: Binding(get: { Color(nsColor: (model.document?.background.color ?? .ink).nsColor) }, set: { value in
                    model.mutate("Background Color") { $0.background.color = AnnotationColor(NSColor(value)) }
                }), supportsOpacity: false)
                Toggle("Gradient", isOn: backgroundBinding(\.gradient))
                if model.document?.background.gradient == true {
                    ColorPicker("Second color", selection: Binding(get: { Color(nsColor: (model.document?.background.secondColor ?? .ink).nsColor) }, set: { value in
                        model.mutate("Background Color") { $0.background.secondColor = AnnotationColor(NSColor(value)) }
                    }), supportsOpacity: false)
                }
                backgroundSlider("Padding", keyPath: \.padding, range: 0...300)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Inset"); Spacer(); Text("\(Int(model.document?.background.inset ?? 0))").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { model.document?.background.inset ?? 0 }, set: { value in
                        model.mutate("Inset") { $0.background.inset = value }
                    }), in: 0...100, step: 1)
                }
                if (model.document?.background.inset ?? 0) > 0 {
                    ColorPicker("Inset color", selection: Binding(get: { Color(nsColor: (model.document?.background.insetColor ?? .white).nsColor) }, set: { value in
                        model.mutate("Inset Color") { $0.background.insetColor = AnnotationColor(NSColor(value)) }
                    }), supportsOpacity: false)
                }
                backgroundSlider("Corners", keyPath: \.cornerRadius, range: 0...100)
                backgroundSlider("Shadow", keyPath: \.shadow, range: 0...100)
                Picker("Ratio", selection: backgroundBinding(\.aspectRatio)) {
                    Text("Auto").tag(0.0)
                    Text("Square").tag(1.0)
                    Text("16:9").tag(16.0 / 9)
                    Text("9:16").tag(9.0 / 16)
                    Text("4:3").tag(4.0 / 3)
                }
                HStack(spacing: 8) {
                    Button { model.alignContent(x: -1) } label: { Image(systemName: "align.horizontal.left") }.help("Align left")
                    Button { model.alignContent(x: 0, y: 0) } label: { Image(systemName: "scope") }.help("Center content")
                    Button { model.alignContent(x: 1) } label: { Image(systemName: "align.horizontal.right") }.help("Align right")
                    Button { model.alignContent(y: -1) } label: { Image(systemName: "align.vertical.top") }.help("Align top")
                    Button { model.alignContent(y: 1) } label: { Image(systemName: "align.vertical.bottom") }.help("Align bottom")
                }.buttonStyle(.borderless)
                HStack {
                    Menu("Presets") {
                        ForEach(Array(model.backgroundPresets.enumerated()), id: \.offset) { index, preset in
                            Button("Style \(index + 1)") { model.applyBackgroundPreset(preset) }
                        }
                        if !model.backgroundPresets.isEmpty {
                            Divider()
                            Menu("Remove") {
                                ForEach(Array(model.backgroundPresets.enumerated()), id: \.offset) { index, _ in
                                    Button("Style \(index + 1)") { model.removeBackgroundPreset(at: index) }
                                }
                            }
                        }
                    }.disabled(model.backgroundPresets.isEmpty)
                    Button("Save Style") { model.saveBackgroundPreset() }
                }
            }
        }
    }

    private func backgroundBinding<T>(_ keyPath: WritableKeyPath<ImageBackground, T>) -> Binding<T> {
        Binding(get: { (model.document?.background ?? ImageBackground())[keyPath: keyPath] },
                set: { value in model.mutate("Background") { $0.background[keyPath: keyPath] = value } })
    }

    private func backgroundSlider(_ title: String, keyPath: WritableKeyPath<ImageBackground, Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int((model.document?.background ?? ImageBackground())[keyPath: keyPath]))").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: backgroundBinding(keyPath), in: range, step: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let size = model.document?.outputSize {
                Text("\(Int(size.width)) × \(Int(size.height))").monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { model.canvas?.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Button(model.zoomLabel) { model.canvas?.actualSize() }.help("Actual size")
            Button { model.canvas?.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button("Fit") { model.canvas?.fitToWindow() }
        }
        .font(.caption).buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
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
