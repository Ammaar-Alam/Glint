import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct ImageAnnotationClipboard: Codable, Sendable {
    var annotations: [ImageAnnotation]
    var images: [UUID: Data]
}

private struct ImageClipboardContents: @unchecked Sendable {
    var annotations: [ImageAnnotation]
    var images: [UUID: CGImage]
}

@MainActor
final class ImageEditorModel: ObservableObject {
    @Published private(set) var document: ImageDocument?
    @Published private(set) var preview: CGImage?
    @Published var selectedIDs: Set<UUID> = []
    @Published var tool: AnnotationTool = .arrow { didSet { toolChanged(from: oldValue) } }
    // crop edits a draft over the whole image and applies it when the crop tool is left
    @Published private(set) var cropDraft: CGRect?
    @Published var color = EditorDefaults.color
    @Published var lineWidth = EditorDefaults.lineWidth
    @Published var fontSize: Double = 28
    @Published var filled = false
    @Published var bold = true
    @Published var italic = false
    @Published var busy = false
    @Published var status = "Opening image…"
    @Published var errorMessage: String?
    @Published var zoomLabel = "Fit"
    @Published var cropAspectRatio = 0.0 { didSet { fitCropDraftToRatio() } }
    @Published var smartHighlight = true
    @Published var arrowStyle = UserDefaults.standard.string(forKey: "arrowStyle").flatMap(ArrowStyle.init(rawValue:)) ?? .tapered {
        didSet { UserDefaults.standard.set(arrowStyle.rawValue, forKey: "arrowStyle") }
    }
    @Published var canCapture = false
    @Published var canPin = false
    @Published var backgroundPresets: [ImageBackground] = []
    @Published var showsBackgroundPanel = false

    let undoManager = UndoManager()
    let inputURL: URL
    var projectURL: URL?
    weak var canvas: ImageCanvasView?
    var onExport: (URL) -> Void
    var onSaveProject: (() -> Void)?

    private var source: CGImage?
    private var insertedImages: [UUID: CGImage] = [:]
    private var savedDocument: ImageDocument?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var renderRevision = 0
    private var isClosed = false
    private var textBoxes: [CGRect] = []
    private var backgroundLoadID = UUID()

