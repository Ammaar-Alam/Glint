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
    var panel: VideoInspectorPanel = .background
    private(set) var frames: [VideoFrame] = []
    private(set) var undoStack: [VideoEdits] = []
    private(set) var redoStack: [VideoEdits] = []
    @ObservationIgnored private var savedEdits: VideoEdits?
    @ObservationIgnored private var lastEditKey: AnyKeyPath?
    @ObservationIgnored private var lastEditDate = Date.distantPast
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var frameDensity = 0
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
        apply(project.edits)
    }

    func edit(_ body: (inout VideoEdits) -> Void) {
        guard var project else { return }
        let before = project.edits
        body(&project.edits)
        guard before != project.edits else { return }
        remember(before); lastEditKey = nil
        apply(project.edits)
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
        redoStack.append(current); lastEditKey = nil
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = project?.edits else { return }
        undoStack.append(current); lastEditKey = nil
        apply(next)
    }

    private func apply(_ edits: VideoEdits) {
        guard var project else { return }
        let source = project.sourceTime(at: currentTime)
        let previous = project.edits
        project.edits = edits
        self.project = project
        currentTime = min(project.outputTime(at: source), max(0, project.editedDuration - 0.001))
        if !edits.zooms.contains(where: { $0.id == selectedZoom }) { selectedZoom = nil }
        if !edits.zooms.contains(where: { $0.id == pickingZoom }) { pickingZoom = nil }
        window?.isDocumentEdited = isDirty
        var previewEdits = edits
        previewEdits.exportQuality = previous.exportQuality
        if previewEdits != previous { refreshPreview() }
    }

    func refreshPreview(immediately: Bool = false) {
        previewTask?.cancel()
        guard let project, let directory else { return }
        let backgrounds = backgroundDirectory
        previewTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if let self, let item = self.player.currentItem, let current = item.videoComposition,
                   let instruction = current.instructions.first as? VideoInstruction {
                    let previous = instruction.project.edits, edits = project.edits
                    if previous.trimStart == edits.trimStart, previous.trimEnd == edits.trimEnd, previous.cuts == edits.cuts,
                       previous.audioEnabled == edits.audioEnabled, previous.systemVolume == edits.systemVolume,
                       previous.microphoneVolume == edits.microphoneVolume, previous.backgroundFile == edits.backgroundFile,
                       previous.maximumDimension == edits.maximumDimension {
                        _ = try project.validated()
                        let composition = current.mutableCopy() as! AVMutableVideoComposition
                        composition.renderSize = VideoGeometry.outputSize(for: project)
                        composition.instructions = [VideoInstruction(project: project, screenTrackID: instruction.screenTrackID,
                            cameraTrackID: instruction.cameraTrackID, screenTransform: instruction.screenTransform,
                            cameraTransform: instruction.cameraTransform, backgroundImage: instruction.backgroundImage, activity: instruction.activity)]
                        item.videoComposition = composition
                        self.previewTask = nil
                        self.isPreparing = false
                        if self.isPlaying { self.player.play() }
                        return
                    }
                }
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
                try Task.checkCancellation()
                if isPlaying { player.play() }
                isPreparing = false
                window?.isDocumentEdited = isDirty
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
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

    func addZoom(at time: Double? = nil) {
        guard let project else { return }
        let start = min(max(project.edits.trimStart, time ?? sourceTime - 0.3), max(project.edits.trimStart, project.edits.trimEnd - 0.5))
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

    func removeZoom(_ id: UUID) {
        edit { $0.zooms.removeAll { $0.id == id } }
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

    func updateCut(_ id: UUID, start: Double, end: Double) {
        guard let project, start.isFinite, end.isFinite, let index = project.edits.cuts.firstIndex(where: { $0.id == id }) else { return }
        var candidate = project
        candidate.edits.cuts[index].start = max(0, start)
        candidate.edits.cuts[index].end = min(project.duration, max(start, end))
        guard candidate.editedDuration >= 0.05 else { errorMessage = "Keep at least one frame in the video."; return }
        edit { $0 = candidate.edits }
    }

    func loadFrames(tiles: Int) {
        let density = VideoFrameStrip.density(for: tiles)
        guard density > frameDensity, let project, let directory else { return }
        frameDensity = density
        let cached = Set(frames.map { Int(($0.time * 1000).rounded()) })
        let times = VideoFrameStrip.times(duration: project.duration, density: density).filter { !cached.contains(Int(($0 * 1000).rounded())) }
        let url = directory.appendingPathComponent(project.screenFile)
        let size = CGSize(width: 104 * Double(project.width) / Double(project.height), height: 104)
        let tolerance = CMTime(seconds: project.duration / Double(density) / 2, preferredTimescale: 600)
        frameTask?.cancel()
        frameTask = Task.detached(priority: .utility) { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            generator.requestedTimeToleranceBefore = tolerance; generator.requestedTimeToleranceAfter = tolerance
            for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
                if Task.isCancelled { generator.cancelAllCGImageGeneration(); return }
                guard let image = try? result.image else { continue }
                await self?.insertFrame(VideoFrame(time: result.requestedTime.seconds, image: image))
            }
        }
    }

    private func insertFrame(_ frame: VideoFrame) {
        let index = VideoGeometry.lastIndex(in: frames, at: frame.time, timestamp: \.time)
        if let index, abs(frames[index].time - frame.time) < 0.0005 { return }
        frames.insert(frame, at: (index ?? -1) + 1)
    }

    func frame(near time: Double) -> CGImage? {
        guard let index = VideoGeometry.lastIndex(in: frames, at: time, timestamp: \.time) else { return frames.first?.image }
        if index + 1 < frames.count, frames[index + 1].time - time < time - frames[index].time { return frames[index + 1].image }
        return frames[index].image
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
        loadTask?.cancel(); previewTask?.cancel(); exportTask?.cancel(); frameTask?.cancel()
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(url.deletingPathExtension().lastPathComponent) — Glint"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 960, height: 640)
        window.contentViewController = NSHostingController(rootView: VideoEditorView(model: model))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        model.window = window
        window.delegate = self
        window.center()
        centerWindowButtons()
        model.load()
    }

    // appkit pins the window buttons to the default titlebar, so line them up with the taller editor bar
    private func centerWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let titlebar = button.superview else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: titlebar.bounds.height - VideoEditorView.barHeight / 2 - button.frame.height / 2))
        }
    }

    func windowDidResize(_ notification: Notification) { centerWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { centerWindowButtons() }

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
            alert.informativeText = model.isSaving ? "Wait for the save to finish before closing this window." : "Wait for the export to finish, or cancel it."
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
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
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
            VideoEditorBar(model: model)
            Divider()
            if let project = model.project {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        VideoStage(model: model, project: project)
                        Divider()
                        VideoTimelineView(model: model, project: project).disabled(model.isExporting)
                    }
                    Divider()
                    VideoInspectorView(model: model, project: project).disabled(model.isExporting)
                }
            } else {
                ZStack {
                    Color.backdrop
                    if model.isPreparing { ProgressView().controlSize(.small) }
                    else { ContentUnavailableView("Video unavailable", systemImage: "video.slash", description: Text(model.errorMessage ?? "This recording couldn’t be opened.")) }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(.glint)
        .alert("Couldn’t complete the action", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    static let barHeight: CGFloat = 46

    static func clock(_ seconds: Double) -> String {
        let seconds = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

private struct VideoEditorBar: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo").disabled(model.undoStack.isEmpty).keyboardShortcut("z")
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo").disabled(model.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .buttonStyle(ToolButtonStyle())
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small) }
            Menu {
                Button("Save As…", action: saveAs)
            } label: { Text("Save") } primaryAction: { save() }
                .menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
                .disabled(model.project == nil || model.isSaving)
            if model.isExporting {
                HStack(spacing: 8) {
                    ProgressView(value: model.exportProgress).progressViewStyle(.linear).frame(width: 84)
                    Text(model.exportProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit()).frame(width: 34, alignment: .trailing)
                    Button(action: model.cancelExport) { Image(systemName: "xmark") }
                        .buttonStyle(ToolButtonStyle(size: CGSize(width: 22, height: 22)))
                        .help("Cancel export").keyboardShortcut(.cancelAction)
                }
                .padding(.leading, 12).padding(.trailing, 3)
                .frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            } else {
                Menu {
                    Button("MP4") { model.export(.mp4) }
                    Button("GIF") { model.export(.gif) }
                    Divider()
                    Button("Trim Only") { model.export(.original) }
                } label: { Text("Export") }
                    .menuStyle(.button).buttonStyle(PrimaryButtonStyle()).fixedSize()
                    .disabled(model.project == nil || model.isSaving)
            }
        }
        .padding(.leading, 82).padding(.trailing, 14)
        .frame(height: VideoEditorView.barHeight)
        .frame(maxWidth: .infinity)
        .overlay {
            Text(model.originalURL.deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 360)
                .allowsHitTesting(false)
        }
        .background(.bar)
        // menus don't take key equivalents, so these carry the shortcuts
        .background {
            Group {
                Button("Save", action: save).keyboardShortcut("s")
                Button("Save As", action: saveAs).keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export") { model.export(.mp4) }.keyboardShortcut("e").disabled(model.isExporting)
            }
            .disabled(model.project == nil || model.isSaving)
            .hidden()
        }
    }

    private func save() { Task { _ = await model.saveProject() } }
    private func saveAs() { Task { _ = await model.saveProject(asNew: true) } }
}

