import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class RecordingController {
    private(set) var state: RecordingState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var countdownRemaining = 0
    private(set) var microphoneLevel: Double = 0
    private(set) var lastWarning: String?
    private(set) var lastRecordingURL: URL?
    var onFailure: ((Error) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var writer: RecordingWriter?
    @ObservationIgnored private var cameraSession: AVCaptureSession?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var options = RecordingOptions()
    @ObservationIgnored private var project: VideoProject?
    @ObservationIgnored private var timeline = RecordingTimeline()
    @ObservationIgnored private var captureRect = CGRect.zero
    @ObservationIgnored private var isWindowCapture = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var cursorSamples: [VideoCursorSample] = []
    @ObservationIgnored private var clicks: [VideoClick] = []
    @ObservationIgnored private var keystrokes: [VideoKeystroke] = []
    @ObservationIgnored private var lastCheckpoint = 0.0
    @ObservationIgnored private var preparationError: Error?
    private let metadataQueue = DispatchQueue(label: "Glint.recording.metadata", qos: .utility)

    func start(options: RecordingOptions) async throws {
        guard state == .idle else { throw GlintError.message("A recording is already in progress.") }
        guard (1...120).contains(options.framesPerSecond), (320...7680).contains(options.maximumDimension),
              (0...10).contains(options.countdown) else { throw GlintError.message("Choose a supported recording quality and countdown.") }
        state = .preparing
        elapsed = 0; countdownRemaining = 0; microphoneLevel = 0; lastWarning = nil
        self.options = options
        timeline = RecordingTimeline(); cursorSamples = []; clicks = []; keystrokes = []; lastCheckpoint = 0
        preparationError = nil
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw GlintError.message("Allow Glint in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
            }
            if options.capturesMicrophone { try await Self.requestAccess(to: .audio, name: "Microphone") }
            if options.capturesCamera { try await Self.requestAccess(to: .video, name: "Camera") }
            if options.showsKeystrokes, !AXIsProcessTrusted() {
                throw GlintError.message("Showing keystrokes requires Accessibility access. Allow Glint in System Settings → Privacy & Security → Accessibility, or turn off Show Keys.")
            }
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let selection = try await selectContent(content, mode: options.mode)
            captureRect = selection.rect; isWindowCapture = options.mode == .window
            let config = SCStreamConfiguration()
            let size = Self.outputSize(for: selection.rect.size, scale: Double(selection.filter.pointPixelScale), maximumDimension: options.maximumDimension)
            config.width = Int(size.width); config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
            config.queueDepth = 5; config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false; config.showMouseClicks = false
            config.capturesAudio = options.capturesSystemAudio
            config.captureMicrophone = options.capturesMicrophone
            config.microphoneCaptureDeviceID = options.microphoneDeviceID
            config.sampleRate = 48000; config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = true
            config.scalesToFit = true
            if let sourceRect = selection.sourceRect { config.sourceRect = sourceRect }

            let folder = try Self.recordingsDirectory().appendingPathComponent(UUID().uuidString + ".glintvideo", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            try Data().write(to: folder.appendingPathComponent("recording-in-progress"))
            var initialProject = VideoProject(duration: 0.1, width: config.width, height: config.height, frameRate: options.framesPerSecond)
            initialProject.edits.showsCursor = options.showsCursor
            initialProject.edits.showsClicks = options.showsClicks
            initialProject.edits.showsKeystrokes = options.showsKeystrokes
            initialProject.edits.keystrokesOnlyShortcuts = options.keystrokesOnlyShortcuts
            initialProject.edits.showsCamera = options.capturesCamera
            initialProject.edits.maximumDimension = min(3840, options.maximumDimension)
            project = initialProject
            try initialProject.save(to: folder)
            let output = try RecordingWriter(directory: folder, width: config.width, height: config.height, options: options)
            writer = output
            output.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if self.state == .preparing { self.preparationError = error; return }
                    guard self.state == .recording || self.state == .paused else { return }
                    await self.handleFailure(error)
                }
            }
            output.onWindowFrame = { [weak self] rect in
                Task { @MainActor in
                    if self?.isWindowCapture == true, rect.width > 0, rect.height > 0 { self?.captureRect = rect }
                }
            }
            output.onAudioLevel = { [weak self] level in
                Task { @MainActor in self?.microphoneLevel = level }
            }
            output.onCameraStartTime = { [weak self] time in
                Task { @MainActor in self?.project?.cameraStartTime = time; self?.project?.cameraFile = "camera.mov" }
            }
            let capture = SCStream(filter: selection.filter, configuration: config, delegate: output)
            stream = capture
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            if options.capturesSystemAudio { try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue) }
            if options.capturesMicrophone { try capture.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue) }
            if options.capturesCamera { cameraSession = try Self.makeCameraSession(options: options, delegate: output) }
            for value in stride(from: options.countdown, through: 1, by: -1) {
                countdownRemaining = value
                try await Task.sleep(for: .seconds(1))
            }
            countdownRemaining = 0
            try Task.checkCancellation()
            if let session = cameraSession {
                await Task.detached(priority: .userInitiated) { session.startRunning() }.value
                output.setCameraClock(session.synchronizationClock)
                guard session.isRunning else { throw GlintError.message("The camera couldn’t be started. Check that another app isn’t using it.") }
            }
            try await capture.startCapture()
            let origin = try await output.waitForFirstFrame()
            try Task.checkCancellation()
            if let preparationError { throw preparationError }
            timeline.origin = origin
            state = .recording
            installEventMonitors()
            let updateTimer = Timer(timeInterval: 1 / Double(min(60, options.framesPerSecond)), repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
            timer = updateTimer
            RunLoop.main.add(updateTimer, forMode: .common)
            update()
        } catch {
            await cleanupFailedStart()
            state = .idle
            throw error
        }
    }

    func pause() async throws {
        guard state == .recording, let writer else { throw GlintError.message("There isn’t an active recording to pause.") }
        let now = Self.hostTime
        timeline.pause(at: now)
        await writer.pause(at: now)
        elapsed = timeline.elapsed(at: now); state = .paused; microphoneLevel = 0
        checkpoint()
    }

    func resume() async throws {
        guard state == .paused, let writer else { throw GlintError.message("There isn’t a paused recording to resume.") }
        let now = Self.hostTime
        timeline.resume(at: now)
        await writer.resume(at: now)
        state = .recording
    }

    func stop() async throws -> URL {
        guard state == .recording || state == .paused, let writer, let directory, var project else {
            throw GlintError.message("There isn’t a recording to stop.")
        }
        let end = Self.hostTime
        elapsed = timeline.elapsed(at: end)
        state = .stopping
        removeEventMonitors()
        timer?.invalidate(); timer = nil; microphoneLevel = 0
        var stoppingError: Error?
        do { try await stream?.stopCapture() } catch { stoppingError = error }
        if let session = cameraSession { await Task.detached { session.stopRunning() }.value }
        do {
            let result = try await writer.finish(at: end)
            let asset = AVURLAsset(url: directory.appendingPathComponent(project.screenFile))
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw GlintError.message("The recording is empty.") }
            project.duration = duration; project.edits.trimEnd = duration
            project.cursorSamples = cursorSamples; project.clicks = clicks; project.keystrokes = keystrokes
            if let cameraStart = result.cameraStartTime { project.cameraFile = "camera.mov"; project.cameraStartTime = cameraStart }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioIDs = try await Self.recordedAudioIDs(in: asset)
            project.systemAudioTrackID = audioIDs.system; project.microphoneAudioTrackID = audioIDs.microphone
            if options.capturesSystemAudio, project.systemAudioTrackID == nil { project.systemAudioTrackID = audioTracks.first?.trackID }
            if options.capturesMicrophone, project.microphoneAudioTrackID == nil {
                project.microphoneAudioTrackID = audioTracks.first(where: { $0.trackID != project.systemAudioTrackID })?.trackID
            }
            let finishedProject = project
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                metadataQueue.async {
                    do {
                        var sorted = finishedProject
                        sorted.cursorSamples.sort { $0.time < $1.time }; sorted.clicks.sort { $0.time < $1.time }; sorted.keystrokes.sort { $0.time < $1.time }
                        try sorted.save(to: directory)
                        try FileManager.default.removeItem(at: directory.appendingPathComponent("recording-in-progress"))
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 640, height: 480)
            if let preview = try? await generator.image(at: .zero).image {
                try? await Task.detached(priority: .utility) { try ImageFile.write(preview, to: directory.appendingPathComponent("preview.png")) }.value
            }
            var warnings = [lastWarning].compactMap { $0 }
            if result.droppedVideoFrames > 0 || result.droppedAudioSamples > 0 {
                warnings.append("The Mac couldn’t encode every sample: \(result.droppedVideoFrames) video frames and \(result.droppedAudioSamples) audio buffers were dropped. Try a lower recording resolution or frame rate.")
            }
            if options.capturesCamera, result.cameraStartTime == nil { warnings.append("The camera supplied no frames. The screen recording was saved.") }
            if options.capturesMicrophone, project.microphoneAudioTrackID == nil { warnings.append("The microphone supplied no audio. The screen recording was saved.") }
            if let stoppingError { warnings.append(stoppingError.localizedDescription) }
            lastWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            lastRecordingURL = directory
            resetSession()
            return directory
        } catch {
            lastRecordingURL = directory
            resetSession()
            throw GlintError.message("The recording couldn’t finish: \(error.localizedDescription)\nRecoverable files are kept at \(directory.path).")
        }
    }

    private func handleFailure(_ error: Error) async {
        do {
            let url = try await stop()
            onFailure?(GlintError.message("Recording stopped early: \(error.localizedDescription)\nThe captured portion was saved at \(url.path)."))
        } catch { onFailure?(error) }
    }

    private func update() {
        guard state == .recording else { return }
        let now = Self.hostTime
        elapsed = timeline.elapsed(at: now)
        microphoneLevel *= 0.93
        let position = currentPosition()
        let sample = VideoCursorSample(time: elapsed, position: position.point, visible: position.visible)
        if let last = cursorSamples.last {
            if last.position != sample.position || last.visible != sample.visible || elapsed - last.time > 0.2 { cursorSamples.append(sample) }
        } else { cursorSamples.append(sample) }
        if elapsed - lastCheckpoint >= 5 { lastCheckpoint = elapsed; checkpoint() }
    }

    private func currentPosition() -> (point: VideoPoint, visible: Bool) {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: CGDisplayBounds(CGMainDisplayID()).height - mouse.y)
        let normalized = VideoPoint(x: (point.x - captureRect.minX) / captureRect.width,
                                    y: (point.y - captureRect.minY) / captureRect.height)
        return (normalized.clamped, captureRect.contains(point))
    }

    private func installEventMonitors() {
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        if options.showsKeystrokes { mask.insert(.keyDown) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleEvent(event) }
            return event
        }
    }

    private func handleEvent(_ event: NSEvent) {
        guard state == .recording || state == .paused else { return }
        let release = event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp
        if release {
            if let index = clicks.lastIndex(where: { $0.button == event.buttonNumber && $0.releaseTime == nil }) {
                clicks[index].releaseTime = max(clicks[index].time, timeline.elapsed(at: event.timestamp))
            }
            return
        }
        guard state == .recording, let time = timeline.presentationTime(for: event.timestamp) else { return }
        if event.type == .keyDown {
            guard options.showsKeystrokes, !IsSecureEventInputEnabled() else { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isShortcut = !modifiers.intersection([.command, .control, .option]).isEmpty
            if let text = Self.keyLabel(event) { keystrokes.append(.init(time: time, text: text, isShortcut: isShortcut)) }
        } else {
            let position = currentPosition()
            if position.visible { clicks.append(.init(time: time, position: position.point, button: event.buttonNumber)) }
        }
    }

    private static func keyLabel(_ event: NSEvent) -> String? {
        let named: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = named[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased()
        guard let key, !key.isEmpty, key.count <= 8 else { return nil }
        let flags = event.modifierFlags
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
    }

    private func checkpoint() {
        guard let directory, var snapshot = project, elapsed > 0 else { return }
        snapshot.duration = elapsed; snapshot.edits.trimEnd = elapsed
        snapshot.cursorSamples = cursorSamples; snapshot.clicks = clicks; snapshot.keystrokes = keystrokes
        if options.capturesCamera { snapshot.cameraFile = "camera.mov" }
        let saved = snapshot
        metadataQueue.async { [weak self] in
            do {
                var sorted = saved
                sorted.cursorSamples.sort { $0.time < $1.time }; sorted.clicks.sort { $0.time < $1.time }; sorted.keystrokes.sort { $0.time < $1.time }
                try sorted.save(to: directory)
            }
            catch {
                Task { @MainActor in self?.lastWarning = "Recovery checkpoints couldn’t be saved: \(error.localizedDescription)" }
            }
        }
    }

    private func removeEventMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
    }

    private func cleanupFailedStart() async {
        removeEventMonitors(); timer?.invalidate(); timer = nil
        try? await stream?.stopCapture()
        if let cameraSession { await Task.detached { cameraSession.stopRunning() }.value }
        await writer?.cancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        resetSession()
    }

    private func resetSession() {
        stream = nil; writer = nil; cameraSession = nil; directory = nil; project = nil
        cursorSamples = []; clicks = []; keystrokes = []
        state = .idle; countdownRemaining = 0; microphoneLevel = 0
    }

    private static var hostTime: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private static func requestAccess(to media: AVMediaType, name: String) async throws {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: media)
        default: granted = false
        }
        guard granted else { throw GlintError.message("Allow Glint in System Settings → Privacy & Security → \(name), then try again.") }
    }

    private func selectContent(_ content: SCShareableContent, mode: RecordingMode) async throws -> (filter: SCContentFilter, rect: CGRect, sourceRect: CGRect?) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        switch mode {
        case .window:
            let windows = content.windows.filter { $0.owningApplication?.processID != ownPID && $0.frame.width > 50 && $0.frame.height > 50 && $0.windowLayer == 0 }
            guard let window = await SelectionController.selectWindow(from: windows) else { throw CancellationError() }
            return (SCContentFilter(desktopIndependentWindow: window), window.frame, nil)
        case .area:
            guard let rect = await SelectionController.selectRegion() else { throw CancellationError() }
            guard let display = content.displays.first(where: { $0.frame.contains(rect) }) else {
                throw GlintError.message("Choose a recording area inside one display.")
            }
            let source = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            return (CaptureFrame.displayFilter(display: display, content: content, hideDesktop: options.hideDesktop), rect, source)
        case .fullScreen:
            let mouse = NSEvent.mouseLocation
            let pointer = CGPoint(x: mouse.x, y: CGDisplayBounds(CGMainDisplayID()).height - mouse.y)
            guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first else {
                throw GlintError.message("No display is available to record.")
            }
            return (CaptureFrame.displayFilter(display: display, content: content, hideDesktop: options.hideDesktop), display.frame, nil)
        }
    }

    static func outputSize(for points: CGSize, scale: Double, maximumDimension: Int) -> CGSize {
        let width = max(2, points.width * max(1, scale))
        let height = max(2, points.height * max(1, scale))
        let ratio = min(1, Double(maximumDimension) / max(width, height))
        return CGSize(width: max(2, Int(width * ratio) / 2 * 2), height: max(2, Int(height * ratio) / 2 * 2))
    }

    private static func makeCameraSession(options: RecordingOptions, delegate: RecordingWriter) throws -> AVCaptureSession {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        let device: AVCaptureDevice?
        if let identifier = options.cameraDeviceID {
            device = devices.first { $0.uniqueID == identifier }
        } else { device = AVCaptureDevice.default(for: .video) }
        guard let device else { throw GlintError.message("No camera is connected.") }
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw GlintError.message("The camera couldn’t be connected.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: delegate.queue)
        guard session.canAddOutput(output) else { throw GlintError.message("The camera output isn’t available.") }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        return session
    }

    nonisolated static func recordingsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Glint/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func recoverInterruptedRecordings() async throws -> [URL] {
        try await recoverInterruptedRecordings(in: recordingsDirectory())
    }

    nonisolated static func recoverInterruptedRecordings(in directory: URL) async throws -> [URL] {
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var recovered: [URL] = []
        for folder in folders where folder.pathExtension == "glintvideo" {
            let importedMarker = folder.appendingPathComponent("imported-to-library")
            if let data = try? Data(contentsOf: importedMarker),
               let value = String(data: data, encoding: .utf8), UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            let marker = folder.appendingPathComponent("recording-in-progress")
            let interrupted = FileManager.default.fileExists(atPath: marker.path)
            do {
                var project = try VideoProject.load(from: folder)
                let asset = AVURLAsset(url: folder.appendingPathComponent(project.screenFile))
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { continue }
                if interrupted {
                    project.duration = duration; project.edits.trimEnd = duration
                    project.cursorSamples.removeAll { $0.time > duration }
                    project.clicks.removeAll { $0.time > duration }; project.keystrokes.removeAll { $0.time > duration }
                    if let camera = project.cameraFile, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(camera).path) { project.cameraFile = nil }
                    let audioIDs = try await recordedAudioIDs(in: asset)
                    project.systemAudioTrackID = audioIDs.system; project.microphoneAudioTrackID = audioIDs.microphone
                    try project.save(to: folder)
                    try FileManager.default.removeItem(at: marker)
                }
                recovered.append(folder)
            } catch { continue }
        }
        return recovered
    }

    nonisolated private static func recordedAudioIDs(in asset: AVAsset) async throws -> (system: Int32?, microphone: Int32?) {
        var system: Int32?, microphone: Int32?
        for track in try await asset.loadTracks(withMediaType: .audio) {
            for item in try await track.load(.metadata) where item.identifier == .quickTimeUserDataTrackName {
                let title = try await item.load(.stringValue)
                if title == "System Audio" { system = track.trackID }
                if title == "Microphone" { microphone = track.trackID }
            }
        }
        return (system, microphone)
    }
}
