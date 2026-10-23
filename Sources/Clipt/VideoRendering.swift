import AppKit
import AVFoundation
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum VideoGeometry {
    static func lastIndex<T>(in values: [T], at time: Double, timestamp: (T) -> Double) -> Int? {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if timestamp(values[middle]) <= time { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    static func outputSize(for project: VideoProject) -> CGSize {
        if let width = project.edits.customWidth, let height = project.edits.customHeight {
            return CGSize(width: max(64, width / 2 * 2), height: max(64, height / 2 * 2))
        }
        let ratio = project.edits.aspect.ratio ?? Double(project.width) / Double(project.height)
        let maximum = Double(project.edits.maximumDimension)
        let width = ratio >= 1 ? maximum : maximum * ratio
        let height = ratio >= 1 ? maximum / ratio : maximum
        return CGSize(width: max(2, floor(width / 2) * 2), height: max(2, floor(height / 2) * 2))
    }

    static func contentRect(for project: VideoProject, size: CGSize) -> CGRect {
        let padding = project.edits.showsBackground ? min(min(size.width, size.height) * 0.4, max(0, min(300, project.edits.padding)) * max(size.width, size.height) / 1920) : 0
        let available = CGRect(origin: .zero, size: size).insetBy(dx: padding, dy: padding)
        let scale = min(available.width / Double(project.width), available.height / Double(project.height))
        let width = Double(project.width) * scale, height = Double(project.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func cursor(at time: Double, samples: [VideoCursorSample], smoothing: Double = 0) -> VideoCursorSample? {
        guard !samples.isEmpty else { return nil }
        func sample(_ time: Double) -> VideoCursorSample {
            let index = lastIndex(in: samples, at: time, timestamp: \.time) ?? 0
            let left = samples[index]
            guard index + 1 < samples.count, left.visible, samples[index + 1].visible else { return left }
            let right = samples[index + 1]
            let span = right.time - left.time
            guard span > 0, span < 1 else { return left }
            let fraction = min(1, max(0, (time - left.time) / span))
            return .init(time: time, position: .init(x: left.position.x + (right.position.x - left.position.x) * fraction,
                                                     y: left.position.y + (right.position.y - left.position.y) * fraction), visible: left.visible)
        }
        let current = sample(time)
        guard current.visible, smoothing > 0 else { return current }
        let interval = min(1, smoothing) * 0.12
        let neighbors = [-1.0, -0.5, 0, 0.5, 1].map { sample(time + interval * $0) }.filter(\.visible)
        return .init(time: time, position: .init(x: neighbors.map(\.position.x).reduce(0, +) / Double(neighbors.count),
                                                y: neighbors.map(\.position.y).reduce(0, +) / Double(neighbors.count)))
    }

    static func zoom(at time: Double, project: VideoProject) -> (scale: Double, center: VideoPoint) {
        guard let zoom = project.edits.zooms.last(where: { time >= $0.start && time <= $0.start + $0.duration }) else { return (1, .center) }
        let ramp = min(0.45, zoom.duration / 2)
        let progress = min(1, (time - zoom.start) / ramp, (zoom.start + zoom.duration - time) / ramp)
        let eased = max(0, progress) * max(0, progress) * (3 - 2 * max(0, progress))
        let scale = 1 + (zoom.scale - 1) * eased
        let target = zoom.followsCursor ? cursor(at: time, samples: project.cursorSamples, smoothing: max(0.5, project.edits.cursorSmoothing))?.position ?? zoom.center : zoom.center
        let center = VideoPoint(x: 0.5 + (target.x - 0.5) * eased, y: 0.5 + (target.y - 0.5) * eased)
        let half = 0.5 / scale
        return (scale, .init(x: min(1 - half, max(half, center.x)), y: min(1 - half, max(half, center.y))))
    }

    static func cameraRect(project: VideoProject, size: CGSize, zoomScale: Double = 1) -> CGRect {
        if project.edits.cameraFullScreen { return CGRect(origin: .zero, size: size) }
        let zoomFactor = project.edits.cameraSmallerDuringZoom ? 1 - 0.22 * min(1, max(0, zoomScale - 1)) : 1
        let inset = min(max(size.width, size.height) * 0.025, min(size.width, size.height) * 0.1)
        let width = min(min(size.width, size.height) - 2 * inset, max(size.width, size.height) * min(0.5, max(0.08, project.edits.cameraSize)) * zoomFactor)
        let right = project.edits.cameraPosition == .bottomRight || project.edits.cameraPosition == .topRight
        let top = project.edits.cameraPosition == .topRight || project.edits.cameraPosition == .topLeft
        return CGRect(x: right ? size.width - width - inset : inset,
                      y: top ? size.height - width - inset : inset, width: width, height: width)
    }

    static func pressScale(at time: Double, clicks: [VideoClick]) -> Double {
        guard let index = lastIndex(in: clicks, at: time, timestamp: \.time) else { return 1 }
        let click = clicks[index]
        let release = click.releaseTime ?? click.time + 0.16
        let down = min(1, max(0, (time - click.time) / 0.06))
        let up = min(1, max(0, (time - release) / 0.1))
        return 1 - 0.18 * down * (1 - up)
    }
}

struct VideoActivity {
    let mouse: [Double]
    let typing: [Double]

    init(project: VideoProject) {
        var movements: [Double] = []
        var previous: VideoCursorSample?
        for sample in project.cursorSamples {
            if let previous {
                if abs(previous.position.x - sample.position.x) * Double(project.width) > 1 ||
                    abs(previous.position.y - sample.position.y) * Double(project.height) > 1 || previous.visible != sample.visible {
                    movements.append(sample.time)
                }
            } else { movements.append(sample.time) }
            previous = sample
        }
        mouse = (movements + project.clicks.map(\.time)).sorted()
        typing = project.keystrokes.filter { !$0.isShortcut }.map(\.time)
    }

    func cursorOpacity(at time: Double, edits: VideoEdits) -> Double {
        let lastMouse = VideoGeometry.lastIndex(in: mouse, at: time, timestamp: { $0 }).map { mouse[$0] } ?? 0
        var opacity = edits.cursorHideWhenStationary ? min(1, max(0, (1.8 - (time - lastMouse)) / 0.3)) : 1
        if edits.cursorHideWhileTyping, let key = VideoGeometry.lastIndex(in: typing, at: time, timestamp: { $0 }).map({ typing[$0] }), key > lastMouse {
            opacity = min(opacity, min(1, max(0, (time - key - 1) / 0.2)))
        }
        return opacity
    }
}

final class VideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let screenTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform
    let backgroundImage: CIImage?
    let activity: VideoActivity
    let project: VideoProject

    init(project: VideoProject, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, screenTransform: CGAffineTransform, cameraTransform: CGAffineTransform, backgroundImage: CIImage?) {
        self.project = project
        self.screenTrackID = screenTrackID; self.cameraTrackID = cameraTrackID
        self.screenTransform = screenTransform; self.cameraTransform = cameraTransform
        self.backgroundImage = backgroundImage
        activity = VideoActivity(project: project)
        timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: project.editedDuration, preferredTimescale: 600))
        requiredSourceTrackIDs = [screenTrackID, cameraTrackID].compactMap { $0 }.map { NSNumber(value: $0) }
    }
}

final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true] }
    private let queue = DispatchQueue(label: "app.clipt.video-compositor", qos: .userInitiated)
    private let renderer = VideoFrameRenderer()
    private let cancellationLock = NSLock()
    private var generation = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let currentGeneration = cancellationLock.withLock { generation }
        queue.async {
            autoreleasepool {
                guard self.cancellationLock.withLock({ self.generation == currentGeneration }) else {
                    request.finishCancelledRequest()
                    return
                }
                guard let instruction = request.videoCompositionInstruction as? VideoInstruction,
                      let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: CliptError.message("A video frame couldn’t be read."))
                    return
                }
                let screen = CIImage(cvPixelBuffer: screenBuffer).transformed(by: instruction.screenTransform)
                let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0).transformed(by: instruction.cameraTransform) }
                let time = instruction.project.sourceTime(at: request.compositionTime.seconds)
                let image = self.renderer.render(screen: screen, camera: camera, project: instruction.project, sourceTime: time, size: request.renderContext.size, backgroundImage: instruction.backgroundImage, activity: instruction.activity)
                self.renderer.context.render(image, to: output, bounds: CGRect(origin: .zero, size: request.renderContext.size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.withLock { generation += 1 }
        queue.sync {}
    }
}

