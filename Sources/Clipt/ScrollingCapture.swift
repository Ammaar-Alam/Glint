import AppKit
import ScreenCaptureKit

enum ScrollAxis: Int, CaseIterable {
    case vertical, horizontal
}

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

    static func step(for viewport: CGSize, axis: ScrollAxis) -> Int32 {
        let length = axis == .vertical ? viewport.height : viewport.width
        guard length.isFinite, length > 0 else { return 1 }
        return Int32(max(1, min(120, length / 5)).rounded(.down))
    }
}

struct ScrollRaster {
    let values: [UInt8]
    let length: Int
    let breadth: Int

    init(image: CGImage, axis: ScrollAxis) throws {
        let width = axis == .vertical ? min(96, image.width) : image.width
        let height = axis == .vertical ? image.height : min(96, image.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw CliptError.message("The scrolling capture couldn’t be analyzed.")
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CliptError.message("The scrolling capture couldn’t be read.")
        }
        length = axis == .vertical ? height : width
        breadth = axis == .vertical ? width : height
        if axis == .vertical {
            values = Array(UnsafeBufferPointer(start: data, count: width * height))
        } else {
            var transposed = [UInt8](repeating: 0, count: width * height)
            for x in 0..<width {
                for y in 0..<height { transposed[x * height + y] = data[y * width + x] }
            }
            values = transposed
        }
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
    let axis: ScrollAxis
    let first: CGImage
    private var previous: ScrollRaster
    private var strips: [CGImage] = []
    private var tail: CGImage
    private let edgeInset: Int
    private(set) var length: Int
    private(set) var frameCount = 1
    private let maximumPixels = 48_000_000

    init(image: CGImage, axis: ScrollAxis) throws {
        self.axis = axis
        first = image
        previous = try ScrollRaster(image: image, axis: axis)
        length = axis == .vertical ? image.height : image.width
        edgeInset = max(1, min(160, length / 8))
        let tailRect = axis == .vertical
            ? CGRect(x: 0, y: image.height - edgeInset, width: image.width, height: edgeInset)
            : CGRect(x: image.width - edgeInset, y: 0, width: edgeInset, height: image.height)
        tail = try Self.copy(image, rect: tailRect)
    }

    mutating func append(_ image: CGImage) throws -> ScrollMatch {
        guard image.width == first.width, image.height == first.height else {
            throw CliptError.message("The screen resolution changed. Finish this capture and start another.")
        }
        let raster = try ScrollRaster(image: image, axis: axis)
        let match = previous.match(raster)
        guard case .forward(let distance) = match else { return match }
        let breadth = axis == .vertical ? first.width : first.height
        guard length + distance <= 32_768, (length + distance) * breadth <= maximumPixels else {
            throw CliptError.message("This capture reached its size limit. Finish to save it, then start another.")
        }
        let rect = axis == .vertical
            ? CGRect(x: 0, y: image.height - edgeInset - distance, width: image.width, height: distance)
            : CGRect(x: image.width - edgeInset - distance, y: 0, width: distance, height: image.height)
        let strip = try Self.copy(image, rect: rect)
        let tailRect = axis == .vertical
            ? CGRect(x: 0, y: image.height - edgeInset, width: image.width, height: edgeInset)
            : CGRect(x: image.width - edgeInset, y: 0, width: edgeInset, height: image.height)
        let latestTail = try Self.copy(image, rect: tailRect)
        strips.append(strip)
        tail = latestTail
        length += distance
        previous = raster
        frameCount += 1
        return match
    }

    func render() throws -> CGImage {
        let width = axis == .vertical ? first.width : length
        let height = axis == .vertical ? length : first.height
        guard let context = Self.context(width: width, height: height) else {
            throw CliptError.message("There isn’t enough memory to finish this scrolling capture.")
        }
        let leadingRect = axis == .vertical
            ? CGRect(x: 0, y: 0, width: first.width, height: first.height - edgeInset)
            : CGRect(x: 0, y: 0, width: first.width - edgeInset, height: first.height)
        guard let leading = first.cropping(to: leadingRect) else { throw CliptError.message("The first frame couldn’t be read.") }
        var offset = 0
        // Only the newest trailing edge is kept so fixed footers are not repeated
        for image in [leading] + strips + [tail] {
            let rect = axis == .vertical
                ? CGRect(x: 0, y: height - offset - image.height, width: image.width, height: image.height)
                : CGRect(x: offset, y: 0, width: image.width, height: image.height)
            context.draw(image, in: rect)
            offset += axis == .vertical ? image.height : image.width
        }
        guard let image = context.makeImage() else { throw CliptError.message("The capture couldn’t be rendered.") }
        return image
    }

    private static func copy(_ image: CGImage, rect: CGRect) throws -> CGImage {
        guard let cropped = image.cropping(to: rect), let context = context(width: cropped.width, height: cropped.height) else {
            throw CliptError.message("The next part of the capture couldn’t be added.")
        }
        // A copied strip does not retain the full viewport's backing storage
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let result = context.makeImage() else { throw CliptError.message("The capture couldn’t be combined.") }
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
    private var running = false
    private var finishing = false
    private var misses = 0
    private let status = NSTextField(wrappingLabelWithString: "Scroll slowly within the selected area.")
    private let direction = NSSegmentedControl(labels: ["Vertical", "Horizontal"], trackingMode: .selectOne, target: nil, action: nil)
    private let startButton = NSButton()
    private let finishButton = NSButton()
    private let autoButton = NSButton(checkboxWithTitle: "Auto", target: nil, action: nil)
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
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(.success(nil)) }
        }
    }

    private func showPanel() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 148), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.title = "Scrolling Capture"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        direction.selectedSegment = 0
        direction.frame = CGRect(x: 16, y: 108, width: 220, height: 24)
        autoButton.frame = CGRect(x: 256, y: 108, width: 88, height: 24)
        autoButton.target = self
        autoButton.action = #selector(toggleAutomatic)
        autoButton.setAccessibilityLabel("Automatic scrolling")
        status.frame = CGRect(x: 16, y: 52, width: 328, height: 44)
        status.font = .systemFont(ofSize: 12)
        startButton.title = "Start"
        startButton.target = self
        startButton.action = #selector(toggleCapture)
        startButton.frame = CGRect(x: 16, y: 14, width: 92, height: 28)
        startButton.bezelStyle = .rounded
        finishButton.title = "Finish"
        finishButton.target = self
        finishButton.action = #selector(finishCapture)
        finishButton.frame = CGRect(x: 124, y: 14, width: 100, height: 28)
        finishButton.bezelStyle = .rounded
        finishButton.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCapture))
        cancel.frame = CGRect(x: 240, y: 14, width: 104, height: 28)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        for view in [direction, autoButton, status, startButton, finishButton, cancel] { panel.contentView?.addSubview(view) }
        panel.center()
        let cocoaRect = CaptureGeometry.cocoaRect(fromQuartz: rect, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaRect) }) {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20, y: screen.visibleFrame.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    @objc private func toggleAutomatic() {
        autoProgress = AutoScrollProgress()
        autoTarget = nil
        guard autoButton.state == .on else { return }
        guard AXIsProcessTrusted() else {
            autoButton.state = .off
            status.stringValue = "Auto requires Accessibility access in System Settings. Manual capture is still available."
            return
        }
        guard let target = windowAtCapturePoint(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            autoButton.state = .off
            status.stringValue = "Activate the window inside your capture, then enable Auto."
            return
        }
        autoTarget = target
        status.stringValue = running ? "Automatic scrolling" : "Ready for automatic scrolling."
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

    private func scrollAutomatically(axis: ScrollAxis) {
        guard autoButton.state == .on, running, !finishing, continuation != nil, !Task.isCancelled, !autoProgress.stopped else { return }
        guard AXIsProcessTrusted(), let target = autoTarget,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let current = windowAtCapturePoint(), current.pid == target.pid, current.window == target.window else {
            pauseAutomatic("Automatic scrolling paused because the selected window changed.")
            return
        }
        let step = AutoScrollProgress.step(for: rect.size, axis: axis)
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: axis == .vertical ? -step : 0, wheel2: axis == .horizontal ? -step : 0, wheel3: 0) else {
            pauseAutomatic("Automatic scrolling isn’t available. You can continue manually.")
            return
        }
        event.location = CGPoint(x: rect.midX, y: rect.midY)
        event.flags = []
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.window))
        event.postToPid(target.pid)
        autoProgress.didScroll()
    }

    private func pauseAutomatic(_ message: String) {
        autoProgress.stop()
        autoButton.state = .off
        autoTarget = nil
        running = false
        startButton.title = "Resume"
        status.stringValue = message
    }

    @objc private func toggleCapture() {
        guard !finishing else { return }
        if running {
            running = false
            sampleTask?.cancel()
            startButton.title = "Resume"
            status.stringValue = "Paused"
            return
        }
        running = true
        autoProgress = AutoScrollProgress()
        direction.isEnabled = false
        startButton.title = "Pause"
        status.stringValue = autoButton.state == .on ? "Automatic scrolling" : "Scroll slowly within the selected area."
        misses = 0
        sampleTask = Task { [weak self] in await self?.sample() }
    }

    private func sample() async {
        while running && !finishing && !Task.isCancelled {
            do {
                if stitcher == nil {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let image = try await CaptureFrame.region(rect, content: content, showsCursor: false, hideDesktop: hideDesktop)
                guard running, !finishing, !Task.isCancelled else { break }
                let axis = ScrollAxis(rawValue: direction.selectedSegment) ?? .vertical
                if let current = stitcher {
                    let (updated, match) = try await Task.detached(priority: .userInitiated) {
                        var updated = current
                        let match = try updated.append(image)
                        return (updated, match)
                    }.value
                    guard running, !finishing, !Task.isCancelled else { break }
                    stitcher = updated
                    if autoButton.state == .on, autoProgress.observe(match) {
                        pauseAutomatic(match == .unchanged ? "End of scrolling reached. Finish to save your capture." : "Alignment lost. Scroll back slightly, then resume or finish.")
                        break
                    }
                    switch match {
                    case .forward:
                        misses = 0
                        status.stringValue = "\(updated.frameCount) frames · \(updated.length) px"
                    case .unchanged: break
                    case .backward:
                        status.stringValue = "Scroll forward to continue."
                    case .uncertain:
                        misses += 1
                        status.stringValue = "Couldn’t align this view. Scroll back slightly or finish the current capture."
                        if misses >= 12 {
                            running = false
                            startButton.title = "Resume"
                        }
                    }
                } else {
                    stitcher = try await Task.detached(priority: .userInitiated) { try ScrollStitcher(image: image, axis: axis) }.value
                    finishButton.isEnabled = true
                }
                scrollAutomatically(axis: axis)
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                break
            } catch {
                running = false
                startButton.title = "Resume"
                status.stringValue = error.localizedDescription
                if stitcher == nil { direction.isEnabled = true }
            }
        }
    }

    @objc private func finishCapture() {
        guard let stitcher, !finishing else { return }
        finishing = true
        running = false
        sampleTask?.cancel()
        autoProgress.stop()
        autoButton.isEnabled = false
        startButton.isEnabled = false
        finishButton.isEnabled = false
        status.stringValue = "Saving…"
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try stitcher.render() }.value
                complete(.success(image))
            } catch {
                finishing = false
                startButton.isEnabled = true
                autoButton.isEnabled = true
                finishButton.isEnabled = true
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func cancelCapture() { complete(.success(nil)) }

    private func complete(_ result: Result<CGImage?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        running = false
        autoProgress.stop()
        autoTarget = nil
        sampleTask?.cancel()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        continuation.resume(with: result)
    }
}
