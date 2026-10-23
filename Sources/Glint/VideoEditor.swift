import AppKit
import AVKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class VideoEditorModel {
    private(set) var project: VideoProject?
    private(set) var directory: URL?
    let player = AVPlayer()
    var currentTime = 0.0
    var isPlaying = false
    var isPreparing = true
    var isExporting = false
    var exportProgress = 0.0
    var gifFrameRate = 15
    var isSaving = false
    var errorMessage: String?
    var selectedZoom: UUID?
    var pickingZoom: UUID?
    private(set) var undoStack: [VideoEdits] = []
    private(set) var redoStack: [VideoEdits] = []
    @ObservationIgnored private var savedEdits: VideoEdits?
    @ObservationIgnored private var lastEditKey: AnyKeyPath?
    @ObservationIgnored private var lastEditDate = Date.distantPast
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var scratchDirectories: [URL] = []
    @ObservationIgnored private var backgroundDirectory: URL?
    @ObservationIgnored private var needsSaveLocation: Bool
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored let originalURL: URL
    @ObservationIgnored let onExport: (URL) -> Void
    @ObservationIgnored weak var window: NSWindow?

    var isDirty: Bool { project?.edits != savedEdits }
    var duration: Double { project?.editedDuration ?? 0 }
    var sourceTime: Double { project?.sourceTime(at: currentTime) ?? 0 }

    init(url: URL, onExport: @escaping (URL) -> Void) {
        originalURL = url; self.onExport = onExport
        needsSaveLocation = url.pathExtension.lowercased() != "glintvideo"
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    func load() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if originalURL.pathExtension.lowercased() == "glintvideo" {
                    let project = try await Task.detached(priority: .userInitiated) { try VideoProject.load(from: self.originalURL) }.value
                    self.project = project; directory = originalURL
                } else {
                    let (project, directory) = try await VideoCompositionBuilder.importMovie(originalURL)
                    self.project = project; self.directory = directory
                    scratchDirectories.append(directory)
                }
                try Task.checkCancellation()
                savedEdits = project?.edits
                gifFrameRate = min(15, project?.frameRate ?? 15)
                refreshPreview(immediately: true)
            } catch is CancellationError {
                isPreparing = false
                cleanupScratch()
            } catch {
                isPreparing = false; errorMessage = error.localizedDescription
            }
        }
    }

    func set<Value: Equatable>(_ key: WritableKeyPath<VideoEdits, Value>, _ value: Value) {
        guard var project, project.edits[keyPath: key] != value else { return }
        if let number = value as? Double, !number.isFinite { return }
        let previous = project.edits
        project.edits[keyPath: key] = value
        if key == \VideoEdits.trimStart { project.edits.trimStart = max(0, min(project.duration - 0.05, min(project.edits.trimStart, project.edits.trimEnd - 0.05))) }
        if key == \VideoEdits.trimEnd { project.edits.trimEnd = min(project.duration, max(project.edits.trimStart + 0.05, project.edits.trimEnd)) }
        guard project.editedDuration > 0 else { errorMessage = "Keep at least one frame in the video."; return }
        if key != lastEditKey || Date().timeIntervalSince(lastEditDate) > 0.6 { remember(previous) }
        lastEditKey = key; lastEditDate = Date()
        self.project = project
        if key == \VideoEdits.exportQuality { window?.isDocumentEdited = isDirty; return }
        refreshPreview()
    }

    func edit(_ body: (inout VideoEdits) -> Void) {
        guard var project else { return }
        let before = project.edits
        body(&project.edits)
        guard before != project.edits else { return }
        remember(before); lastEditKey = nil
        self.project = project
        refreshPreview()
    }

    func binding<Value: Equatable>(_ key: WritableKeyPath<VideoEdits, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.project?.edits[keyPath: key] ?? fallback }, set: { self.set(key, $0) })
    }

    private func remember(_ edits: VideoEdits) {
        undoStack.append(edits)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast(), let current = project?.edits else { return }
        redoStack.append(current); project?.edits = previous; lastEditKey = nil
        refreshPreview()
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = project?.edits else { return }
        undoStack.append(current); project?.edits = next; lastEditKey = nil
        refreshPreview()
    }

    func refreshPreview(immediately: Bool = false) {
        previewTask?.cancel()
        guard let project, let directory else { return }
        let backgrounds = backgroundDirectory
        previewTask = Task { [weak self] in
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(180)) }
                try Task.checkCancellation()
                let composition = try await VideoCompositionBuilder.make(project: project, directory: directory, backgroundDirectory: backgrounds)
                try Task.checkCancellation()
                guard let self else { return }
                let position = min(currentTime, max(0, project.editedDuration - 0.001))
                let item = AVPlayerItem(asset: composition.asset)
                item.videoComposition = composition.videoComposition
                item.audioMix = composition.audioMix
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if isPlaying { player.play() }
                isPreparing = false
                window?.isDocumentEdited = isDirty
            } catch is CancellationError {} catch {
                self?.isPreparing = false; self?.errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        guard project != nil else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play(); isPlaying = true
        }
    }

    func seek(to time: Double) {
        currentTime = max(0, min(max(0, duration - 0.001), time))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func addZoom() {
        guard let project else { return }
        let start = min(max(project.edits.trimStart, sourceTime - 0.3), max(project.edits.trimStart, project.edits.trimEnd - 0.5))
        let zoom = VideoZoom(start: start, duration: min(3, project.edits.trimEnd - start), followsCursor: !project.cursorSamples.isEmpty)
        edit { $0.zooms.append(zoom) }
        selectedZoom = zoom.id
    }

    func smartZooms() {
        guard let project else { return }
        var zooms: [VideoZoom] = []
        for click in project.clicks where click.time >= project.edits.trimStart && click.time < project.edits.trimEnd {
            let start = max(project.edits.trimStart, click.time - 0.35)
            if let last = zooms.last, start < last.start + last.duration { continue }
            zooms.append(VideoZoom(start: start, duration: min(2.7, project.edits.trimEnd - start), center: click.position))
        }
        edit { $0.zooms = zooms }
    }

    func updateZoom(_ id: UUID, _ body: (inout VideoZoom) -> Void) {
        edit { edits in
            if let index = edits.zooms.firstIndex(where: { $0.id == id }) { body(&edits.zooms[index]) }
        }
    }

    func chooseZoomCenter(_ id: UUID, point: CGPoint, viewSize: CGSize) {
        guard let project else { return }
        let outputSize = VideoGeometry.outputSize(for: project)
        let fit = min(viewSize.width / outputSize.width, viewSize.height / outputSize.height)
        let x = (point.x - (viewSize.width - outputSize.width * fit) / 2) / fit
        let y = outputSize.height - (point.y - (viewSize.height - outputSize.height * fit) / 2) / fit
        let rect = VideoGeometry.contentRect(for: project, size: outputSize)
        let current = VideoGeometry.zoom(at: sourceTime, project: project)
        let center = VideoPoint(x: current.center.x + (x - rect.midX) / (rect.width * current.scale),
                                y: current.center.y - (y - rect.midY) / (rect.height * current.scale)).clamped
        updateZoom(id) { $0.center = center; $0.followsCursor = false }
        pickingZoom = nil
    }

    func removeRange(start: Double, end: Double) {
        guard let project, start.isFinite, end.isFinite else { return }
        let range = VideoTimeRange(start: max(project.edits.trimStart, start), end: min(project.edits.trimEnd, end))
        guard range.duration > 0 else { return }
        var candidate = project
        candidate.edits.cuts.append(range)
        guard candidate.editedDuration >= 0.05 else { errorMessage = "Keep at least one frame in the video."; return }
        edit { $0.cuts.append(range) }
    }

    func chooseBackground() {
        guard !isSaving, directory != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await importBackground(from: url) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func ensureBackgroundWorkspace() async throws -> URL {
        guard let project, let directory else { throw GlintError.message("Open a video before adding a background.") }
        let workspace: URL
        if let backgroundDirectory { workspace = backgroundDirectory }
        else {
            workspace = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-backgrounds-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            backgroundDirectory = workspace
            scratchDirectories.append(workspace)
        }
        try await Task.detached(priority: .userInitiated) {
            for file in project.backgroundFiles {
                let target = workspace.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.copyItem(at: directory.appendingPathComponent(file), to: target)
                }
            }
        }.value
        return workspace
    }

    func importBackground(from url: URL) async throws {
        guard !isSaving else { throw GlintError.message("Wait for the current save to finish.") }
        isSaving = true
        defer { isSaving = false }
        let workspace = try await ensureBackgroundWorkspace()
        let filename = "background-\(UUID().uuidString).png"
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                             kCGImageSourceThumbnailMaxPixelSize: 7680,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw GlintError.message("This background image couldn’t be opened.")
            }
            try ImageFile.write(image, to: workspace.appendingPathComponent(filename))
        }.value
        project?.backgroundFiles.append(filename)
        edit { $0.backgroundFile = filename; $0.showsBackground = true }
    }

    func saveProject(asNew: Bool = false) async -> Bool {
        guard !isSaving, let project, let source = directory else { return false }
        var destination = source
        if needsSaveLocation || asNew {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(exportedAs: "app.glint.video-project", conformingTo: .package)]
            panel.nameFieldStringValue = "\(originalURL.deletingPathExtension().lastPathComponent).glintvideo"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if !project.backgroundFiles.isEmpty { _ = try await ensureBackgroundWorkspace() }
            let backgrounds = backgroundDirectory
            let thumbnail = try? await VideoCompositionBuilder.thumbnail(project: project, directory: source, time: currentTime, backgroundDirectory: backgrounds)
            var savedProject = project
            savedProject.backgroundFiles = [project.edits.backgroundFile].compactMap { $0 }
            let persisted = savedProject
            let chosen = destination
            try await Task.detached(priority: .userInitiated) {
                if chosen.standardizedFileURL == source.standardizedFileURL {
                    var copied: [URL] = []
                    do {
                        for file in persisted.backgroundFiles {
                            let target = chosen.appendingPathComponent(file)
                            if !FileManager.default.fileExists(atPath: target.path) {
                                try FileManager.default.copyItem(at: VideoCompositionBuilder.backgroundURL(file, directory: source, backgroundDirectory: backgrounds), to: target)
                                copied.append(target)
                            }
                        }
                        try persisted.save(to: chosen)
                    } catch {
                        for url in copied { try? FileManager.default.removeItem(at: url) }
                        throw error
                    }
                    if let thumbnail { try? ImageFile.write(thumbnail, to: chosen.appendingPathComponent("preview.png")) }
                } else {
                    let temporary = chosen.deletingLastPathComponent().appendingPathComponent(".Glint-\(UUID().uuidString).glintvideo", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                    for file in [project.screenFile, project.cameraFile].compactMap({ $0 }) {
                        try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: temporary.appendingPathComponent(file))
                    }
                    for file in persisted.backgroundFiles {
                        try FileManager.default.copyItem(at: VideoCompositionBuilder.backgroundURL(file, directory: source, backgroundDirectory: backgrounds), to: temporary.appendingPathComponent(file))
                    }
                    if let thumbnail { try? ImageFile.write(thumbnail, to: temporary.appendingPathComponent("preview.png")) }
                    try persisted.save(to: temporary)
                    if FileManager.default.fileExists(atPath: chosen.path) { _ = try FileManager.default.replaceItemAt(chosen, withItemAt: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: chosen) }
                }
            }.value
            directory = destination; needsSaveLocation = false; savedEdits = project.edits
            window?.isDocumentEdited = false
            refreshPreview(immediately: true)
            onExport(destination)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func export(_ format: VideoExportFormat) {
        guard !isExporting, !isSaving, let project, let directory else { return }
        let panel = NSSavePanel()
        switch format {
        case .mp4: panel.allowedContentTypes = [.mpeg4Movie]
        case .gif: panel.allowedContentTypes = [.gif]
        case .original: panel.allowedContentTypes = [.quickTimeMovie]
        }
        panel.nameFieldStringValue = "\(originalURL.deletingPathExtension().lastPathComponent).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.pause(); isPlaying = false
        isExporting = true; exportProgress = 0
        let backgrounds = backgroundDirectory
        let rate = gifFrameRate
        exportTask = Task { [weak self] in
            defer { self?.isExporting = false; self?.cleanupScratch() }
            do {
                try await VideoExporter.export(project: project, directory: directory, destination: url, format: format, backgroundDirectory: backgrounds, gifFrameRate: rate) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.exportProgress = progress }
                }
                self?.onExport(url)
            } catch is CancellationError {} catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func shutdown() {
        isClosed = true
        loadTask?.cancel(); previewTask?.cancel(); exportTask?.cancel()
        player.pause(); player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        cleanupScratch()
    }

    private func cleanupScratch() {
        if isClosed && !isExporting {
            for directory in scratchDirectories { try? FileManager.default.removeItem(at: directory) }
            scratchDirectories.removeAll()
        }
    }
}