final class VideoFrameRenderer {
    let context = CIContext(options: [.cacheIntermediates: false])
    private var cursorCache: [String: CIImage] = [:]
    private var textCache: [String: CIImage] = [:]

    func render(screen: CIImage, camera: CIImage?, project: VideoProject, sourceTime: Double, size: CGSize, backgroundImage: CIImage? = nil, activity: VideoActivity? = nil) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let edits = project.edits
        let screenVisible = !(edits.showsCamera && edits.cameraFullScreen)
        let unit = max(size.width, size.height) / 1920
        var result = background(edits, bounds: bounds, image: backgroundImage)
        let rect = VideoGeometry.contentRect(for: project, size: size)
        let zoom = VideoGeometry.zoom(at: sourceTime, project: project)
        let normalized = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let crop = CGRect(x: (zoom.center.x - 0.5 / zoom.scale) * normalized.extent.width,
                          y: (1 - zoom.center.y - 0.5 / zoom.scale) * normalized.extent.height,
                          width: normalized.extent.width / zoom.scale, height: normalized.extent.height / zoom.scale)
        var content = fit(normalized.cropped(to: crop), into: rect, fill: true)
        if edits.motionBlur > 0 {
            let previous = VideoGeometry.zoom(at: sourceTime - 1 / Double(project.frameRate), project: project)
            let dx = (zoom.center.x - previous.center.x) * rect.width
            let dy = (zoom.center.y - previous.center.y) * rect.height
            let movement = hypot(dx, dy) + abs(zoom.scale - previous.scale) * rect.width * 0.25
            let radius = min(24 * unit, movement * max(0, min(1, edits.motionBlur)))
            if radius > 0.25 { content = content.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(-dy, dx)]).cropped(to: rect) }
        }
        let radius = edits.showsBackground ? max(0, min(100, edits.cornerRadius)) * unit : 0
        if screenVisible { result = composite(content, in: rect, radius: radius, shadow: edits.showsBackground ? max(0, min(80, edits.shadow)) * unit : 0, onto: result) }

        func position(_ point: VideoPoint) -> CGPoint {
            CGPoint(x: rect.midX + (point.x - zoom.center.x) * rect.width * zoom.scale,
                    y: rect.midY - (point.y - zoom.center.y) * rect.height * zoom.scale)
        }
        if screenVisible && edits.showsClicks {
            for click in project.clicks where sourceTime >= click.time && sourceTime < click.time + 0.55 {
                let progress = (sourceTime - click.time) / 0.55
                let center = position(click.position)
                guard rect.contains(center) else { continue }
                let r = (edits.clickAnimated ? 12 + progress * 22 : 22) * unit * min(3, max(0.25, edits.clickSize))
                let opacity = edits.clickAnimated ? 1 - progress : min(1, (1 - progress) * 3)
                let image = ring(radius: r, color: edits.clickColor, opacity: opacity, lineWidth: 3 * unit, filled: edits.clickFilled)
                result = image.transformed(by: CGAffineTransform(translationX: center.x - image.extent.width / 2, y: center.y - image.extent.height / 2)).cropped(to: rect).composited(over: result)
            }
        }
        if screenVisible && edits.showsCursor, let sample = VideoGeometry.cursor(at: sourceTime, samples: project.cursorSamples, smoothing: edits.cursorMovement == .smooth ? edits.cursorSmoothing : 0), sample.visible {
            let point = position(sample.position)
            if rect.contains(point) {
                let press = edits.cursorPressEffect ? VideoGeometry.pressScale(at: sourceTime, clicks: project.clicks) : 1
                let scale = max(0.5, min(4, edits.cursorScale)) * unit * min(zoom.scale, 2) * press
                let opacity = (activity ?? VideoActivity(project: project)).cursorOpacity(at: sourceTime, edits: edits)
                let cursor = cursorImage(style: edits.cursorStyle, scale: scale).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
                let offset = edits.cursorStyle == .arrow ? CGPoint(x: 4 * scale, y: cursor.extent.height - 4 * scale) : CGPoint(x: cursor.extent.width / 2, y: cursor.extent.height / 2)
                result = cursor.transformed(by: CGAffineTransform(translationX: point.x - offset.x, y: point.y - offset.y)).cropped(to: rect).composited(over: result)
            }
        }
        if edits.showsCamera, let camera {
            let cameraRect = VideoGeometry.cameraRect(project: project, size: size, zoomScale: zoom.scale)
            var camera = camera
            if edits.cameraMirrored { camera = camera.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
            let cameraRadius: CGFloat
            switch edits.cameraShape {
            case .circle: cameraRadius = cameraRect.width / 2
            case .rounded: cameraRadius = cameraRect.width * 0.12
            case .square: cameraRadius = 0
            }
            result = composite(fit(camera, into: cameraRect, fill: true), in: cameraRect, radius: edits.cameraFullScreen ? 0 : cameraRadius, shadow: edits.cameraFullScreen ? 0 : 12 * unit, onto: result)
        }
        if edits.showsKeystrokes, let last = project.keystrokes.last(where: { $0.time <= sourceTime && sourceTime - $0.time < 2 && (!edits.keystrokesOnlyShortcuts || $0.isShortcut) }) {
            let opacity = min(1, (2 - (sourceTime - last.time)) / 0.25)
            var label = textImage(last.text, scale: max(0.5, min(2, edits.keystrokeScale)) * unit, style: edits.keystrokeStyle)
            let fit = min(1, size.width * 0.9 / label.extent.width)
            label = label.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            let inset = size.width * 0.04
            let x: Double
            switch edits.keystrokePosition {
            case .bottomLeft, .topLeft: x = inset
            case .bottom, .top: x = (size.width - label.extent.width) / 2
            case .bottomRight, .topRight: x = size.width - label.extent.width - inset
            }
            let top = [.topLeft, .top, .topRight].contains(edits.keystrokePosition)
            let y = top ? size.height * 0.945 - label.extent.height : size.height * 0.055
            let visible = label.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            result = visible.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: result)
        }
        return result.cropped(to: bounds)
    }

    private func background(_ edits: VideoEdits, bounds: CGRect, image: CIImage?) -> CIImage {
        guard edits.showsBackground else { return CIImage(color: .black).cropped(to: bounds) }
        let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: bounds.minX, y: bounds.maxY),
                                                              "inputPoint1": CIVector(x: bounds.maxX, y: bounds.minY),
                                                              "inputColor0": CIColor(color: edits.backgroundTop.nsColor)!,
                                                              "inputColor1": CIColor(color: edits.backgroundBottom.nsColor)!])!.outputImage!.cropped(to: bounds)
        return image.map { fit($0, into: bounds, fill: true).composited(over: gradient) } ?? gradient
    }

    private func fit(_ image: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
        let scale = fill ? max(rect.width / image.extent.width, rect.height / image.extent.height) : min(rect.width / image.extent.width, rect.height / image.extent.height)
        let transform = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return image.transformed(by: transform).cropped(to: rect)
    }

    private func composite(_ image: CIImage, in rect: CGRect, radius: Double, shadow: Double, onto background: CIImage) -> CIImage {
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": CIColor.white])!.outputImage!
        let clear = CIImage(color: .clear).cropped(to: background.extent)
        let content = image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        var result = background
        if shadow > 0 {
            let shadowImage = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                               "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                               "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                               "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.4)])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shadow])
                .transformed(by: CGAffineTransform(translationX: 0, y: -shadow * 0.35))
            result = shadowImage.composited(over: result)
        }
        return content.composited(over: result)
    }

    private func cursorImage(style: VideoCursorStyle, scale: Double) -> CIImage {
        let key = "\(style.rawValue)-\(Int(scale * 100))"
        if let cached = cursorCache[key] { return cached }
        let size = CGSize(width: ceil(38 * scale), height: ceil(44 * scale))
        let image = bitmap(size: size) { context in
            context.translateBy(x: 0, y: size.height); context.scaleBy(x: scale, y: -scale)
            context.setFillColor(CGColor(gray: 0.08, alpha: 1)); context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(1.8)
            if style == .circle {
                context.addEllipse(in: CGRect(x: 8, y: 11, width: 20, height: 20))
            } else {
                context.move(to: CGPoint(x: 4, y: 4)); context.addLine(to: CGPoint(x: 4, y: 31))
                context.addLine(to: CGPoint(x: 11, y: 24)); context.addLine(to: CGPoint(x: 17, y: 38))
                context.addLine(to: CGPoint(x: 23, y: 35)); context.addLine(to: CGPoint(x: 17, y: 22))
                context.addLine(to: CGPoint(x: 28, y: 22)); context.closePath()
            }
            context.drawPath(using: .fillStroke)
        }
        if cursorCache.count > 100 { cursorCache.removeAll(keepingCapacity: true) }
        cursorCache[key] = image
        return image
    }

    private func ring(radius: Double, color: VideoColor, opacity: Double, lineWidth: Double, filled: Bool) -> CIImage {
        let side = ceil((radius + lineWidth) * 2)
        return bitmap(size: CGSize(width: side, height: side)) { context in
            let rect = CGRect(x: side / 2 - radius, y: side / 2 - radius, width: radius * 2, height: radius * 2)
            if filled {
                context.setFillColor(color.nsColor.withAlphaComponent(opacity * 0.4).cgColor)
                context.fillEllipse(in: rect)
            } else {
                context.setStrokeColor(color.nsColor.withAlphaComponent(opacity).cgColor)
                context.setLineWidth(lineWidth)
                context.strokeEllipse(in: rect)
            }
        }
    }

    private func textImage(_ text: String, scale: Double, style: VideoKeyStyle) -> CIImage {
        let key = "\(text)-\(Int(scale * 100))-\(style.rawValue)"
        if let image = textCache[key] { return image }
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 24 * scale, nil)
        let attributed = NSAttributedString(string: String(text.prefix(80)), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: style == .light ? 0.07 : 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let size = CGSize(width: ceil(lineBounds.width + 34 * scale), height: ceil(52 * scale))
        let image = bitmap(size: size) { context in
            if style != .plain {
                context.setFillColor(CGColor(gray: style == .light ? 0.96 : 0.07, alpha: 0.9))
                context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
                context.fillPath()
            } else { context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.8)) }
            context.textPosition = CGPoint(x: 17 * scale - lineBounds.minX, y: (size.height - lineBounds.height) / 2 - lineBounds.minY)
            CTLineDraw(line, context)
        }
        if textCache.count > 60 { textCache.removeAll(keepingCapacity: true) }
        textCache[key] = image
        return image
    }

    private func bitmap(size: CGSize, draw: (CGContext) -> Void) -> CIImage {
        guard let context = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        draw(context)
        return context.makeImage().map(CIImage.init(cgImage:)) ?? CIImage.empty()
    }
}

