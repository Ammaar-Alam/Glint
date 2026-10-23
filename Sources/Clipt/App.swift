import AppKit
import Carbon
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct CliptMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let library = CaptureLibrary()
    let shortcuts = ShortcutManager()
    let capture = CaptureService()
    let recorder = RecordingController()
    private lazy var shelf = QuickAccessPanel(library: library)
    private var statusItem: NSStatusItem!
    private var captureCommandMenu: NSMenu?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var recordingSetup: NSWindow?
    private var recordingPanel: NSPanel?
    private var editors: [NSWindowController] = []
    private var pins: [PinnedImagePanel] = []
    private var captureTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var closeObserver: NSObjectProtocol?
    private var pinsVisible = true
    private var terminationTask: Task<Void, Never>?
    private var pendingWrites = 0
    private var clipboardTask: Task<Void, Never>?
    private var clipboardGeneration = 0
    private var recordingHiddenWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let launchInBackground = launchEvent?.eventID == kAEOpenApplication &&
            (launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem)
        UserDefaults.standard.register(defaults: ["windowShadow": true, "afterCapture": "popup", "shelfPosition": "bottomLeft", "filenameTemplate": "Clipt {date} at {time}"])
        makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Clipt")
        statusItem.button?.toolTip = "Clipt"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
        shortcuts.onAction = { [weak self] in self?.perform($0) }
        shortcuts.start()
        capture.onRecord = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.captureTask?.value
                self?.showRecordingSetup()
            }
        }
        shelf.onEdit = { [weak self] in self?.edit($0) }
        shelf.onCopy = { [weak self] in self?.copy($0) }
        shelf.onSave = { [weak self] in self?.save($0) }
        shelf.onPin = { [weak self] in self?.pin($0) }
        shelf.onHistory = { [weak self] in self?.showHistory() }
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.recordingPanel?.orderOut(nil)
            self.restoreRecordingWindows()
            if let url = self.recorder.lastRecordingURL { self.importRecording(url, openEditor: true) }
            showError(error)
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                self?.editors.removeAll { $0.window === window }
            }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        Task {
            await library.load()
            await library.applyRetention(days: UserDefaults.standard.integer(forKey: "retentionDays"))
            do {
                let recovered = try await RecordingController.recoverInterruptedRecordings()
                for url in recovered { importRecording(url, openEditor: false) }
            } catch { library.error = error.localizedDescription }
            if !launchInBackground { showHistory() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHistory()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard terminationTask == nil else { sender.reply(toOpenOrPrint: .cancel); return }
        for filename in filenames { importFile(URL(fileURLWithPath: filename), openEditor: true) }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard terminationTask == nil else { return }
        for url in urls {
            if url.isFileURL { importFile(url, openEditor: true); continue }
            guard url.scheme == "clipt" else { continue }
            guard UserDefaults.standard.bool(forKey: "automationEnabled") else {
                showError(CliptError.message("Enable Allow capture URLs in Clipt Settings to use automation."))
                continue
            }
            switch url.host {
            case "capture":
                let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mode" })?.value ?? "area"
                if let mode = CaptureMode(rawValue: value) { takeCapture(mode) }
                else { showError(CliptError.message("This capture mode isn’t supported.")) }
            case "record": showRecordingSetup()
            case "stop": stopRecording()
            case "history": showHistory()
            default: showError(CliptError.message("This Clipt command isn’t supported."))
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            let ready = await prepareToTerminate()
            terminationTask = nil
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }

    private func prepareToTerminate() async -> Bool {
        if captureTask != nil || pendingWrites > 0 || recorder.state == .stopping {
            showError(CliptError.message("Finish or cancel the current capture or save before quitting."))
            return false
        }
        if recorder.state != .idle {
            let alert = NSAlert()
            alert.messageText = recorder.state == .preparing ? "Cancel recording and quit?" : "Finish recording and quit?"
            alert.informativeText = "Your recording will be kept in Clipt."
            alert.addButton(withTitle: recorder.state == .preparing ? "Cancel and Quit" : "Finish and Quit")
            alert.addButton(withTitle: "Keep Open")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if recorder.state == .preparing {
                recordingTask?.cancel()
                await recordingTask?.value
            } else {
                do { _ = try await finishRecording() }
                catch { showError(error); return false }
            }
        }
        for editor in editors {
            if let editor = editor as? EditorClosing, !(await editor.prepareToClose()) { return false }
        }
        if pendingWrites > 0 || captureTask != nil || capture.isCapturing || recorder.state != .idle || recordingTask != nil {
            showError(CliptError.message("Clipt is still finishing your work. Try quitting again when it finishes."))
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
        statusTimer?.invalidate()
        captureTask?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === captureCommandMenu {
            menu.removeAllItems()
            addCaptureCommands(to: menu)
        } else { rebuildMenu(menu) }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        addCaptureCommands(to: menu)
        menu.addItem(.separator())
        menu.addItem(HandlerMenuItem("Open File…", key: "o") { [weak self] in self?.openFile() })
        menu.addItem(HandlerMenuItem("Open Clipboard") { [weak self] in self?.openClipboard() })
        menu.addItem(HandlerMenuItem("History…") { [weak self] in self?.showHistory() })
        menu.addItem(HandlerMenuItem("Reopen Last Popup") { [weak self] in self?.shelf.reopenLast() })
        if !pins.isEmpty {
            menu.addItem(HandlerMenuItem(pinsVisible ? "Hide Pins" : "Show Pins") { [weak self] in self?.togglePins() })
            menu.addItem(HandlerMenuItem("Unlock Pins") { [weak self] in self?.pins.forEach { $0.ignoresMouseEvents = false } })
            menu.addItem(HandlerMenuItem("Close Pins") { [weak self] in self?.pins.forEach { $0.close() } })
        }
        menu.addItem(.separator())
        menu.addItem(HandlerMenuItem("Settings…", key: ",") { [weak self] in self?.showSettings() })
        menu.addItem(HandlerMenuItem("About Clipt") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) })
        menu.addItem(HandlerMenuItem("Quit Clipt", key: "q") { NSApp.terminate(nil) })
    }

    private func addCaptureCommands(to menu: NSMenu) {
        for mode in CaptureMode.allCases {
            let item = HandlerMenuItem(mode.title) { [weak self] in self?.takeCapture(mode) }
            item.isEnabled = captureTask == nil && !capture.isCapturing && recorder.state == .idle
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if recorder.state == .recording || recorder.state == .paused {
            menu.addItem(HandlerMenuItem("Stop Recording") { [weak self] in self?.stopRecording() })
            menu.addItem(HandlerMenuItem(recorder.state == .paused ? "Resume Recording" : "Pause Recording") { [weak self] in self?.togglePause() })
        } else {
            let record = HandlerMenuItem("Record Screen…") { [weak self] in self?.showRecordingSetup() }
            record.isEnabled = recorder.state == .idle
            menu.addItem(record)
        }
    }

    private func makeMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Clipt")
        appMenu.addItem(HandlerMenuItem("Settings…", key: ",") { [weak self] in self?.showSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(HandlerMenuItem("Quit Clipt", key: "q") { NSApp.terminate(nil) })
        let appItem = NSMenuItem(title: "Clipt", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(HandlerMenuItem("Open…", key: "o") { [weak self] in self?.openFile() })
        let clipboard = HandlerMenuItem("Open Clipboard", key: "v") { [weak self] in self?.openClipboard() }
        clipboard.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(clipboard)
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let captureMenu = NSMenu(title: "Capture")
        captureMenu.delegate = self
        captureCommandMenu = captureMenu
        addCaptureCommands(to: captureMenu)
        let captureItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        captureItem.submenu = captureMenu
        main.addItem(captureItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                                       ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                       ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func perform(_ action: ShortcutAction) {
        guard terminationTask == nil else { return }
        if let mode = CaptureMode(rawValue: action.rawValue) { takeCapture(mode); return }
        switch action {
        case .record:
            if recorder.state == .recording || recorder.state == .paused { stopRecording() }
            else { showRecordingSetup() }
        case .history: showHistory()
        case .reopen: shelf.reopenLast()
        case .hidePins: togglePins()
        default: break
        }
    }

    func takeCapture(_ mode: CaptureMode) {
        guard terminationTask == nil, captureTask == nil, !capture.isCapturing, recorder.state == .idle else { NSSound.beep(); return }
        captureTask = Task {
            defer { captureTask = nil }
            do {
                guard let result = try await captureWithHiddenWindows(mode) else { return }
                if let text = result.recognizedText {
                    showRecognizedText(text)
                    await cleanupTemporaryCapture(result.url)
                } else { handleCapture(try await ingestTemporaryCapture(result.url)) }
                if UserDefaults.standard.bool(forKey: "captureSound") { NSSound(named: "Pop")?.play() }
            } catch is CancellationError {} catch { showError(error) }
        }
    }

    private func configureCapture() {
        capture.includeCursor = UserDefaults.standard.bool(forKey: "includeCursor")
        capture.showWindowShadow = UserDefaults.standard.bool(forKey: "windowShadow")
        capture.freezeScreen = UserDefaults.standard.bool(forKey: "freezeScreen")
        capture.hideDesktop = UserDefaults.standard.bool(forKey: "hideDesktop")
    }

    private func hideCaptureWindows() -> [NSWindow] {
        shelf.suppressForCapture()
        let windows = NSApp.orderedWindows.filter(\.isVisible)
        windows.forEach { $0.orderOut(nil) }
        return windows
    }

    private func restoreCaptureWindows(_ windows: [NSWindow]) {
        for window in windows.reversed() { window.orderFront(nil) }
        shelf.restoreAfterCapture()
    }

    private func captureWithHiddenWindows(_ mode: CaptureMode) async throws -> CaptureResult? {
        let hidden = hideCaptureWindows()
        defer { restoreCaptureWindows(hidden) }
        configureCapture()
        return try await capture.capture(mode, delay: TimeInterval(UserDefaults.standard.integer(forKey: "captureDelay")))
    }

    private func handleCapture(_ item: CaptureItem) {
        if UserDefaults.standard.bool(forKey: "autoCopy") { copy(item) }
        switch UserDefaults.standard.string(forKey: "afterCapture") {
        case "editor": edit(item)
        case "save": save(item)
        default: shelf.present(item)
        }
    }

    func importFile(_ url: URL, openEditor: Bool) {
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                let item = try await library.ingest(url, title: url.deletingPathExtension().lastPathComponent)
                if openEditor { edit(item) } else { shelf.present(item) }
            } catch { showError(error) }
        }
    }

    func openFile() {
        guard terminationTask == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, UTType(exportedAs: "app.clipt.image-project", conformingTo: .package), UTType(exportedAs: "app.clipt.video-project", conformingTo: .package)]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.importFile(url, openEditor: true) }
        }
    }

    func openClipboard() {
        guard terminationTask == nil else { return }
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            importFile(url, openEditor: true)
        } else if let image = NSImage(pasteboard: .general), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            pendingWrites += 1
            Task {
                defer { pendingWrites -= 1 }
                do {
                    let url = ImageFile.temporaryURL()
                    try await Task.detached { try ImageFile.write(cgImage, to: url) }.value
                    let item = try await ingestTemporaryCapture(url)
                    edit(item)
                } catch { showError(error) }
            }
        } else { showError(CliptError.message("Copy an image or video file first.")) }
    }

    func edit(_ item: CaptureItem) {
        guard terminationTask == nil else { return }
        let url = item.url(in: library.root)
        guard FileManager.default.fileExists(atPath: url.path) else { showError(CliptError.message("This capture is no longer available.")); return }
        let exported: (URL) -> Void = { [weak self] url in self?.importFile(url, openEditor: false) }
        let editor: NSWindowController
        if item.kind.isVideo { editor = VideoEditorWindowController(url: url, onExport: exported) }
        else {
            let imageEditor = ImageEditorWindowController(url: url, onExport: exported)
            imageEditor.onPin = { [weak self] imageURL in
                guard let self else { return }
                self.pendingWrites += 1
                Task {
                    defer { self.pendingWrites -= 1 }
                    do { self.pin(try await self.ingestTemporaryCapture(imageURL)) }
                    catch { showError(error) }
                }
            }
            imageEditor.onCapture = { [weak self] in
                guard let self, self.terminationTask == nil, self.captureTask == nil, !self.capture.isCapturing, self.recorder.state == .idle else { return nil }
                self.pendingWrites += 1
                defer { self.pendingWrites -= 1 }
                do { return try await self.captureWithHiddenWindows(.area).map(\.url) }
                catch is CancellationError { return nil }
                catch { showError(error); return nil }
            }
            editor = imageEditor
        }
        editors.append(editor)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func copy(_ item: CaptureItem) {
        clipboardTask?.cancel()
        clipboardGeneration += 1
        let generation = clipboardGeneration
        let changeCount = NSPasteboard.general.changeCount
        if item.kind.isVideo {
            if item.kind == .videoProject { edit(item); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item.url(in: library.root) as NSURL])
            return
        }
        clipboardTask = Task {
            do {
                let url = try renderedImageURL(item)
                let data = try await Task.detached { () -> Data in
                    let image = try ImageProject.readImage(url)
                    let output = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw CliptError.message("The image couldn’t be copied.") }
                    CGImageDestinationAddImage(dest, image, nil)
                    guard CGImageDestinationFinalize(dest) else { throw CliptError.message("The image couldn’t be copied.") }
                    return output as Data
                }.value
                guard !Task.isCancelled, clipboardGeneration == generation, NSPasteboard.general.changeCount == changeCount else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            } catch is CancellationError {} catch { showError(error) }
        }
    }

    func save(_ item: CaptureItem) {
        if item.kind == .videoProject { edit(item); return }
        guard let source = item.shareURL(in: library.root) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title + "." + source.pathExtension
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: source.pathExtension) ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            self.pendingWrites += 1
            Task {
                defer { self.pendingWrites -= 1 }
                do { try await Task.detached { try ExportFile.copy(source, to: destination) }.value }
                catch { showError(error) }
            }
        }
    }

    func pin(_ item: CaptureItem) {
        Task { [self] in
            do {
                let url = try renderedImageURL(item)
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                guard let image = NSImage(data: data) else { throw CliptError.message("The image couldn’t be opened.") }
                let panel = PinnedImagePanel(image: image)
                panel.onEdit = { [weak self] in self?.edit(item) }
                panel.onClose = { [weak self, weak panel] in self?.pins.removeAll { $0 === panel } }
                pins.append(panel)
                pinsVisible = true
                panel.orderFrontRegardless()
            } catch { showError(error) }
        }
    }

    private func renderedImageURL(_ item: CaptureItem) throws -> URL {
        guard let url = item.shareURL(in: library.root), FileManager.default.fileExists(atPath: url.path) else {
            throw CliptError.message("Open this project in the editor and export it before sharing.")
        }
        return url
    }

    private func togglePins() {
        pinsVisible.toggle()
        for pin in pins { if pinsVisible { pin.orderFrontRegardless() } else { pin.orderOut(nil) } }
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(title: "Clipt", size: NSSize(width: 960, height: 640), root: HistoryView(
                library: library, onEdit: edit, onCopy: copy, onSave: save, onPin: pin, onImport: openFile,
                onCapture: { [weak self] in self?.takeCapture(.area) }
            ))
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = makeWindow(title: "Clipt Settings", size: NSSize(width: 600, height: 590), root: SettingsView(shortcuts: shortcuts)) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showRecognizedText(_ text: String) {
        clipboardTask?.cancel()
        clipboardGeneration += 1
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let window = makeWindow(title: "Captured Text", size: NSSize(width: 560, height: 360), root: OCRResultView(text: text))
        let controller = NSWindowController(window: window)
        editors.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showRecordingSetup() {
        guard terminationTask == nil, recorder.state == .idle, recordingTask == nil, !capture.isCapturing else { recordingPanel?.orderFrontRegardless(); return }
        recordingSetup = makeWindow(title: "Record", size: NSSize(width: 460, height: 560), root: RecordingSetupView { [weak self] options in self?.startRecording(options) })
        recordingSetup?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRecording(_ options: RecordingOptions) {
        guard terminationTask == nil, recorder.state == .idle, recordingTask == nil, !capture.isCapturing else { return }
        recordingSetup?.orderOut(nil)
        recordingHiddenWindows = hideCaptureWindows()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Recording"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingControls(recorder: recorder, onPause: togglePause, onStop: stopRecording, onCancel: { [weak self] in self?.recordingTask?.cancel() }))
        panel.center()
        recordingPanel = panel
        panel.orderFrontRegardless()
        recordingTask = Task {
            defer { recordingTask = nil }
            do { try await recorder.start(options: options) }
            catch is CancellationError { panel.orderOut(nil); restoreRecordingWindows() }
            catch { panel.orderOut(nil); restoreRecordingWindows(); showError(error) }
        }
    }

    private func stopRecording() {
        guard recorder.state == .recording || recorder.state == .paused else { return }
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                let item = try await finishRecording()
                edit(item)
                if let warning = recorder.lastWarning { showError(CliptError.message(warning)) }
            } catch { showError(error) }
        }
    }

    private func togglePause() {
        Task {
            do {
                if recorder.state == .paused { try await recorder.resume() }
                else if recorder.state == .recording { try await recorder.pause() }
            } catch { showError(error) }
        }
    }

    private func restoreRecordingWindows() {
        restoreCaptureWindows(recordingHiddenWindows)
        recordingHiddenWindows.removeAll()
    }

    private func finishRecording() async throws -> CaptureItem {
        defer { recordingPanel?.orderOut(nil); restoreRecordingWindows() }
        return try await ingestRecording(try await recorder.stop())
    }

    private func ingestRecording(_ url: URL) async throws -> CaptureItem {
        let item = try await library.ingest(url)
        let recordings = try RecordingController.recordingsDirectory().resolvingSymlinksInPath().standardizedFileURL
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        if source.deletingLastPathComponent() == recordings,
           source.pathExtension == "cliptvideo",
           !FileManager.default.fileExists(atPath: source.appendingPathComponent("recording-in-progress").path) {
            do {
                try await Task.detached(priority: .utility) {
                    try Data(item.id.uuidString.utf8).write(to: source.appendingPathComponent("imported-to-library"), options: .atomic)
                    try FileManager.default.removeItem(at: source)
                }.value
            }
            catch { library.error = "The recording was saved, but its working copy couldn’t be removed: \(error.localizedDescription)" }
        }
        return item
    }

    private func ingestTemporaryCapture(_ url: URL) async throws -> CaptureItem {
        let item = try await library.ingest(url)
        await cleanupTemporaryCapture(url)
        return item
    }

    private func cleanupTemporaryCapture(_ url: URL) async {
        do { try await Task.detached(priority: .utility) { try ImageFile.removeTemporary(url) }.value }
        catch { library.error = "The capture was saved, but its temporary file couldn’t be removed: \(error.localizedDescription)" }
    }

    private func importRecording(_ url: URL, openEditor: Bool) {
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                let item = try await ingestRecording(url)
                if openEditor { edit(item) } else { shelf.present(item) }
            } catch { showError(error) }
        }
    }

    private func updateStatus() {
        if recorder.state == .recording || recorder.state == .paused {
            statusItem.button?.image = NSImage(systemSymbolName: recorder.state == .paused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: "Recording")
            statusItem.button?.title = " " + Self.duration(recorder.elapsed)
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Clipt")
            statusItem.button?.title = ""
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, root: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        return window
    }
}

enum ExportFile {
    static func copy(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".clipt-export-\(UUID().uuidString).\(destination.pathExtension)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

struct OCRResultView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    .keyboardShortcut("c", modifiers: .command)
            }
        }.padding(20).frame(minWidth: 360, minHeight: 220)
    }
}
