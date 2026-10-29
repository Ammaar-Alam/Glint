import AppKit
import ScreenCaptureKit
import SwiftUI

enum ScrollMatch: Equatable {
    case unchanged
    case forward(Int)
    case backward
    case uncertain
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
final class ScrollingCaptureController {
    private let rect: CGRect
    private var content: SCShareableContent
    private let hideDesktop: Bool
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<CGImage?, Error>?
    private var sampleTask: Task<Void, Never>?
    private var stitcher: ScrollStitcher?
    private var finishing = false
    private var dimmed = false

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
                sampleTask = Task { [weak self] in await self?.sample() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(.success(nil)) }
        }
    }

    private func showPanel() {
        let host = FirstMouseHostingView(rootView: DoneCard { [weak self] in self?.done() })
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.contentView = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let card = CGSize(width: 96, height: 44)
        let cocoaRect = CaptureGeometry.cocoaRect(fromQuartz: rect, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let screen = (NSScreen.screens.first { $0.frame.intersects(cocoaRect) } ?? NSScreen.screens[0]).visibleFrame
        // the bar shrinks into Done where it stood, without a bar Done sits where the bar would have
        let bar = SelectionController.lastBarFrame
        let from = bar ?? CGRect(origin: CaptureGeometry.attach(card, to: cocoaRect, within: screen), size: card)
        let to = CGRect(x: (from.midX - card.width / 2).rounded(), y: (from.midY - card.height / 2).rounded(), width: card.width, height: card.height)
        panel.setFrame(from.insetBy(dx: -20, dy: -20), display: true)
        panel.alphaValue = bar == nil ? 0 : 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(to.insetBy(dx: -20, dy: -20), display: true)
            panel.animator().alphaValue = 1
        }
    }

    // steps back while the page moves and returns once it settles
    private func dim(_ value: Bool) {
        guard let panel, value != dimmed else { return }
        dimmed = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = value ? 0.25 : 1
        }
        // scrolling over a faded button still reaches the page
        panel.ignoresMouseEvents = value
    }

    // samples about once a frame so fast scrolling still overlaps the previous view
    private func sample() async {
        var lastMove = ContinuousClock.now
        while !finishing && !Task.isCancelled {
            do {
                if stitcher == nil {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let image = try await CaptureFrame.region(rect, content: content, showsCursor: false, hideDesktop: hideDesktop)
                guard !finishing, !Task.isCancelled else { break }
                var moved = false
                if let current = stitcher {
                    let (updated, match) = try await Task.detached(priority: .userInitiated) {
                        var updated = current
                        let match = try updated.append(image)
                        return (updated, match)
                    }.value
                    guard !finishing, !Task.isCancelled else { break }
                    stitcher = updated
                    if case .forward = match { moved = true }
                } else {
                    stitcher = try await Task.detached(priority: .userInitiated) { try ScrollStitcher(image: image) }.value
                }
                if moved {
                    lastMove = .now
                    dim(true)
                } else if ContinuousClock.now - lastMove > .seconds(0.6) {
                    dim(false)
                }
                try await Task.sleep(for: .milliseconds(16))
            } catch is CancellationError {
                break
            } catch {
                // a size limit or a changed screen keeps what was already captured
                if stitcher == nil { complete(.failure(error)) } else { done() }
                break
            }
        }
    }

    private func done() {
        guard !finishing else { return }
        guard let stitcher else { complete(.success(nil)); return }
        finishing = true
        sampleTask?.cancel()
        Task {
            do { complete(.success(try await Task.detached(priority: .userInitiated) { try stitcher.render() }.value)) }
            catch { complete(.failure(error)) }
        }
    }

    private func complete(_ result: Result<CGImage?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        sampleTask?.cancel()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        continuation.resume(with: result)
    }
}

// the same white card as the capture bar so one can become the other
private struct DoneCard: View {
    let action: () -> Void
    @State private var shown = false

    var body: some View {
        Button("Done", action: action)
            .buttonStyle(PrimaryButtonStyle())
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
            .padding(20)
            .onAppear { withAnimation(.easeOut(duration: 0.2).delay(0.15)) { shown = true } }
    }
}
