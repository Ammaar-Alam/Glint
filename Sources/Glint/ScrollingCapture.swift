import AppKit
import ScreenCaptureKit

enum ScrollMatch: Equatable {
    case unchanged
    case forward(Int)
    case backward
    case uncertain
}

struct AutoScrollProgress {
    private(set) var unchangedFrames = 0
    private(set) var stopped = false
    private var hasScrolled = false

    mutating func didScroll() { hasScrolled = true }

    mutating func observe(_ match: ScrollMatch) -> Bool {
        guard !stopped else { return true }
        guard hasScrolled else { return false }
        switch match {
        case .forward: unchangedFrames = 0
        case .unchanged:
            unchangedFrames += 1
            stopped = unchangedFrames >= 3
        case .uncertain, .backward: stopped = true
        }
        return stopped
    }

    mutating func stop() { stopped = true }

    static func step(for height: CGFloat) -> Int32 {
        guard height.isFinite, height > 0 else { return 1 }
        return Int32(max(1, min(120, height / 5)).rounded(.down))
    }
}

struct ScrollRaster {
    let values: [UInt8]
    let length: Int
    let breadth: Int

    init(image: CGImage) throws {
        length = image.height
        breadth = min(96, image.width)
        guard let context = CGContext(data: nil, width: breadth, height: length, bitsPerComponent: 8, bytesPerRow: breadth,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw GlintError.message("The scrolling capture couldn’t be analyzed.")
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: breadth, height: length))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw GlintError.message("The scrolling capture couldn’t be read.")
        }
        values = Array(UnsafeBufferPointer(start: data, count: breadth * length))
    }

    func match(_ next: ScrollRaster) -> ScrollMatch {
        guard length == next.length, breadth == next.breadth, length >= 40 else { return .uncertain }
        let zeroError = error(comparedTo: next, shift: 0)
        if zeroError <= 0.9 { return .unchanged }
        let maximumShift = Int(Double(length) * 0.65)
        let step = max(1, length / 500)
        var candidates: [(shift: Int, error: Double)] = []
        for shift in stride(from: -maximumShift, through: maximumShift, by: step) {
            candidates.append((shift, error(comparedTo: next, shift: shift)))
        }
        guard let coarse = candidates.min(by: { $0.error < $1.error }) else { return .uncertain }
        for shift in max(-maximumShift, coarse.shift - step)...min(maximumShift, coarse.shift + step) {
            candidates.append((shift, error(comparedTo: next, shift: shift)))
        }
        guard let best = candidates.min(by: { $0.error < $1.error }), best.error < 10 else { return .uncertain }
        let separation = max(5, length / 200)
        let runnerUp = candidates.filter { abs($0.shift - best.shift) > separation }.map(\.error).min() ?? .infinity
        // Repeated rows and blank regions cannot establish a unique scroll distance
        guard runnerUp - best.error >= 0.75, best.error < zeroError * 0.65 else { return .uncertain }
        if abs(best.shift) < 2 { return .unchanged }
        return best.shift > 0 ? .forward(best.shift) : .backward
    }

    private func error(comparedTo next: ScrollRaster, shift: Int) -> Double {
        let margin = min(160, length / 8)
        let upper = length - abs(shift) - margin
        guard upper > margin else { return .infinity }
        let rowStep = max(1, (upper - margin) / 40)
        let crossMargin = max(1, breadth / 10)
        var difference = 0
        var count = 0
        for row in stride(from: margin, to: upper, by: rowStep) {
            let oldRow = row + max(0, shift)
            let newRow = row + max(0, -shift)
            for column in stride(from: crossMargin, to: breadth - crossMargin, by: 2) {
                difference += abs(Int(values[oldRow * breadth + column]) - Int(next.values[newRow * breadth + column]))
                count += 1
            }
        }
        return count > 0 ? Double(difference) / Double(count) : .infinity
    }
}

struct ScrollStitcher {
    let first: CGImage
    private var previous: ScrollRaster
    private var strips: [CGImage] = []
    private var tail: CGImage
    private let edgeInset: Int
    private(set) var length: Int
    private(set) var frameCount = 1
    private let maximumPixels = 48_000_000

    init(image: CGImage) throws {
        first = image
        previous = try ScrollRaster(image: image)
        length = image.height
        edgeInset = max(1, min(160, length / 8))
        tail = try Self.copy(image, rect: CGRect(x: 0, y: image.height - edgeInset, width: image.width, height: edgeInset))
    }

    mutating func append(_ image: CGImage) throws -> ScrollMatch {
        guard image.width == first.width, image.height == first.height else {
            throw GlintError.message("The screen resolution changed.")
        }
        let raster = try ScrollRaster(image: image)
        let match = previous.match(raster)
        guard case .forward(let distance) = match else { return match }
        guard length + distance <= 32_768, (length + distance) * first.width <= maximumPixels else {
            throw GlintError.message("This capture reached its size limit.")
        }
        let strip = try Self.copy(image, rect: CGRect(x: 0, y: image.height - edgeInset - distance, width: image.width, height: distance))
        let latestTail = try Self.copy(image, rect: CGRect(x: 0, y: image.height - edgeInset, width: image.width, height: edgeInset))
        strips.append(strip)
        tail = latestTail
        length += distance
        previous = raster
        frameCount += 1
        return match
    }