@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate, EditorClosing {
    let model: VideoEditorModel
    private var closeAfterSave = false
    private var checkingClose = false

    init(url: URL, onExport: @escaping (URL) -> Void) {
        model = VideoEditorModel(url: url, onExport: onExport)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(url.deletingPathExtension().lastPathComponent) — Glint"
        window.minSize = NSSize(width: 900, height: 620)
        window.contentViewController = NSHostingController(rootView: VideoEditorView(model: model))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        model.window = window
        window.delegate = self
        window.center()
        model.load()
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeAfterSave || (!model.isDirty && !model.isExporting && !model.isSaving) { return true }
        Task {
            if await prepareToClose() { closeAfterSave = true; close() }
        }
        return false
    }

    func prepareToClose() async -> Bool {
        guard !checkingClose else { return false }
        checkingClose = true
        defer { checkingClose = false }
        if model.isSaving || model.isExporting {
            let alert = NSAlert()
            alert.messageText = model.isSaving ? "The project is still saving" : "A video export is still running"
            alert.informativeText = model.isSaving ? "Wait for the save to finish before closing this window." : "Wait for the export to finish, or cancel it in the progress window."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your video edits?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return await model.saveProject()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) { model.shutdown() }
}

struct VideoPlaybackView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

struct VideoEditorView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.help("Undo").disabled(model.undoStack.isEmpty).keyboardShortcut("z")
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }.help("Redo").disabled(model.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                Divider().frame(height: 18)
                Button("Save Project") { Task { _ = await model.saveProject() } }.keyboardShortcut("s")
                Menu {
                    Button("Save As…") { Task { _ = await model.saveProject(asNew: true) } }
                } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Menu("Export") {
                    Button("Video (MP4)") { model.export(.mp4) }.keyboardShortcut("e")
                    Button("Animation (GIF)") { model.export(.gif) }
                    Divider()
                    Button("Trim Only…") { model.export(.original) }.help("Keep the original appearance and encoding; only trim and remove sections")
                }.menuStyle(.borderedButton).disabled(model.project == nil || model.isExporting)
            }.padding(12).background(.bar)
            Divider()
            if let project = model.project {
                HSplitView {
                    VStack(spacing: 0) {
                        ZStack {
                            VideoPlaybackView(player: model.player).allowsHitTesting(false)
                            if let zoom = model.pickingZoom {
                                GeometryReader { geometry in
                                    Color.clear.contentShape(Rectangle()).onTapGesture { point in
                                        model.chooseZoomCenter(zoom, point: point, viewSize: geometry.size)
                                    }
                                    .overlay(alignment: .top) {
                                        Text("Choose the zoom center").padding(8).background(.regularMaterial, in: Capsule()).padding()
                                    }
                                }
                            }
                            if model.isPreparing { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                        }.background(.black).frame(minWidth: 480, minHeight: 300)
                        VideoTimelineView(model: model, project: project)
                    }
                    VideoInspectorView(model: model, project: project).frame(minWidth: 290, idealWidth: 310, maxWidth: 360)
                }
            } else {
                Spacer()
                if model.isPreparing { ProgressView("Opening video…") }
                else { ContentUnavailableView("Video unavailable", systemImage: "video.slash", description: Text(model.errorMessage ?? "This recording couldn’t be opened.")) }
                Spacer()
            }
        }
        .sheet(isPresented: $model.isExporting) {
            VStack(spacing: 18) {
                Text("Exporting video").font(.headline)
                ProgressView(value: model.exportProgress).frame(width: 280)
                Text(model.exportProgress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel", action: model.cancelExport).keyboardShortcut(.cancelAction)
            }.padding(30).interactiveDismissDisabled()
        }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct VideoTimelineView: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject
    @State private var cutStart = 0.0
    @State private var cutEnd = 1.0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: model.togglePlayback) { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }.keyboardShortcut(.space, modifiers: [])
                Text(time(model.currentTime)).monospacedDigit().frame(width: 78)
                Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }), in: 0...max(0.001, model.duration))
                Text(time(model.duration)).monospacedDigit().frame(width: 78).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Trim").font(.subheadline.weight(.medium))
                numberField("Start", value: model.binding(\.trimStart, fallback: 0))
                Button { model.set(\.trimStart, model.sourceTime) } label: { Image(systemName: "arrow.left.to.line") }.help("Set start at playhead")
                numberField("End", value: model.binding(\.trimEnd, fallback: project.duration))
                Button { model.set(\.trimEnd, model.sourceTime) } label: { Image(systemName: "arrow.right.to.line") }.help("Set end at playhead")
                Spacer()
                Button("Reset") { model.edit { $0.trimStart = 0; $0.trimEnd = project.duration; $0.cuts = [] } }
            }
            HStack(spacing: 8) {
                Text("Cut").font(.subheadline.weight(.medium)).frame(width: 27, alignment: .leading)
                numberField("From", value: $cutStart)
                numberField("To", value: $cutEnd)
                Button("Remove") { model.removeRange(start: cutStart, end: cutEnd) }
                Button { cutStart = model.sourceTime; cutEnd = min(project.edits.trimEnd, cutStart + 1) } label: { Image(systemName: "scope") }.help("Start at playhead")
                Spacer()
                Button("Add Zoom", action: model.addZoom)
            }
            if !project.edits.cuts.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(project.edits.cuts) { cut in
                            HStack(spacing: 5) {
                                Text("\(time(cut.start))–\(time(cut.end))").font(.caption).monospacedDigit()
                                Button { model.edit { $0.cuts.removeAll { $0.id == cut.id } } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Restore this section")
                            }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }.padding(14).background(.bar)
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).font(.caption)
            TextField(label, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).frame(width: 62)
        }
    }

    private func time(_ seconds: Double) -> String {
        let seconds = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

private struct VideoInspectorView: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject
    @State private var customWidth = 1920
    @State private var customHeight = 1080

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Canvas") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Shape", selection: model.binding(\.aspect, fallback: .original)) { ForEach(VideoAspect.allCases) { Text($0.rawValue).tag($0) } }
                        Picker("Resolution", selection: resolution) {
                            ForEach([1280, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
                            Text("Custom").tag(0)
                        }
                        if project.edits.customWidth != nil {
                            HStack {
                                TextField("Width", value: $customWidth, format: .number).textFieldStyle(.roundedBorder)
                                Text("×")
                                TextField("Height", value: $customHeight, format: .number).textFieldStyle(.roundedBorder)
                                Button("Apply", action: applyCustomSize)
                            }
                        }
                        Toggle("Background", isOn: model.binding(\.showsBackground, fallback: true))
                        if project.edits.showsBackground {
                            HStack {
                                Button("Image…", action: model.chooseBackground)
                                if project.edits.backgroundFile != nil { Button("Remove") { model.edit { $0.backgroundFile = nil } } }
                            }
                            HStack { colorPicker("Top", key: \.backgroundTop); colorPicker("Bottom", key: \.backgroundBottom) }
                            slider("Padding", key: \.padding, range: 0...200)
                            slider("Corners", key: \.cornerRadius, range: 0...80)
                            slider("Shadow", key: \.shadow, range: 0...60)
                        }
                    }.padding(5)
                }
                GroupBox("Zooms") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Add", action: model.addZoom)
                            Button("Auto", action: model.smartZooms).disabled(project.clicks.isEmpty).help("Add zooms around clicks")
                            Spacer()
                        }
                        if project.edits.zooms.isEmpty { Text("Draw attention to a detail.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(project.edits.zooms) { zoom in
                            VideoZoomRow(model: model, zoom: zoom, duration: project.duration, hasCursor: !project.cursorSamples.isEmpty)
                        }
                        slider("Motion blur", key: \.motionBlur, range: 0...1)
                    }.padding(5)
                }
                if !project.cursorSamples.isEmpty {
                    GroupBox("Cursor") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Show cursor", isOn: model.binding(\.showsCursor, fallback: true))
                            Picker("Style", selection: model.binding(\.cursorStyle, fallback: .arrow)) { ForEach(VideoCursorStyle.allCases) { Text($0.rawValue).tag($0) } }
                            Picker("Movement", selection: model.binding(\.cursorMovement, fallback: .smooth)) { ForEach(VideoCursorMovement.allCases) { Text($0.rawValue).tag($0) } }
                            slider("Size", key: \.cursorScale, range: 0.5...4)
                            if project.edits.cursorMovement == .smooth { slider("Smoothing", key: \.cursorSmoothing, range: 0...1) }
                            Toggle("Hide when stationary", isOn: model.binding(\.cursorHideWhenStationary, fallback: false))
                            Toggle("Hide while typing", isOn: model.binding(\.cursorHideWhileTyping, fallback: false))
                                .disabled(project.keystrokes.isEmpty).help("Requires keystrokes to have been recorded")
                            Toggle("Press effect", isOn: model.binding(\.cursorPressEffect, fallback: true))
                            Toggle("Click ripple", isOn: model.binding(\.showsClicks, fallback: true))
                            if project.edits.showsClicks {
                                colorPicker("Click color", key: \.clickColor)
                                slider("Ripple size", key: \.clickSize, range: 0.25...3)
                                Toggle("Filled", isOn: model.binding(\.clickFilled, fallback: false))
                                Toggle("Animate", isOn: model.binding(\.clickAnimated, fallback: true))
                            }
                        }.padding(5)
                    }
                }
                if project.cameraFile != nil {
                    GroupBox("Camera") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Show camera", isOn: model.binding(\.showsCamera, fallback: true))
                            Toggle("Full screen", isOn: model.binding(\.cameraFullScreen, fallback: false))
                            Toggle("Smaller during zoom", isOn: model.binding(\.cameraSmallerDuringZoom, fallback: false)).disabled(project.edits.cameraFullScreen)
                            Picker("Position", selection: model.binding(\.cameraPosition, fallback: .bottomRight)) { ForEach(VideoCameraPosition.allCases) { Text($0.rawValue).tag($0) } }
                            Picker("Shape", selection: model.binding(\.cameraShape, fallback: .circle)) { ForEach(VideoCameraShape.allCases) { Text($0.rawValue).tag($0) } }
                            slider("Size", key: \.cameraSize, range: 0.08...0.5)
                            Toggle("Mirror", isOn: model.binding(\.cameraMirrored, fallback: true))
                        }.padding(5)
                    }
                }
                if !project.keystrokes.isEmpty {
                    GroupBox("Keystrokes") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Show keystrokes", isOn: model.binding(\.showsKeystrokes, fallback: true))
                            Toggle("Shortcuts only", isOn: model.binding(\.keystrokesOnlyShortcuts, fallback: true))
                            Picker("Position", selection: model.binding(\.keystrokePosition, fallback: .bottom)) { ForEach(VideoKeyPosition.allCases) { Text($0.rawValue).tag($0) } }
                            Picker("Style", selection: model.binding(\.keystrokeStyle, fallback: .dark)) { ForEach(VideoKeyStyle.allCases) { Text($0.rawValue).tag($0) } }
                            slider("Size", key: \.keystrokeScale, range: 0.5...2)
                        }.padding(5)
                    }
                }
                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Include audio", isOn: model.binding(\.audioEnabled, fallback: true))
                        slider("System", key: \.systemVolume, range: 0...2)
                        if project.microphoneAudioTrackID != nil { slider("Microphone", key: \.microphoneVolume, range: 0...2) }
                    }.padding(5)
                }
                GroupBox("Export") {
                    VStack(alignment: .leading, spacing: 10) {
                        slider("MP4 quality", key: \.exportQuality, range: 0...1)
                        Text("About \(ByteCountFormatter.string(fromByteCount: VideoExporter.estimatedSize(project: project), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        Picker("GIF frame rate", selection: $model.gifFrameRate) {
                            ForEach(Array(Set([5, 10, 15, 20, 25, 30, 50, min(50, project.frameRate)])).filter { $0 <= project.frameRate }.sorted(), id: \.self) { Text("\($0) fps").tag($0) }
                        }
                    }.padding(5)
                }
            }.padding(14)
        }.background(Color(nsColor: .controlBackgroundColor))
        .onAppear { customWidth = project.edits.customWidth ?? Int(VideoGeometry.outputSize(for: project).width); customHeight = project.edits.customHeight ?? Int(VideoGeometry.outputSize(for: project).height) }
    }

    private func slider(_ title: String, key: WritableKeyPath<VideoEdits, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 68, alignment: .leading)
            Slider(value: model.binding(key, fallback: range.lowerBound), in: range)
        }
    }

    private func colorPicker(_ title: String, key: WritableKeyPath<VideoEdits, VideoColor>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(nsColor: project.edits[keyPath: key].nsColor) }, set: { model.set(key, VideoColor(NSColor($0))) }), supportsOpacity: false).font(.caption)
    }

    private var resolution: Binding<Int> {
        Binding(get: { project.edits.customWidth == nil ? project.edits.maximumDimension : 0 }, set: { value in
            if value == 0 {
                let size = VideoGeometry.outputSize(for: project)
                customWidth = Int(size.width); customHeight = Int(size.height)
                model.edit { $0.customWidth = customWidth; $0.customHeight = customHeight }
            } else {
                model.edit { $0.maximumDimension = value; $0.customWidth = nil; $0.customHeight = nil }
            }
        })
    }

    private func applyCustomSize() {
        guard (64...7680).contains(customWidth), (64...7680).contains(customHeight) else {
            model.errorMessage = "Choose a width and height between 64 and 7680 pixels."
            return
        }
        customWidth = customWidth / 2 * 2; customHeight = customHeight / 2 * 2
        model.edit { $0.customWidth = customWidth; $0.customHeight = customHeight }
    }
}

