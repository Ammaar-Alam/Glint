import AppKit
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case allInOne, area, window, fullScreen, previousArea, scrolling, text

    var id: String { rawValue }
    var title: String {
        switch self {
        case .allInOne: return "All-in-One Capture"
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullScreen: return "Capture Screen"
        case .previousArea: return "Capture Previous Area"
        case .scrolling: return "Scrolling Capture"
        case .text: return "Capture Text"
        }
    }
}

struct CaptureResult {
    let url: URL
    let recognizedText: String?
}

@MainActor
final class CaptureService {
    var includeCursor = false
    var showWindowShadow = true
    var freezeScreen = false
    var hideDesktop = false
    var onRecord: (() -> Void)?
    private(set) var isCapturing = false
    private let regionDefaultsKey = "lastCaptureRegion"

    func capture(_ mode: CaptureMode, delay: TimeInterval = 0) async throws -> CaptureResult? {
        guard !isCapturing else { throw GlintError.message("A capture is already in progress.") }
        isCapturing = true
        defer { isCapturing = false }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw GlintError.message("Allow Glint in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let cursor = includeCursor
        let shadow = showWindowShadow
        let hiddenDesktop = hideDesktop
        let needsSelector = mode != .fullScreen && mode != .previousArea
        var frozenFrames: [FrozenDisplayFrame] = []
        var delayed = false
        if freezeScreen && needsSelector && mode != .window && mode != .scrolling {
            guard await CaptureCountdown.wait(seconds: delay) else { return nil }
            delayed = true
            for display in content.displays {
                let image = try await CaptureFrame.region(display.frame, content: content, showsCursor: cursor, hideDesktop: hiddenDesktop)
                frozenFrames.append(FrozenDisplayFrame(displayID: display.displayID, frame: display.frame, image: image))
            }
        }
        let selected: CaptureSelection
        if needsSelector {
            guard let choice = await SelectionController.selectCapture(mode: mode, windows: content.windows, frozenFrames: frozenFrames,
                                                                       allowsRecording: onRecord != nil, magnifier: { rect in
                try? await CaptureFrame.region(rect, content: content, showsCursor: false, hideDesktop: hiddenDesktop)
            }) else { return nil }
            selected = choice
        } else if mode == .fullScreen {
            let point = CaptureGeometry.quartzPoint(fromCocoa: NSEvent.mouseLocation, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
            guard let display = content.displays.first(where: { $0.frame.contains(point) }) ?? content.displays.first else {
                throw GlintError.message("No screen is available to capture.")
            }
            selected = .region(display.frame, .fullScreen)
        } else {
            guard let saved = UserDefaults.standard.string(forKey: regionDefaultsKey) else {
                throw GlintError.message("Capture an area first to reuse its selection.")
            }
            let rect = NSRectFromString(saved)
            guard !rect.isEmpty, content.displays.contains(where: { $0.frame.intersects(rect) }) else {
                throw GlintError.message("The previous area is no longer on a connected screen.")
            }
            selected = .region(rect, .previousArea)
        }
        if case .record = selected { onRecord?(); return nil }
        if !delayed, !(await CaptureCountdown.wait(seconds: delay)) { return nil }
        let image: CGImage
        let effectiveMode: CaptureMode
        switch selected {
        case .record: return nil
        case .window(let window):
            effectiveMode = .window
            image = try await CaptureFrame.window(window, showsCursor: cursor, shadow: shadow)
        case .region(let rect, let chosenMode):
            effectiveMode = chosenMode
            if chosenMode != .fullScreen { UserDefaults.standard.set(NSStringFromRect(rect), forKey: regionDefaultsKey) }
            if chosenMode == .scrolling {
                guard let result = try await ScrollingCaptureController.capture(rect: rect, content: content, hideDesktop: hiddenDesktop) else { return nil }
                image = result
            } else if !frozenFrames.isEmpty {
                image = try await CaptureFrame.frozenRegion(rect, frames: frozenFrames)
            } else {
                image = try await CaptureFrame.region(rect, content: content, showsCursor: cursor, hideDesktop: hiddenDesktop)
            }
        }
        try Task.checkCancellation()
        let url = ImageFile.temporaryURL()
        try await Task.detached(priority: .userInitiated) { try ImageFile.write(image, to: url) }.value
        if effectiveMode == .text {
            do {
                let text = try await OCRService.recognize(url: url)
                guard !text.isEmpty else { throw GlintError.message("No text or QR code was found in this area.") }
                return CaptureResult(url: url, recognizedText: text)
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
        return CaptureResult(url: url, recognizedText: nil)
    }
}

enum CaptureFrame {
    static func displayFilter(display: SCDisplay, content: SCShareableContent, hideDesktop: Bool) -> SCContentFilter {
        let ownApplication = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let wallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let desktopElements = hideDesktop ? content.windows.filter { $0.windowLayer > wallpaperLevel && $0.windowLayer < 0 } : []
        return SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: desktopElements)
    }

    static func region(_ rect: CGRect, content: SCShareableContent, showsCursor: Bool, hideDesktop: Bool = false) async throws -> CGImage {
        let content = content.applications.contains(where: { $0.processID == ProcessInfo.processInfo.processIdentifier })
            ? content : try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let parts = content.displays.filter { $0.frame.intersects(rect) }
        guard !parts.isEmpty, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            throw GlintError.message("The selected area is outside the connected screens.")
        }
        var frames: [(CGRect, CGImage)] = []
        var outputScale: CGFloat = 1
        for display in parts {
            try Task.checkCancellation()
            let intersection = rect.intersection(display.frame)
            let filter = displayFilter(display: display, content: content, hideDesktop: hideDesktop)
            let scale = CGFloat(filter.pointPixelScale)
            outputScale = max(outputScale, scale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CaptureGeometry.displayLocalRect(rect, displayFrame: display.frame)
            configuration.width = max(1, Int((intersection.width * scale).rounded()))
            configuration.height = max(1, Int((intersection.height * scale).rounded()))
            configuration.showsCursor = showsCursor
            configuration.captureResolution = .best
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            frames.append((intersection, image))
        }
        return try await composite(frames, in: rect, scale: outputScale)
    }

    static func frozenRegion(_ rect: CGRect, frames: [FrozenDisplayFrame]) async throws -> CGImage {
        var cropped: [(CGRect, CGImage)] = []
        var outputScale: CGFloat = 1
        for frame in frames where frame.frame.intersects(rect) {
            let intersection = frame.frame.intersection(rect)
            let scaleX = CGFloat(frame.image.width) / frame.frame.width
            let scaleY = CGFloat(frame.image.height) / frame.frame.height
            let source = CGRect(x: (intersection.minX - frame.frame.minX) * scaleX,
                                y: (intersection.minY - frame.frame.minY) * scaleY,
                                width: intersection.width * scaleX, height: intersection.height * scaleY)
            guard let image = frame.image.cropping(to: source) else { continue }
            outputScale = max(outputScale, scaleX)
            cropped.append((intersection, image))
        }
        guard !cropped.isEmpty else { throw GlintError.message("The selected area is outside the frozen screens.") }
        return try await composite(cropped, in: rect, scale: outputScale)
    }

    private static func composite(_ frames: [(CGRect, CGImage)], in rect: CGRect, scale: CGFloat) async throws -> CGImage {
        if frames.count == 1, frames[0].0 == rect { return frames[0].1 }
        let images = frames
        return try await Task.detached(priority: .userInitiated) {
            let width = Int((rect.width * scale).rounded())
            let height = Int((rect.height * scale).rounded())
            guard width > 0, height > 0, width <= 32_768, height <= 32_768,
                  Double(width) * Double(height) <= 80_000_000,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw GlintError.message("The selected area is too large to capture.")
            }
            for (frame, image) in images {
                let target = CGRect(x: (frame.minX - rect.minX) * scale, y: (rect.maxY - frame.maxY) * scale,
                                    width: frame.width * scale, height: frame.height * scale)
                context.draw(image, in: target)
            }
            guard let image = context.makeImage() else { throw GlintError.message("The screens couldn’t be combined.") }
            return image
        }.value
    }

    static func window(_ window: SCWindow, showsCursor: Bool, shadow: Bool) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = showsCursor
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard shadow else { return image }
        return try await Task.detached(priority: .userInitiated) {
            let padding = Int(24 * scale)
            guard let context = CGContext(data: nil, width: image.width + padding * 2, height: image.height + padding * 2,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw GlintError.message("The window shadow couldn’t be rendered.")
            }
            context.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 12 * scale, color: CGColor(gray: 0, alpha: 0.35))
            context.draw(image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
            guard let result = context.makeImage() else { throw GlintError.message("The window couldn’t be rendered.") }
            return result
        }.value
    }
}

@MainActor
private final class CaptureCountdown: NSObject {
    private var cancelled = false
    private var panel: NSPanel?

    static func wait(seconds: TimeInterval) async -> Bool {
        guard seconds.isFinite, seconds > 0 else { return !Task.isCancelled }
        let countdown = CaptureCountdown()
        return await countdown.run(seconds: min(seconds, 60))
    }

    private func run(seconds: TimeInterval) async -> Bool {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 180, height: 120), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.title = "Capture"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        label.alignment = .center
        label.frame = CGRect(x: 20, y: 55, width: 140, height: 45)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCapture))
        cancel.frame = CGRect(x: 45, y: 14, width: 90, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(cancel)
        panel.center()
        panel.orderFrontRegardless()
        let end = Date().addingTimeInterval(seconds)
        while !cancelled && !Task.isCancelled && Date() < end {
            label.stringValue = String(max(1, Int(ceil(end.timeIntervalSinceNow))))
            do { try await Task.sleep(for: .milliseconds(100)) } catch { cancelled = true }
        }
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        return !cancelled && !Task.isCancelled
    }

    @objc private func cancelCapture() { cancelled = true }
}