private struct VideoStage: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        let output = VideoGeometry.outputSize(for: project)
        ZStack {
            Color.backdrop
            VideoPlaybackView(player: model.player)
                .allowsHitTesting(false)
                .aspectRatio(output, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black).shadow(color: .black.opacity(0.22), radius: 18, y: 6))
                .overlay {
                    if let zoom = model.pickingZoom {
                        GeometryReader { geometry in
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { point in model.chooseZoomCenter(zoom, point: point, viewSize: geometry.size) }
                                .pointerStyle(.rectSelection)
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 76)
            VStack {
                if model.pickingZoom != nil {
                    Island {
                        Text("Choose zoom center").font(.system(size: 12, weight: .medium)).padding(.leading, 10)
                        Button { model.pickingZoom = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(ToolButtonStyle(size: CGSize(width: 24, height: 24))).help("Cancel").keyboardShortcut(.cancelAction)
                    }
                    .padding(.top, 14)
                }
                Spacer()
                VideoTransport(model: model).padding(.bottom, 20)
            }
            if model.isPreparing { ProgressView().controlSize(.small).padding(10).background(.regularMaterial, in: Circle()) }
        }
        .frame(minHeight: 320)
        .clipped()
    }
}

private struct VideoTransport: View {
    let model: VideoEditorModel

    var body: some View {
        Island {
            Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start")
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 30, height: 30)))
            Button(action: model.togglePlayback) { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16)) }
                .help(model.isPlaying ? "Pause" : "Play")
                .buttonStyle(ToolButtonStyle(size: CGSize(width: 34, height: 30)))
                .keyboardShortcut(.space, modifiers: [])
            HStack(spacing: 5) {
                Text(VideoEditorView.clock(model.currentTime)).foregroundStyle(.primary)
                Text("/").foregroundStyle(.tertiary)
                Text(VideoEditorView.clock(model.duration)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .padding(.horizontal, 10)
        }
    }
}
