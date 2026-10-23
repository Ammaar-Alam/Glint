import AppKit
import Carbon
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct GlintMain {
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
    private var recordingPanel: NSPanel?
    private var recordingOptions = RecordingOptions()
    private var editors: [NSWindowController] = []
    private var pins: [PinnedImagePanel] = []
    private var captureTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var closeObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var pinsVisible = true
    private var terminationTask: Task<Void, Never>?
    private var pendingWrites = 0
    private var clipboardTask: Task<Void, Never>?
    private var recordingHiddenWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let launchInBackground = launchEvent?.eventID == kAEOpenApplication &&
            (launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem)
        UserDefaults.standard.register(defaults: ["windowShadow": true, "shelfPosition": "bottomLeft", "filenameTemplate": "Glint {date} at {time}", "showMenuBarIcon": true,
                                                  "showMagnifier": true, "shelfScale": 1.0, "shelfFollowsPointer": true])
        CaptureAction.migrate()
        makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon
        statusItem.button?.toolTip = "Glint"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
        updateStatus()
        shortcuts.onAction = { [weak self] in self?.perform($0) }
        shortcuts.start()
        capture.onRecord = { [weak self] target, options in
            Task { @MainActor [weak self] in
                await self?.captureTask?.value
                self?.startRecording(options, target: target)
            }
        }
        shelf.onCommand = { [weak self] in self?.perform($0, on: $1) }
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
                self?.updateDock(closing: window)
            }
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDock() }
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
            // a relaunch after granting access returns to the welcome window to confirm it
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "onboarded") || !CGPreflightScreenCaptureAccess() || defaults.bool(forKey: "screenAccessRequested") { showOnboarding() }
            else if !launchInBackground { showHome() }
        }
    }

    // a dock icon while a window is open, menu bar only otherwise
    private func updateDock(closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // the dock icon returns to open windows, opening the app otherwise just leaves it in the menu bar
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHome() }
        return true
    }

    // with the menu bar icon hidden, opening the app is the way back to settings
    private func showHome() {
        if !UserDefaults.standard.bool(forKey: "showMenuBarIcon") { showSettings() }
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
            guard url.scheme == "glint" else { continue }
            guard UserDefaults.standard.bool(forKey: "automationEnabled") else {
                showError(GlintError.message("Enable Allow capture URLs in Glint Settings to use automation."))
                continue
            }
            switch url.host {
            case "capture":
                let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mode" })?.value ?? "area"
                if let mode = CaptureMode(rawValue: value) { takeCapture(mode) }
                else { showError(GlintError.message("This capture mode isn’t supported.")) }
            case "record": showRecordingSetup()
            case "stop": stopRecording()
            case "history": showHistory()
            default: showError(GlintError.message("This Glint command isn’t supported."))
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
            showError(GlintError.message("Finish or cancel the current capture or save before quitting."))
            return false
        }
        if recorder.state != .idle {
            let alert = NSAlert()
            alert.messageText = recorder.state == .preparing ? "Cancel recording and quit?" : "Finish recording and quit?"
            alert.informativeText = "Your recording will be kept in Glint."
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
            showError(GlintError.message("Glint is still finishing your work. Try quitting again when it finishes."))
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
        statusTimer?.invalidate()
        captureTask?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
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
        menu.addItem(HandlerMenuItem("Open File…", key: "o", symbol: "folder") { [weak self] in self?.openFile() })
        menu.addItem(HandlerMenuItem("Open Clipboard", symbol: "doc.on.clipboard") { [weak self] in self?.openClipboard() })
        let history = HandlerMenuItem("History", symbol: "clock") { [weak self] in self?.showHistory() }
        history.show(shortcuts.shortcuts[.history])
        menu.addItem(history)
        menu.addItem(HandlerMenuItem("Reopen Last Popup", symbol: "rectangle.stack") { [weak self] in self?.shelf.reopenLast() })
        if !pins.isEmpty {
            let pinMenu = NSMenu()
            pinMenu.addItem(HandlerMenuItem(pinsVisible ? "Hide Pins" : "Show Pins") { [weak self] in self?.togglePins() })
            pinMenu.addItem(HandlerMenuItem("Unlock Pins") { [weak self] in self?.pins.forEach { $0.ignoresMouseEvents = false } })
            pinMenu.addItem(HandlerMenuItem("Close Pins") { [weak self] in self?.pins.forEach { $0.close() } })
            let pinItem = NSMenuItem(title: "Pins", action: nil, keyEquivalent: "")
            pinItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
            pinItem.submenu = pinMenu
            menu.addItem(pinItem)
        }
        menu.addItem(.separator())
        menu.addItem(HandlerMenuItem("Settings…", key: ",", symbol: "gearshape") { [weak self] in self?.showSettings() })
        menu.addItem(HandlerMenuItem("About Glint", symbol: "info.circle") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) })
        menu.addItem(HandlerMenuItem("Quit Glint", key: "q", symbol: "power") { NSApp.terminate(nil) })
    }

    private func addCaptureCommands(to menu: NSMenu) {
        for mode in CaptureMode.allCases {
            let item = HandlerMenuItem(mode.title, symbol: mode.symbol) { [weak self] in self?.takeCapture(mode) }
            item.show(ShortcutAction(rawValue: mode.rawValue).flatMap { shortcuts.shortcuts[$0] })
            item.isEnabled = captureTask == nil && !capture.isCapturing && recorder.state == .idle
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if recorder.state == .recording || recorder.state == .paused {
            let stop = HandlerMenuItem("Stop Recording", symbol: "stop.circle") { [weak self] in self?.stopRecording() }
            stop.show(shortcuts.shortcuts[.record])
            menu.addItem(stop)
            menu.addItem(HandlerMenuItem(recorder.state == .paused ? "Resume Recording" : "Pause Recording",
                                         symbol: recorder.state == .paused ? "play.circle" : "pause.circle") { [weak self] in self?.togglePause() })
        } else {
            let record = HandlerMenuItem("Record Screen…", symbol: "record.circle") { [weak self] in self?.showRecordingSetup() }
            record.show(shortcuts.shortcuts[.record])
            record.isEnabled = recorder.state == .idle
            menu.addItem(record)
            let gif = HandlerMenuItem("Record GIF…", symbol: "photo.stack") { [weak self] in self?.showRecordingSetup(.gif) }
            gif.isEnabled = recorder.state == .idle
            menu.addItem(gif)
        }
    }

    private func makeMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Glint")
        appMenu.addItem(HandlerMenuItem("Settings…", key: ",") { [weak self] in self?.showSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(HandlerMenuItem("Quit Glint", key: "q") { NSApp.terminate(nil) })
        let appItem = NSMenuItem(title: "Glint", action: nil, keyEquivalent: "")
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

    func takeCapture(_ mode: CaptureMode, recording: RecordingFormat? = nil) {
        guard terminationTask == nil, captureTask == nil, !capture.isCapturing, recorder.state == .idle else { NSSound.beep(); return }
        guard CGPreflightScreenCaptureAccess() else { showOnboarding(); return }
        captureTask = Task {
            defer { captureTask = nil }
            do {
                guard let result = try await captureWithHiddenWindows(mode, recording: recording) else { return }
                if let text = result.recognizedText {
                    showRecognizedText(text)
                    await cleanupTemporaryCapture(result.url)
                } else { handleCapture(try await ingestTemporaryCapture(await applyDefaultBackground(result.url))) }
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

    private func captureWithHiddenWindows(_ mode: CaptureMode, recording: RecordingFormat? = nil) async throws -> CaptureResult? {
        let hidden = hideCaptureWindows()
        defer { restoreCaptureWindows(hidden) }
        configureCapture()
        return try await capture.capture(mode, recording: recording)
    }

    private func handleCapture(_ item: CaptureItem, recording: Bool = false) {
        let actions = CaptureAction.enabled(recording: recording)
        if item.kind == .videoProject {
            deliverRecording(item, save: actions.contains(.save), copy: actions.contains(.copy))
        } else {
            if actions.contains(.copy) { copy(item) }
            if actions.contains(.save) {
                if let folder = CaptureFolder.current { saveToFolder(item, folder: folder) } else { save(item) }
            }
        }
        if actions.contains(.editor) { edit(item) }
        if actions.contains(.popup) { shelf.present(item) }
    }

    // a failed style keeps the plain capture rather than losing it
    private func applyDefaultBackground(_ url: URL) async -> URL {
        guard let preset = EditorDefaults.backgroundPreset else { return url }
        let presets = ImageEditorModel.presetDirectory
        do {
            let project = try await Task.detached(priority: .userInitiated) { try EditorDefaults.styledProject(url, background: preset, presetDirectory: presets) }.value
            await cleanupTemporaryCapture(url)
            return project
        } catch {
            library.error = "The default background couldn’t be applied: \(error.localizedDescription)"
            return url
        }
    }

    // movies and animated gifs are copied as they are, only stills convert to the chosen format
    static func screenshotFormat(for item: CaptureItem, source: URL) -> ScreenshotFormat? {
        item.kind.isVideo || source.pathExtension.lowercased() == "gif" ? nil : ScreenshotFormat.current
    }

    private func saveToFolder(_ item: CaptureItem, folder: URL) {
        guard let source = item.shareURL(in: library.root) else { edit(item); return }
        let format = Self.screenshotFormat(for: item, source: source)
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                try await Task.detached {
                    if let format { _ = try CaptureFolder.saveImage(source, named: item.title, format: format, in: folder) }
                    else { _ = try CaptureFolder.saveFile(source, named: item.title, in: folder) }
                }.value
                Toast.show("Saved to \(FileManager.default.displayName(atPath: folder.path))", symbol: "arrow.down.circle.fill")
            } catch { showError(error) }
        }
    }

    // recordings are shared as a rendered movie, saved to the folder or asked for, and copied as a file
    private func deliverRecording(_ item: CaptureItem, save: Bool, copy: Bool) {
        guard save else { if copy { exportRecording(item, to: nil, copy: true) }; return }
        if let folder = CaptureFolder.current {
            do { exportRecording(item, to: try CaptureFolder.destination(in: folder, name: item.title, pathExtension: "mp4"), copy: copy) }
            catch { showError(error) }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title + ".mp4"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            if url != nil || copy { self.exportRecording(item, to: url, copy: copy) }
        }
    }

    private func exportRecording(_ item: CaptureItem, to target: URL?, copy: Bool) {
        let clipboard = ClipboardWriter.general
        let request = copy ? clipboard.begin() : nil
        let directory = item.url(in: library.root)
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                // ponytail: a copy-only movie lives in the temporary folder until macOS clears it
                let destination = try target ?? {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    return folder.appendingPathComponent(item.title + ".mp4")
                }()
                let project = try VideoProject.load(from: directory)
                defer { CaptureFolder.release(destination) }
                try await VideoExporter.export(project: project, directory: directory, destination: destination, format: .mp4) { _ in }
                if let request { clipboard.commit(request) { _ = $0.writeObjects([destination as NSURL]) } }
            } catch { showError(error) }
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
        panel.allowedContentTypes = [.image, .movie, UTType(exportedAs: "app.glint.image-project", conformingTo: .package), UTType(exportedAs: "app.glint.video-project", conformingTo: .package)]
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
        } else { showError(GlintError.message("Copy an image or video file first.")) }
    }

    func edit(_ item: CaptureItem) {
        guard terminationTask == nil else { return }
        let url = item.url(in: library.root)
        guard FileManager.default.fileExists(atPath: url.path) else { showError(GlintError.message("This capture is no longer available.")); return }
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
        let clipboard = ClipboardWriter.general
        let request = clipboard.begin()
        // a GIF goes as its file so it stays animated where it is pasted
        if item.kind.isVideo || item.filename.hasSuffix(".gif") {
            if item.kind == .videoProject { edit(item); return }
            clipboard.commit(request) { _ = $0.writeObjects([item.url(in: library.root) as NSURL]) }
            Toast.show("Copied")
            return
        }
        clipboardTask = Task {
            do {
                let url = try renderedImageURL(item)
                let data = try await Task.detached { () -> Data in
                    let image = try ImageProject.readImage(url)
                    let output = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw GlintError.message("The image couldn’t be copied.") }
                    CGImageDestinationAddImage(dest, image, nil)
                    guard CGImageDestinationFinalize(dest) else { throw GlintError.message("The image couldn’t be copied.") }
                    return output as Data
                }.value
                guard !Task.isCancelled else { return }
                try clipboard.commit(request) {
                    guard $0.setData(data, forType: .png) else { throw GlintError.message("The image couldn’t be copied.") }
                }
                Toast.show("Copied")
            } catch is CancellationError {} catch { showError(error) }
        }
    }

    func save(_ item: CaptureItem) {
        if item.kind == .videoProject { edit(item); return }
        guard let source = item.shareURL(in: library.root) else { return }
        let format = Self.screenshotFormat(for: item, source: source)
        let type = format?.type ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title + "." + (type.preferredFilenameExtension ?? source.pathExtension)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            self.pendingWrites += 1
            Task {
                defer { self.pendingWrites -= 1 }
                do {
                    try await Task.detached {
                        if let format { try CaptureFolder.writeImage(source, format: format, to: destination) }
                        else { try ExportFile.copy(source, to: destination) }
                    }.value
                } catch { showError(error) }
            }
        }
    }

    func perform(_ command: CaptureCommand, on item: CaptureItem) {
        // projects reveal and share their flattened render, never the package
        let file = item.shareURL(in: library.root) ?? item.url(in: library.root)
        switch command {
        case .copy: copy(item)
        case .save: saveToFolder(item, folder: CaptureFolder.current ?? URL.desktopDirectory)
        case .saveAs: save(item)
        case .edit: edit(item)
        case .pin: pin(item)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([file])
        case .copyPath:
            clipboardTask?.cancel()
            let clipboard = ClipboardWriter.general
            clipboard.commit(clipboard.begin()) { _ = $0.setString(file.path, forType: .string) }
        case .trash:
            Task {
                do {
                    try await library.trash(item)
                    if shelf.shelf.ids.contains(item.id) { shelf.dismiss(item) }
                } catch { showError(error) }
            }
        case .rename, .close, .closeAll: break
        }
    }

    func pin(_ item: CaptureItem) {
        Task { [self] in
            do {
                let url = try renderedImageURL(item)
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                guard let image = NSImage(data: data) else { throw GlintError.message("The image couldn’t be opened.") }
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
            throw GlintError.message("Open this project in the editor and export it before sharing.")
        }
        return url
    }

    private func togglePins() {
        pinsVisible.toggle()
        for pin in pins { if pinsVisible { pin.orderFrontRegardless() } else { pin.orderOut(nil) } }
    }

    func showHistory() {
        if historyWindow == nil {
            let window = makeWindow(title: "Glint", size: NSSize(width: 1000, height: 680), root: HistoryView(
                library: library, shortcuts: shortcuts, onCommand: { [weak self] in self?.perform($0, on: $1) }, onImport: openFile,
                onCapture: { [weak self] in self?.takeCapture(.area) }, onRecord: { [weak self] in self?.showRecordingSetup() }
            ), draggable: false)
            // an empty unified toolbar only sets the titlebar height, the view draws the bar
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var onboardingWindow: NSWindow?

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = makeWindow(title: "Welcome to Glint", size: NSSize(width: 520, height: 560), root: OnboardingView(
                relaunch: { [weak self] in self?.relaunch() },
                finish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    UserDefaults.standard.set(false, forKey: "screenAccessRequested")
                    self?.onboardingWindow?.close()
                    self?.onboardingWindow = nil
                }))
            window.styleMask.remove(.resizable)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // macOS applies a new screen recording grant only to a fresh launch
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do { try task.run() } catch { showError(error); return }
        NSApp.terminate(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = makeWindow(title: "Glint Settings", size: NSSize(width: 760, height: 580), root: SettingsView(shortcuts: shortcuts))
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showRecognizedText(_ text: String) {
        clipboardTask?.cancel()
        let clipboard = ClipboardWriter.general
        clipboard.commit(clipboard.begin()) { _ = $0.setString(text, forType: .string) }
        let window = makeWindow(title: "Captured Text", size: NSSize(width: 560, height: 360), root: OCRResultView(text: text))
        let controller = NSWindowController(window: window)
        editors.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // recording starts from the capture overlay with its recording bar showing
    func showRecordingSetup(_ format: RecordingFormat = .video) {
        guard terminationTask == nil, recorder.state == .idle, recordingTask == nil, recordingPanel?.isVisible != true else {
            recordingPanel?.orderFrontRegardless(); return
        }
        takeCapture(.allInOne, recording: format)
    }

    private func startRecording(_ options: RecordingOptions, target: CaptureSelection) {
        guard terminationTask == nil, recorder.state == .idle, recordingTask == nil, !capture.isCapturing else { return }
        recordingOptions = options
        recordingHiddenWindows = hideCaptureWindows()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Recording"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstMouseHostingView(rootView: RecordingControls(
            recorder: recorder, showsMicrophone: options.capturesMicrophone, onPause: togglePause, onStop: stopRecording,
            onCancel: { [weak self] in self?.recordingTask?.cancel() },
            onRestart: { [weak self] in self?.discardRecording(restart: true) },
            onDelete: { [weak self] in self?.discardRecording(restart: false) }))
        host.sizingOptions = []
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // wide enough for every state, the capsule centers itself
            let size = CGSize(width: 420, height: host.fittingSize.height)
            panel.setFrame(CGRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + 8, width: size.width, height: size.height), display: false)
        }
        recordingPanel = panel
        panel.orderFrontRegardless()
        recordingTask = Task {
            defer { recordingTask = nil }
            do { try await recorder.start(options: options, target: target) }
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
                let item = try await finishRecording(gif: recordingOptions.format == .gif)
                // a recorded gif goes straight to the popup, video projects follow the recording actions
                if item.kind.isVideo { handleCapture(item, recording: true) } else { shelf.present(item) }
                if let warning = recorder.lastWarning { showError(GlintError.message(warning)) }
            } catch { showError(error) }
        }
    }

    // restart and delete throw away what was recorded, so they ask first
    private func discardRecording(restart: Bool) {
        guard recorder.state == .recording || recorder.state == .paused else { return }
        let alert = NSAlert()
        alert.messageText = restart ? "Restart recording?" : "Delete recording?"
        alert.informativeText = "What you’ve recorded so far will be deleted."
        alert.addButton(withTitle: restart ? "Restart" : "Delete")
        alert.addButton(withTitle: "Cancel")
        if !restart { alert.buttons.first?.hasDestructiveAction = true }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, recorder.state == .recording || recorder.state == .paused else { return }
        let options = recordingOptions
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                defer { recordingPanel?.orderOut(nil); restoreRecordingWindows() }
                let url = try await recorder.stop()
                try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: url) }.value
            } catch { showError(error); return }
            if restart { showRecordingSetup(options.format) }
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

    // a GIF that fails to render falls back to the saved project
    private func finishRecording(gif: Bool = false) async throws -> CaptureItem {
        let panel = recordingPanel
        defer { panel?.orderOut(nil) }
        let item: CaptureItem
        do {
            item = try await ingestRecording(try await recorder.stop())
            restoreRecordingWindows()
        } catch { restoreRecordingWindows(); throw error }
        guard gif else { return item }
        (panel?.contentView as? FirstMouseHostingView<RecordingControls>)?.rootView.saving = true
        do { return try await makeGIF(from: item) }
        catch { showError(error); return item }
    }

    private func makeGIF(from item: CaptureItem) async throws -> CaptureItem {
        let project = item.url(in: library.root)
        let output = ImageFile.temporaryURL(extension: "gif")
        do { try await VideoExporter.recordingGIF(project: project, destination: output) }
        catch { await cleanupTemporaryCapture(output); throw error }
        return try await ingestTemporaryCapture(output)
    }

    private func ingestRecording(_ url: URL) async throws -> CaptureItem {
        let item = try await library.ingest(url)
        let recordings = try RecordingController.recordingsDirectory().resolvingSymlinksInPath().standardizedFileURL
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        if source.deletingLastPathComponent() == recordings,
           source.pathExtension == "glintvideo",
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
        // recording controls stay reachable even when the icon is hidden
        let visible = recorder.state != .idle || UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
        if recorder.state == .recording || recorder.state == .paused {
            statusItem.button?.image = NSImage(systemSymbolName: recorder.state == .paused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: "Recording")
            statusItem.button?.title = " " + Self.duration(recorder.elapsed)
        } else {
            statusItem.button?.image = Self.menuBarIcon
            statusItem.button?.title = ""
        }
    }

    // bundled template mark, falls back to a system symbol when run outside the app bundle
    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "glint-mark", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Glint") }
        image.size = NSSize(width: 17, height: 17)
        image.isTemplate = true
        image.accessibilityDescription = "Glint"
        return image
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    // windows that drag only from their own bar pass draggable: false
    private func makeWindow<Content: View>(title: String, size: NSSize, root: Content, draggable: Bool = true) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = draggable ? NSHostingView(rootView: root) : StaticHostingView(rootView: root)
        window.center()
        return window
    }
}

enum ExportFile {
    static func copy(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".glint-export-\(UUID().uuidString).\(destination.pathExtension)")
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

    // the first free name, numbered the way Finder does
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