private struct VideoZoomRow: View {
    @Bindable var model: VideoEditorModel
    let zoom: VideoZoom
    let duration: Double
    let hasCursor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.seek(to: model.project?.outputTime(at: zoom.start + min(0.5, zoom.duration / 2)) ?? 0) } label: { Text(String(format: "%.1fs", zoom.start)).monospacedDigit() }
                Spacer()
                Button { model.edit { $0.zooms.removeAll { $0.id == zoom.id } } } label: { Image(systemName: "trash") }.help("Remove zoom")
            }
            HStack {
                Text("Start").font(.caption)
                TextField("Start", value: binding(\.start, range: 0...max(0, duration - 0.1)), format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder)
                Text("Length").font(.caption)
                TextField("Length", value: binding(\.duration, range: 0.1...max(0.1, duration - zoom.start)), format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder)
            }
            HStack { Text("Zoom").font(.caption); Slider(value: binding(\.scale, range: 1...4), in: 1...4); Text(String(format: "%.1f×", zoom.scale)).font(.caption).monospacedDigit() }
            Toggle("Follow cursor", isOn: Binding(get: { zoom.followsCursor }, set: { value in model.updateZoom(zoom.id) { $0.followsCursor = value } })).disabled(!hasCursor).font(.caption)
            if !zoom.followsCursor {
                Button(model.pickingZoom == zoom.id ? "Cancel Selection" : "Choose Center") { model.pickingZoom = model.pickingZoom == zoom.id ? nil : zoom.id }
            }
        }.padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding(_ key: WritableKeyPath<VideoZoom, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { zoom[keyPath: key] }, set: { value in
            guard value.isFinite else { return }
            model.updateZoom(zoom.id) { $0[keyPath: key] = min(range.upperBound, max(range.lowerBound, value)) }
        })
    }
}