    func render() throws -> CGImage {
        guard let context = Self.context(width: first.width, height: length) else {
            throw GlintError.message("There isn’t enough memory to finish this scrolling capture.")
        }
        guard let leading = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - edgeInset)) else {
            throw GlintError.message("The first frame couldn’t be read.")
        }
        var offset = 0
        // Only the newest trailing edge is kept so fixed footers are not repeated
        for image in [leading] + strips + [tail] {
            context.draw(image, in: CGRect(x: 0, y: length - offset - image.height, width: image.width, height: image.height))
            offset += image.height
        }
        guard let image = context.makeImage() else { throw GlintError.message("The capture couldn’t be rendered.") }
        return image
    }

    private static func copy(_ image: CGImage, rect: CGRect) throws -> CGImage {
        guard let cropped = image.cropping(to: rect), let context = context(width: cropped.width, height: cropped.height) else {
            throw GlintError.message("The next part of the capture couldn’t be added.")
        }
        // A copied strip does not retain the full viewport's backing storage
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let result = context.makeImage() else { throw GlintError.message("The capture couldn’t be combined.") }
        return result
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

@MainActor
final class ScrollingCaptureController: NSObject {
    private let rect: CGRect
    private var content: SCShareableContent
    private let hideDesktop: Bool
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<CGImage?, Error>?
    private var sampleTask: Task<Void, Never>?
    private var stitcher: ScrollStitcher?
    private var finishing = false
    private let status = NSTextField(labelWithString: "")
    private let doneButton = NSButton()
    private var autoProgress = AutoScrollProgress()
    private var autoTarget: (pid: pid_t, window: CGWindowID)?

    private init(rect: CGRect, content: SCShareableContent, hideDesktop: Bool) {
        self.rect = rect
        self.content = content
        self.hideDesktop = hideDesktop
    }

    static func capture(rect: CGRect, content: SCShareableContent, hideDesktop: Bool = false) async throws -> CGImage? {
        let controller = ScrollingCaptureController(rect: rect, content: content, hideDesktop: hideDesktop)
        return try await controller.run()
    }

    private func run() async throws -> CGImage? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                showPanel()
                startAutomatic()
                sampleTask = Task { [weak self] in await self?.sample() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(.success(nil)) }
        }
    }

    private func showPanel() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 56), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.title = "Scrolling Capture"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        status.frame = CGRect(x: 16, y: 14, width: 200, height: 28)
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        doneButton.title = "Done"
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.frame = CGRect(x: 228, y: 14, width: 76, height: 28)
        doneButton.bezelStyle = .rounded
        for view in [status, doneButton] { panel.contentView?.addSubview(view) }
        panel.center()
        let cocoaRect = CaptureGeometry.cocoaRect(fromQuartz: rect, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaRect) }) {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20, y: screen.visibleFrame.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    // without Accessibility or a window under the area the person scrolls by hand
    private func startAutomatic() {
        guard AXIsProcessTrusted() else {
            status.stringValue = "Scroll slowly, or allow Accessibility to scroll for you."
            return
        }
        guard let target = windowAtCapturePoint() else {
            status.stringValue = "Scroll slowly within the area."
            return
        }
        autoTarget = target
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        status.stringValue = "Scrolling…"
    }

    private func windowAtCapturePoint() -> (pid: pid_t, window: CGWindowID)? {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let identifier = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            return (pid, identifier)
        }
        return nil
    }

    private func scrollAutomatically() {
        guard let target = autoTarget, !finishing, continuation != nil, !Task.isCancelled, !autoProgress.stopped else { return }
        guard AXIsProcessTrusted(), let current = windowAtCapturePoint(), current == target else {
            stopAutomatic("Scroll slowly within the area.")
            return
        }
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: -AutoScrollProgress.step(for: rect.height), wheel2: 0, wheel3: 0) else {
            stopAutomatic("Scroll slowly within the area.")
            return
        }
        event.location = CGPoint(x: rect.midX, y: rect.midY)
        event.flags = []
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.window))
        event.postToPid(target.pid)
        autoProgress.didScroll()
    }

    // hands scrolling back to the person, the capture keeps going
    private func stopAutomatic(_ message: String) {
        autoProgress.stop()
        autoTarget = nil
        status.stringValue = message
    }

    private func sample() async {
        while !finishing && !Task.isCancelled {
            do {
                if stitcher == nil {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let image = try await CaptureFrame.region(rect, content: content, showsCursor: false, hideDesktop: hideDesktop)
                guard !finishing, !Task.isCancelled else { break }
                if let current = stitcher {
                    let (updated, match) = try await Task.detached(priority: .userInitiated) {
                        var updated = current
                        let match = try updated.append(image)
                        return (updated, match)
                    }.value
                    guard !finishing, !Task.isCancelled else { break }
                    stitcher = updated
                    if autoTarget != nil, autoProgress.observe(match) {
                        // the page stopped moving, so the end was reached
                        if match == .unchanged { done(); break }
                        stopAutomatic("Scroll back slightly to continue.")
                        continue
                    }
                    switch match {
                    case .forward: if autoTarget == nil { status.stringValue = "Scroll slowly within the area." }
                    case .unchanged: break
                    case .backward: status.stringValue = "Scroll down to continue."
                    case .uncertain: status.stringValue = "Scroll back slightly to continue."
                    }
                } else {
                    stitcher = try await Task.detached(priority: .userInitiated) { try ScrollStitcher(image: image) }.value
                }
                scrollAutomatically()
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                break
            } catch {
                stopAutomatic(error.localizedDescription)
                break
            }
        }
    }

    // nothing captured yet means there is nothing to keep
    @objc private func done() {
        guard !finishing else { return }
        guard let stitcher else { complete(.success(nil)); return }
        finishing = true
        sampleTask?.cancel()
        autoProgress.stop()
        doneButton.isEnabled = false
        status.stringValue = "Saving…"
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try stitcher.render() }.value
                complete(.success(image))
            } catch {
                finishing = false
                doneButton.isEnabled = true
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func complete(_ result: Result<CGImage?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        autoProgress.stop()
        autoTarget = nil
        sampleTask?.cancel()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        continuation.resume(with: result)
    }
}