struct VideoCompositionResult {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let duration: Double
}

enum VideoCompositionBuilder {
    static func thumbnail(project: VideoProject, directory: URL, time: Double = 0, backgroundDirectory: URL? = nil) async throws -> CGImage {
        let composition = try await make(project: project, directory: directory, backgroundDirectory: backgroundDirectory)
        let generator = AVAssetImageGenerator(asset: composition.asset)
        generator.videoComposition = composition.videoComposition
        generator.maximumSize = CGSize(width: 640, height: 480)
        return try await generator.image(at: CMTime(seconds: max(0, min(time, composition.duration - 0.001)), preferredTimescale: 600)).image
    }

    static func backgroundURL(_ filename: String, directory: URL, backgroundDirectory: URL?) -> URL {
        if let backgroundDirectory {
            let url = backgroundDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return directory.appendingPathComponent(filename)
    }

    static func make(project: VideoProject, directory: URL, includeEffects: Bool = true, backgroundDirectory: URL? = nil) async throws -> VideoCompositionResult {
        _ = try project.validated()
        let screen = AVURLAsset(url: directory.appendingPathComponent(project.screenFile))
        guard let sourceVideo = try await screen.loadTracks(withMediaType: .video).first else { throw CliptError.message("The recording has no video track.") }
        let sourceTransform = try await sourceVideo.load(.preferredTransform)
        let sourceDuration = try await screen.load(.duration).seconds
        guard project.edits.trimEnd <= sourceDuration + 0.1 else { throw CliptError.message("The video is shorter than the saved edit.") }
        let asset = AVMutableComposition()
        guard let video = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CliptError.message("The video timeline couldn’t be created.") }
        if !includeEffects { video.preferredTransform = sourceTransform }
        let segments = project.segments
        var outputTime = CMTime.zero
        for segment in segments {
            try Task.checkCancellation()
            let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600), duration: CMTime(seconds: segment.duration, preferredTimescale: 600))
            try video.insertTimeRange(range, of: sourceVideo, at: outputTime)
            outputTime = outputTime + range.duration
        }
        let audioMix = AVMutableAudioMix()
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudio in project.edits.audioEnabled ? try await screen.loadTracks(withMediaType: .audio) : [] {
            guard let track = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let sourceRange = try await sourceAudio.load(.timeRange)
            outputTime = .zero
            for segment in segments {
                let wanted = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600), duration: CMTime(seconds: segment.duration, preferredTimescale: 600))
                let range = CMTimeRangeGetIntersection(wanted, otherRange: sourceRange)
                if range.duration.seconds > 0 { try track.insertTimeRange(range, of: sourceAudio, at: outputTime + (range.start - wanted.start)) }
                outputTime = outputTime + wanted.duration
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let volume = sourceAudio.trackID == project.microphoneAudioTrackID ? project.edits.microphoneVolume : project.edits.systemVolume
            parameters.setVolume(Float(max(0, min(2, volume))), at: .zero)
            audioParameters.append(parameters)
        }
        audioMix.inputParameters = audioParameters
        var cameraTrackID: CMPersistentTrackID?
        var cameraTransform = CGAffineTransform.identity
        if includeEffects, let file = project.cameraFile {
            let cameraAsset = AVURLAsset(url: directory.appendingPathComponent(file))
            if let sourceCamera = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let camera = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let cameraRange = try await sourceCamera.load(.timeRange)
                cameraTransform = try await sourceCamera.load(.preferredTransform)
                outputTime = .zero
                for segment in segments {
                    let wanted = CMTimeRange(start: CMTime(seconds: segment.start - project.cameraStartTime, preferredTimescale: 600), duration: CMTime(seconds: segment.duration, preferredTimescale: 600))
                    let range = CMTimeRangeGetIntersection(wanted, otherRange: cameraRange)
                    if range.duration.seconds > 0 { try camera.insertTimeRange(range, of: sourceCamera, at: outputTime + (range.start - wanted.start)) }
                    outputTime = outputTime + wanted.duration
                }
                cameraTrackID = camera.trackID
            }
        }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = VideoCompositor.self
        composition.renderSize = VideoGeometry.outputSize(for: project)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(60, project.frameRate)))
        let background = try (includeEffects ? project.edits.backgroundFile : nil).map { filename -> CIImage in
            guard let source = CGImageSourceCreateWithURL(backgroundURL(filename, directory: directory, backgroundDirectory: backgroundDirectory) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                             kCGImageSourceThumbnailMaxPixelSize: project.edits.maximumDimension,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw CliptError.message("The background image couldn’t be read.")
            }
            return CIImage(cgImage: image)
        }
        composition.instructions = [VideoInstruction(project: project, screenTrackID: video.trackID, cameraTrackID: cameraTrackID, screenTransform: sourceTransform, cameraTransform: cameraTransform, backgroundImage: background)]
        return VideoCompositionResult(asset: asset, videoComposition: composition, audioMix: audioMix, duration: project.editedDuration)
    }

    static func importMovie(_ url: URL) async throws -> (VideoProject, URL) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CliptError.message("This file doesn’t contain a video.") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: size).applying(transform)
        let duration = try await asset.load(.duration).seconds
        let fps = try await track.load(.nominalFrameRate)
        guard transformed.width.isFinite, transformed.height.isFinite,
              abs(transformed.width) >= 1, abs(transformed.height) >= 1,
              abs(transformed.width) <= 32768, abs(transformed.height) <= 32768 else {
            throw CliptError.message("This video has unsupported frame dimensions.")
        }
        let frameRate = fps.isFinite && fps > 0 ? Int(min(60, max(1, fps.rounded()))) : 30
        var project = VideoProject(duration: duration, width: Int(abs(transformed.width)), height: Int(abs(transformed.height)), frameRate: frameRate)
        project.screenFile = "screen.\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        project.edits.showsCursor = false
        project.edits.showsClicks = false
        project.edits.showsKeystrokes = false
        project.edits.showsBackground = false
        _ = try project.validated()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipt-\(UUID().uuidString).cliptvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(project.screenFile))
            try project.save(to: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return (project, directory)
    }
}