    init(url: URL, onExport: @escaping (URL) -> Void) {
        inputURL = url
        self.onExport = onExport
        if url.pathExtension.lowercased() == "glint" { projectURL = url }
        if let data = UserDefaults.standard.data(forKey: "imageBackgroundPresets"),
           let presets = try? JSONDecoder().decode([ImageBackground].self, from: data) {
            backgroundPresets = presets.filter(\.isValid)
        }
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try ImageProject.load(url) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isClosed else { return }
                self.loadTask = nil
                switch result {
                case .success(let contents):
                    self.source = contents.source
                    self.insertedImages = contents.insertedImages
                    self.document = contents.document
                    self.savedDocument = contents.document
                    self.status = ""
                    self.refreshPreview()
                    self.canvas?.fitToWindow()
                    self.recognizeText(in: contents.source)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.status = "Couldn’t open image"
                }
            }
        }
    }

    deinit {
        loadTask?.cancel()
        renderTask?.cancel()
        ocrTask?.cancel()
    }

    func shutdown() {
        isClosed = true
        loadTask?.cancel(); loadTask = nil
        renderTask?.cancel(); renderTask = nil
        ocrTask?.cancel(); ocrTask = nil
        undoManager.removeAllActions()
        source = nil
        insertedImages.removeAll()
        preview = nil
        document = nil
        savedDocument = nil
        textBoxes.removeAll()
        onSaveProject = nil
    }

    private func recognizeText(in image: CGImage) {
        ocrTask = Task.detached(priority: .utility) { [weak self] in
            let boxes = (try? await ImageTextLayout.wordBoxes(in: image)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isClosed else { return }
                self.textBoxes = boxes
                self.ocrTask = nil
            }
        }
    }

    var hasUnsavedChanges: Bool { document != savedDocument }
    var selectedAnnotations: [ImageAnnotation] { document?.annotations.filter { selectedIDs.contains($0.id) } ?? [] }
    var selectionBounds: CGRect? {
        selectedAnnotations.map(\.bounds).reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
    }

    // what the canvas shows, the whole uncropped image without a background while cropping
    var displayDocument: ImageDocument? {
        guard var document, cropDraft != nil else { return document }
        document.cropRect = Self.cropBounds(document)
        document.background.enabled = false
        return document
    }

    static func cropBounds(_ document: ImageDocument) -> CGRect {
        CGRect(origin: .zero, size: document.sourceSize).union(document.cropRect)
    }

    private func toolChanged(from previous: AnnotationTool) {
        guard previous != tool else { return }
        if tool == .crop, let document {
            selectedIDs = []
            cropDraft = document.cropRect
            fitCropDraftToRatio()
            refreshPreview()
            canvas?.updateCanvasSize()
        } else if previous == .crop {
            applyCrop()
        }
    }

    func setCropDraft(_ rect: CGRect) { cropDraft = rect }

    private func applyCrop() {
        guard let draft = cropDraft else { return }
        cropDraft = nil
        if draft.integral != document?.cropRect { mutate("Crop") { $0.cropRect = draft.integral } }
        refreshPreview()
        canvas?.updateCanvasSize()
    }

    func cancelCrop() {
        cropDraft = nil
        tool = .select
        refreshPreview()
        canvas?.updateCanvasSize()
    }

    private func fitCropDraftToRatio() {
        guard let draft = cropDraft, let document, cropAspectRatio > 0 else { return }
        let ratio = document.quarterTurns % 2 == 0 ? cropAspectRatio : 1 / cropAspectRatio
        var size = draft.size
        if size.width / size.height > ratio { size.width = size.height * ratio } else { size.height = size.width / ratio }
        cropDraft = CGRect(x: draft.midX - size.width / 2, y: draft.midY - size.height / 2, width: size.width, height: size.height)
    }

    func snapshot() throws -> ImageProjectContents {
        guard let document, let source else { throw GlintError.message("The image is still opening.") }
        return ImageProjectContents(document: document, source: source, insertedImages: insertedImages)
    }

    func mutate(_ action: String, _ body: (inout ImageDocument) -> Void) {
        guard var next = document else { return }
        let previous = next
        body(&next)
        guard next != previous else { return }
        do { _ = try next.validated() }
        catch { errorMessage = error.localizedDescription; return }
        document = next
        if adjustmentStart == nil { registerUndo(previous, action: action) } else { adjustmentAction = action }
        refreshPreview()
    }

    // a slider drag edits live and becomes one undo step when released
    private var adjustmentStart: ImageDocument?
    private var adjustmentAction = ""
    var isAdjusting: Bool { adjustmentStart != nil }

    func beginAdjusting() { adjustmentStart = document }

    func endAdjusting() {
        guard let start = adjustmentStart else { return }
        adjustmentStart = nil
        if document != start { registerUndo(start, action: adjustmentAction) }
        canvas?.updateCanvasSize()
    }

    func updateGesture(_ next: ImageDocument) {
        document = next
        refreshPreview()
    }

    func finishGesture(from previous: ImageDocument, action: String) {
        guard document != previous else { return }
        do { if let document { _ = try document.validated() } }
        catch { document = previous; errorMessage = error.localizedDescription }
        if document != previous { registerUndo(previous, action: action) }
        refreshPreview()
    }

    func cancelGesture(restoring previous: ImageDocument) {
        document = previous
        refreshPreview()
    }

    private func registerUndo(_ previous: ImageDocument, action: String) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(previous, action: action) }
        }
        undoManager.setActionName(action)
    }

    private func restore(_ previous: ImageDocument, action: String) {
        guard let current = document else { return }
        registerUndo(current, action: action)
        document = previous
        selectedIDs.formIntersection(Set(previous.annotations.map(\.id)))
        refreshPreview()
    }

    func refreshPreview() {
        guard !isClosed, document != nil else { return }
        renderRevision += 1
        if renderTask == nil { renderLatestPreview() }
    }

    private func renderLatestPreview() {
        guard !isClosed, let saved = try? snapshot(), let shown = displayDocument else { return }
        let contents = ImageProjectContents(document: shown, source: saved.source, insertedImages: saved.insertedImages)
        let revision = renderRevision
        let maximumDimension: CGFloat? = (canvas?.magnification ?? 0) >= 0.9 ? nil : 2200
        // keep one render in flight and pick up the newest gesture state when it finishes
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try ImageRenderer.render(contents, maximumDimension: maximumDimension) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isClosed else { return }
                self.renderTask = nil
                switch result {
                case .success(let image):
                    if self.displayDocument?.canvasSize == contents.document.canvasSize {
                        self.preview = image
                        self.canvas?.updateCanvasSize()
                    }
                case .failure(let error):
                    if revision == self.renderRevision { self.errorMessage = error.localizedDescription }
                }
                if revision != self.renderRevision { self.renderLatestPreview() }
            }
        }
    }

    func newAnnotation(tool: AnnotationTool, at point: CGPoint) -> ImageAnnotation {
        var annotation = ImageAnnotation(tool: tool, rect: CGRect(origin: point, size: .zero))
        annotation.color = tool == .redact ? .ink : color
        annotation.lineWidth = lineWidth
        annotation.fontSize = fontSize
        annotation.filled = filled
        annotation.bold = bold
        annotation.italic = italic
        if [.arrow, .doubleArrow].contains(tool) { annotation.arrowStyle = arrowStyle }
        annotation.number = (document?.annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
        return annotation
    }

    func select(_ id: UUID?, extending: Bool = false) {
        if let id {
            if extending {
                if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            } else { selectedIDs = [id] }
        } else if !extending { selectedIDs = [] }
        if let annotation = selectedAnnotations.last {
            color = annotation.color
            lineWidth = annotation.lineWidth
            fontSize = annotation.fontSize
            filled = annotation.filled
            bold = annotation.bold
            italic = annotation.italic
        }
    }

    func setColor(_ color: AnnotationColor) {
        self.color = color
        changeStyle { $0.color = color }
    }

    func changeStyle(_ update: (inout ImageAnnotation) -> Void) {
        guard !selectedIDs.isEmpty else { return }
        mutate("Change Style") { document in
            for index in document.annotations.indices where selectedIDs.contains(document.annotations[index].id) {
                update(&document.annotations[index])
            }
        }
    }

    func deleteSelection() {
        mutate("Delete") { $0.annotations.removeAll { selectedIDs.contains($0.id) } }
        selectedIDs = []
    }

    func duplicateSelection() {
        var duplicates = selectedAnnotations
        for index in duplicates.indices {
            duplicates[index].id = UUID()
            duplicates[index].move(dx: 16, dy: 16)
        }
        guard !duplicates.isEmpty else { return }
        mutate("Duplicate") { $0.annotations += duplicates }
        selectedIDs = Set(duplicates.map(\.id))
    }

    func bringSelectionToFront() {
        mutate("Bring to Front") { document in
            let selected = document.annotations.filter { selectedIDs.contains($0.id) }
            document.annotations.removeAll { selectedIDs.contains($0.id) }
            document.annotations += selected
        }
    }

    func sendSelectionToBack() {
        mutate("Send to Back") { document in
            let selected = document.annotations.filter { selectedIDs.contains($0.id) }
            document.annotations.removeAll { selectedIDs.contains($0.id) }
            document.annotations.insert(contentsOf: selected, at: 0)
        }
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let document else { return }
        let inverse = document.originalToCanvas.inverted()
        let zero = CGPoint.zero.applying(inverse), delta = CGPoint(x: dx, y: dy).applying(inverse)
        mutate("Move") { document in
            for index in document.annotations.indices where selectedIDs.contains(document.annotations[index].id) {
                document.annotations[index].move(dx: delta.x - zero.x, dy: delta.y - zero.y)
            }
        }
    }

    func rotate() {
        mutate("Rotate") { $0.quarterTurns = ($0.quarterTurns + 1) % 4 }
        canvas?.fitToWindow()
    }

    func resetCrop() {
        if let document, cropDraft != nil { cropDraft = CGRect(origin: .zero, size: document.sourceSize); return }
        mutate("Reset Crop") { $0.cropRect = CGRect(origin: .zero, size: $0.sourceSize) }
    }

    func addImage(url: URL, at point: CGPoint? = nil, beside: Bool = false, ownsTemporary: Bool = false) {
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try ImageProject.readImage(url) }.value
                guard let document else { return }
                guard image.width * image.height <= 80_000_000 else { throw GlintError.message("This image is too large to insert.") }
                let id = UUID()
                insertedImages[id] = image
                let appendRight = beside || (point.map { $0.x >= document.cropRect.maxX } ?? false)
                let appendLeft = point.map { $0.x < document.cropRect.minX } ?? false
                let appendBelow = point.map { $0.y >= document.cropRect.maxY } ?? false
                let appendAbove = point.map { $0.y < document.cropRect.minY } ?? false
                let scale: Double
                if appendRight || appendLeft { scale = document.cropRect.height / Double(image.height) }
                else if appendBelow || appendAbove { scale = document.cropRect.width / Double(image.width) }
                else { scale = min(1, min(document.cropRect.width * 0.7 / Double(image.width), document.cropRect.height * 0.7 / Double(image.height))) }
                let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
                let origin: CGPoint
                if appendRight { origin = CGPoint(x: document.cropRect.maxX, y: document.cropRect.minY) }
                else if appendLeft { origin = CGPoint(x: document.cropRect.minX - size.width, y: document.cropRect.minY) }
                else if appendBelow { origin = CGPoint(x: document.cropRect.minX, y: document.cropRect.maxY) }
                else if appendAbove { origin = CGPoint(x: document.cropRect.minX, y: document.cropRect.minY - size.height) }
                else { origin = point ?? CGPoint(x: document.cropRect.midX - size.width / 2, y: document.cropRect.midY - size.height / 2) }
                var annotation = ImageAnnotation(tool: .image, rect: CGRect(origin: origin, size: size))
                annotation.imageID = id
                mutate("Insert Image") {
                    $0.annotations.append(annotation)
                    $0.cropRect = $0.cropRect.union(annotation.rect).integral
                }
                guard self.document?.annotations.contains(where: { $0.id == annotation.id }) == true else {
                    insertedImages.removeValue(forKey: id)
                    return
                }
                selectedIDs = [annotation.id]
                tool = .select
                canvas?.fitToWindow()
                if ownsTemporary { try ImageFile.removeTemporary(url) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func importImage(beside: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach { addImage(url: $0, beside: beside) } }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try ImageProject.readImage(url) }.value
                let id = UUID()
                insertedImages[id] = image
                mutate("Background Image") { $0.background.imageID = id; $0.background.enabled = true }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func alignContent(x: Double? = nil, y: Double? = nil) {
        guard let document else { return }
        let previous = document.background.contentOffset ?? .zero
        let offset = CGPoint(x: x.map { (document.canvasSize.width - document.contentSize.width - 2 * document.backgroundInset) / 2 * $0 } ?? previous.x,
                             y: y.map { (document.canvasSize.height - document.contentSize.height - 2 * document.backgroundInset) / 2 * $0 } ?? previous.y)
        mutate("Align Content") { $0.background.contentOffset = offset }
    }

    func snapHighlight(_ id: UUID) {
        guard smartHighlight, var next = document,
              let index = next.annotations.firstIndex(where: { $0.id == id }) else { return }
        let annotation = next.annotations[index]
        let boxes = ImageTextLayout.highlights(intersecting: annotation.rect, words: textBoxes)
        guard !boxes.isEmpty else { return }
        let highlights = boxes.map { rect -> ImageAnnotation in
            var copy = annotation
            copy.id = UUID()
            copy.rect = rect
            return copy
        }
        next.annotations.replaceSubrange(index...index, with: highlights)
        selectedIDs = Set(highlights.map(\.id))
        updateGesture(next)
    }

    func saveBackgroundPreset() {
        guard let background = document?.background, !backgroundPresets.contains(background) else { return }
        let image = background.imageID.flatMap { insertedImages[$0] }
        Task {
            do {
                if let id = background.imageID, let image {
                    let directory = Self.presetDirectory
                    try await Task.detached(priority: .utility) {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try ImageFile.write(image, to: directory.appendingPathComponent("\(id.uuidString).png"))
                    }.value
                }
                backgroundPresets.append(background)
                persistPresets()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    static let presetDirectory = URL.applicationSupportDirectory.appendingPathComponent("Glint/Backgrounds", isDirectory: true)

    func applyBackgroundPreset(_ preset: ImageBackground) {
        let request = UUID()
        backgroundLoadID = request
        Task {
            do {
                if let id = preset.imageID, insertedImages[id] == nil {
                    let url = Self.presetDirectory.appendingPathComponent("\(id.uuidString).png")
                    let image = try await Task.detached(priority: .userInitiated) { try ImageProject.readImage(url) }.value
                    guard request == backgroundLoadID else { return }
                    insertedImages[id] = image
                }
                guard request == backgroundLoadID else { return }
                mutate("Apply Preset") { $0.background = preset }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeBackgroundPreset(at index: Int) {
        guard backgroundPresets.indices.contains(index) else { return }
        backgroundPresets.remove(at: index)
        persistPresets()
    }

    private func persistPresets() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(backgroundPresets), forKey: "imageBackgroundPresets") }
        catch { errorMessage = error.localizedDescription }
    }

    func export(to url: URL, type: UTType, quality: Double = 0.95) async throws {
        guard !busy else { return }
        canvas?.commitEditing()
        let contents = try snapshot()
        busy = true
        status = "Exporting…"
        defer { busy = false; status = "" }
        try await Task.detached(priority: .userInitiated) {
            let image = try ImageRenderer.render(contents)
            try ImageFile.write(image, to: url, type: type, quality: quality)
        }.value
        onExport(url)
    }

    func saveProject(to url: URL) async throws {
        guard !busy else { return }
        canvas?.commitEditing()
        let contents = try snapshot()
        busy = true
        status = "Saving project…"
        defer { busy = false; status = "" }
        try await Task.detached(priority: .userInitiated) { try ImageProject.save(contents, to: url) }.value
        projectURL = url
        savedDocument = contents.document
        onExport(url)
    }

    func copyImage() {
        guard !busy, !isClosed else { return }
        canvas?.commitEditing()
        let clipboard = ClipboardWriter.general
        let request = clipboard.begin()
        busy = true
        status = "Copying…"
        Task {
            defer { busy = false; status = "" }
            do {
                let contents = try snapshot()
                let data = try await Task.detached(priority: .userInitiated) {
                    try Self.pngData(ImageRenderer.render(contents))
                }.value
                guard !Task.isCancelled, !isClosed else { return }
                try clipboard.commit(request) {
                    guard $0.setData(data, forType: .png) else { throw GlintError.message("The image couldn’t be copied.") }
                }
                Toast.show("Copied")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    nonisolated static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw GlintError.message("The image couldn’t be encoded.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GlintError.message("The image couldn’t be encoded.") }
        return data as Data
    }

    private static let annotationsPasteboardType = NSPasteboard.PasteboardType("app.glint.annotations")

    func copySelection(cut: Bool = false) {
        guard !selectedAnnotations.isEmpty else { copyImage(); return }
        guard !busy, !isClosed else { return }
        let snapshot = ImageClipboardContents(annotations: selectedAnnotations, images: insertedImages)
        let clipboard = ClipboardWriter.general
        let request = clipboard.begin()
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    var images: [UUID: Data] = [:]
                    for id in Set(snapshot.annotations.compactMap(\.imageID)) {
                        if let image = snapshot.images[id] { images[id] = try Self.pngData(image) }
                    }
                    return try JSONEncoder().encode(ImageAnnotationClipboard(annotations: snapshot.annotations, images: images))
                }.value
                guard !Task.isCancelled, !isClosed else { return }
                guard try clipboard.commit(request, writing: {
                    guard $0.setData(data, forType: Self.annotationsPasteboardType) else {
                        throw GlintError.message("The selection couldn’t be copied.")
                    }
                }) else { return }
                if cut {
                    let copiedIDs = Set(snapshot.annotations.map(\.id))
                    mutate("Cut") { $0.annotations.removeAll { copiedIDs.contains($0.id) } }
                    selectedIDs.subtract(copiedIDs)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func paste() {
        guard !busy else { return }
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: Self.annotationsPasteboardType) {
            busy = true
            Task {
                defer { busy = false }
                do {
                    let pasted = try await Task.detached(priority: .userInitiated) {
                        guard data.count <= 250_000_000 else { throw GlintError.message("This selection is too large to paste.") }
                        let content = try JSONDecoder().decode(ImageAnnotationClipboard.self, from: data)
                        guard content.annotations.count <= 10_000, content.annotations.allSatisfy(\.isValid) else {
                            throw GlintError.message("This selection contains invalid annotations.")
                        }
                        var assets: [UUID: CGImage] = [:]
                        var mapping: [UUID: UUID] = [:]
                        var totalPixels = 0
                        for id in Set(content.annotations.compactMap(\.imageID)) {
                            guard let data = content.images[id], let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                                throw GlintError.message("An image in this selection couldn’t be opened.")
                            }
                            let image = try ImageProject.readImage(source)
                            totalPixels += image.width * image.height
                            guard totalPixels <= 160_000_000 else { throw GlintError.message("This selection contains too many large images.") }
                            let replacement = UUID()
                            assets[replacement] = image
                            mapping[id] = replacement
                        }
                        let annotations = content.annotations.map { item -> ImageAnnotation in
                            var copy = item
                            copy.id = UUID()
                            copy.imageID = item.imageID.flatMap { mapping[$0] }
                            copy.move(dx: 16, dy: 16)
                            return copy
                        }
                        return ImageClipboardContents(annotations: annotations, images: assets)
                    }.value
                    insertedImages.merge(pasted.images) { existing, _ in existing }
                    mutate("Paste") { $0.annotations += pasted.annotations }
                    selectedIDs = Set(pasted.annotations.map(\.id))
                    tool = .select
                } catch { errorMessage = error.localizedDescription }
            }
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.forEach { addImage(url: $0) }
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let url = ImageFile.temporaryURL()
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
                    addImage(url: url, ownsTemporary: true)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
}
