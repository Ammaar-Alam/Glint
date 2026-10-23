import XCTest
import AppKit
import AVFoundation
import AVKit
import CoreImage
import ImageIO
import SwiftUI
@testable import Glint

final class VideoTests: XCTestCase {
    @MainActor
    func testVideoEditorCreatesNativePlaybackViewOffscreen() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("recording.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try await Self.movie(at: package.appendingPathComponent("screen.mov"))
        var project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        project.edits.maximumDimension = 320
        try project.save(to: package)
        let model = VideoEditorModel(url: package) { _ in }
        defer { model.shutdown() }
        model.load()
        let deadline = Date().addingTimeInterval(5)
        while model.project == nil && model.errorMessage == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(model.project)
        let host = NSHostingView(rootView: AnyView(VideoEditorView(model: model)))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        let native = try XCTUnwrap(Self.nativePlayer(in: host))
        XCTAssertTrue(native.player === model.player)
        XCTAssertEqual(native.controlsStyle, .none)
        XCTAssertEqual(native.videoGravity, .resizeAspect)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(native.player)
    }

    @MainActor
    func testNativePlaybackUpdatesTheSuppliedPlayer() async throws {
        let first = AVPlayer(), replacement = AVPlayer()
        let host = NSHostingView(rootView: VideoPlaybackView(player: first))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        host.layoutSubtreeIfNeeded()
        let native = try XCTUnwrap(Self.nativePlayer(in: host))
        XCTAssertTrue(native.player === first)
        host.rootView = VideoPlaybackView(player: replacement)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(native.player === replacement)
    }

    @MainActor
    private static func nativePlayer(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        return view.subviews.lazy.compactMap { nativePlayer(in: $0) }.first
    }

    func testTimelineScaleMapsTimeAndPicksReadableTicks() {
        let scale = VideoTimelineScale(duration: 10, width: 1032, inset: 16)
        XCTAssertEqual(scale.pointsPerSecond, 100)
        XCTAssertEqual(scale.x(0), 16)
        XCTAssertEqual(scale.x(2.5), 266)
        XCTAssertEqual(scale.x(20), 1016)
        XCTAssertEqual(scale.time(266), 2.5)
        XCTAssertEqual(scale.time(0), 0)
        XCTAssertEqual(scale.time(5000), 10)
        XCTAssertEqual(scale.tickStep, 1)
        XCTAssertEqual(VideoTimelineScale(duration: 600, width: 1032).tickStep, 60)
        XCTAssertEqual(VideoTimelineScale(duration: 10, width: 20).time(50), 0)
    }

    func testFrameStripDensityKeepsDecodedFrames() {
        XCTAssertEqual(VideoFrameStrip.density(for: 0), 8)
        XCTAssertEqual(VideoFrameStrip.density(for: 9), 16)
        XCTAssertEqual(VideoFrameStrip.density(for: 5000), 512)
        let coarse = VideoFrameStrip.times(duration: 6, density: 8)
        let fine = VideoFrameStrip.times(duration: 6, density: 16)
        XCTAssertEqual(coarse.first, 0)
        XCTAssertEqual(coarse.count, 8)
        XCTAssertTrue(coarse.allSatisfy { time in fine.contains { abs($0 - time) < 0.000_001 } })
        XCTAssertTrue(fine.allSatisfy { $0 < 6 })
        XCTAssertTrue(VideoFrameStrip.times(duration: 0, density: 8).isEmpty)
    }

    @MainActor
    func testEditorDecodesFrameStripOffTheMainThread() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("recording.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try await Self.movie(at: package.appendingPathComponent("screen.mov"))
        try VideoProject(duration: 1, width: 96, height: 64, frameRate: 10).save(to: package)
        let model = VideoEditorModel(url: package) { _ in }
        defer { model.shutdown() }
        model.load()
        var deadline = Date().addingTimeInterval(5)
        while model.project == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.loadFrames(tiles: 4)
        deadline = Date().addingTimeInterval(5)
        while model.frames.count < 8 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.frames.map(\.time), VideoFrameStrip.times(duration: 1, density: 8))
        XCTAssertTrue(model.frame(near: 0.49) === model.frames[4].image)
        model.loadFrames(tiles: 3)
        XCTAssertEqual(model.frames.count, 8)
    }

    @MainActor
    func testTimelineEditsCutsAndZoomsWithoutEmptyingTheVideo() async throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("recording.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try await Self.movie(at: package.appendingPathComponent("screen.mov"))
        try VideoProject(duration: 1, width: 96, height: 64, frameRate: 10).save(to: package)
        let model = VideoEditorModel(url: package) { _ in }
        defer { model.shutdown() }
        model.load()
        let deadline = Date().addingTimeInterval(5)
        while model.project == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.removeRange(start: 0.2, end: 0.4)
        let cut = try XCTUnwrap(model.project?.edits.cuts.first)
        model.updateCut(cut.id, start: 0.1, end: 0.5)
        XCTAssertEqual(model.project?.edits.cuts.first?.start, 0.1)
        XCTAssertEqual(model.project?.edits.cuts.first?.end, 0.5)
        model.updateCut(cut.id, start: 0, end: 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.project?.edits.cuts.first?.end, 0.5)
        model.addZoom(at: 0.6)
        let zoom = try XCTUnwrap(model.project?.edits.zooms.first)
        XCTAssertEqual(zoom.start, 0.5)
        XCTAssertEqual(model.selectedZoom, zoom.id)
        model.removeZoom(zoom.id)
        XCTAssertNil(model.selectedZoom)
        XCTAssertTrue(model.project?.edits.zooms.isEmpty ?? false)
    }

    func testOverlappingCutsMapEditedTimeToOriginalFrames() throws {
        var project = VideoProject(duration: 10, width: 1920, height: 1080)
        project.edits.trimStart = 1; project.edits.trimEnd = 9
        project.edits.cuts = [.init(start: 2, end: 4), .init(start: 3, end: 6), .init(start: 8, end: 10)]
        XCTAssertEqual(project.segments.map(\.start), [1, 6])
        XCTAssertEqual(project.segments.map(\.end), [2, 8])
        XCTAssertEqual(project.editedDuration, 3)
        XCTAssertEqual(project.sourceTime(at: 1), 6)
        XCTAssertEqual(project.sourceTime(at: 2.5), 7.5)
        XCTAssertEqual(project.outputTime(at: 4), 1)
        XCTAssertEqual(project.outputTime(at: 7), 2)
        _ = try project.validated()
    }

    func testCursorInterpolationAndZoomStayWithinSource() {
        var project = VideoProject(duration: 3, width: 100, height: 60)
        project.cursorSamples = [.init(time: 0, position: .init(x: 0, y: 0)), .init(time: 0.5, position: .init(x: 1, y: 1))]
        let cursor = VideoGeometry.cursor(at: 0.25, samples: project.cursorSamples)
        XCTAssertEqual(cursor?.position.x, 0.5)
        project.edits.zooms = [.init(start: 0, duration: 2, scale: 4, center: .init(x: 0, y: 1), followsCursor: false)]
        let zoom = VideoGeometry.zoom(at: 1, project: project)
        XCTAssertEqual(zoom.scale, 4)
        XCTAssertEqual(zoom.center.x, 0.125)
        XCTAssertEqual(zoom.center.y, 0.875)
        XCTAssertEqual(VideoGeometry.zoom(at: 0, project: project).scale, 1)
        XCTAssertEqual(VideoGeometry.zoom(at: 2, project: project).scale, 1)
    }

    func testIndependentCursorEffectsAndCameraShrink() {
        var project = VideoProject(duration: 4, width: 1920, height: 1080)
        project.cursorSamples = [.init(time: 0, position: .center), .init(time: 0.2, position: .center),
                                 .init(time: 0.4, position: .center), .init(time: 3, position: .init(x: 0.7, y: 0.6))]
        project.clicks = [.init(time: 0.8, position: .center, releaseTime: 1.2)]
        project.keystrokes = [.init(time: 1.2, text: "A", isShortcut: false), .init(time: 1.3, text: "⌘C")]
        project.edits.cursorHideWhenStationary = true
        project.edits.cursorHideWhileTyping = true
        let activity = VideoActivity(project: project)
        XCTAssertEqual(activity.cursorOpacity(at: 1.25, edits: project.edits), 0)
        XCTAssertEqual(activity.cursorOpacity(at: 2.8, edits: project.edits), 0)
        XCTAssertEqual(activity.cursorOpacity(at: 3.1, edits: project.edits), 1)
        XCTAssertEqual(VideoGeometry.pressScale(at: 0.9, clicks: project.clicks), 0.82, accuracy: 0.001)
        XCTAssertEqual(VideoGeometry.pressScale(at: 1.4, clicks: project.clicks), 1, accuracy: 0.001)
        project.edits.cameraSmallerDuringZoom = true
        let base = VideoGeometry.cameraRect(project: project, size: CGSize(width: 1920, height: 1080))
        let zoomed = VideoGeometry.cameraRect(project: project, size: CGSize(width: 1920, height: 1080), zoomScale: 2)
        XCTAssertEqual(zoomed.width, base.width * 0.78, accuracy: 0.001)
        project.edits.cameraFullScreen = true
        XCTAssertEqual(VideoGeometry.cameraRect(project: project, size: CGSize(width: 1920, height: 1080), zoomScale: 2).size, CGSize(width: 1920, height: 1080))
    }

    func testCustomDimensionsAndKeystrokeDisplayOptions() throws {
        var project = VideoProject(duration: 1, width: 100, height: 60)
        project.edits.customWidth = 641; project.edits.customHeight = 360
        XCTAssertEqual(VideoGeometry.outputSize(for: project), CGSize(width: 640, height: 360))
        project.edits.customHeight = nil
        XCTAssertThrowsError(try project.validated())
        project.edits.customWidth = nil; project.edits.maximumDimension = 320
        project.edits.showsBackground = false
        project.keystrokes = [.init(time: 0.1, text: "A", isShortcut: false)]
        let renderer = VideoFrameRenderer()
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 60))
        let size = VideoGeometry.outputSize(for: project)
        func bytes(_ image: CIImage) throws -> Data {
            let cgImage = try XCTUnwrap(renderer.context.createCGImage(image, from: image.extent))
            return try XCTUnwrap(cgImage.dataProvider?.data) as Data
        }
        let hidden = try bytes(renderer.render(screen: red, camera: nil, project: project, sourceTime: 0.5, size: size))
        project.edits.keystrokesOnlyShortcuts = false
        let all = try bytes(renderer.render(screen: red, camera: nil, project: project, sourceTime: 0.5, size: size))
        XCTAssertNotEqual(hidden, all)
        project.edits.keystrokePosition = .topLeft; project.edits.keystrokeStyle = .light
        let moved = try bytes(renderer.render(screen: red, camera: nil, project: project, sourceTime: 0.5, size: size))
        XCTAssertNotEqual(all, moved)
    }

    func testProjectRoundTripAndUntrustedPaths() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = VideoProject(duration: 2, width: 96, height: 64)
        project.cursorSamples = [.init(time: 0, position: .center)]
        project.edits.zooms = [.init(start: 0, duration: 1)]
        try project.save(to: directory)
        XCTAssertEqual(try VideoProject.load(from: directory), project)
        project.screenFile = "../outside.mov"
        XCTAssertThrowsError(try project.validated())
        project.screenFile = "screen.mov"
        project.edits.backgroundTop.red = .nan
        XCTAssertThrowsError(try project.validated())
        project.edits.backgroundTop.red = 0
        project.cursorSamples = [.init(time: 1, position: .center), .init(time: 0, position: .center)]
        XCTAssertThrowsError(try project.validated())
    }

    func testProjectLoadDoesNotDependOnDirectoryURLHint() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent("screen.mov"))
        let project = VideoProject(duration: 1, width: 64, height: 64)
        try project.save(to: directory)
        for hint in [true, false] {
            let url = URL(fileURLWithPath: directory.path, isDirectory: hint)
            XCTAssertEqual(try VideoProject.load(from: url), project, "directory hint: \(hint)")
        }
        let alias = root.appendingPathComponent("alias.glintvideo", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertEqual(try VideoProject.load(from: alias), project)
    }

    func testProjectLoadStillRejectsMediaSymlinkOutsidePackage() throws {
        let root = try Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.mov")
        try Data().write(to: outside)
        let directory = root.appendingPathComponent("capture.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("screen.mov"), withDestinationURL: outside)
        try VideoProject(duration: 1, width: 64, height: 64).save(to: directory)
        for hint in [true, false] {
            XCTAssertThrowsError(try VideoProject.load(from: URL(fileURLWithPath: directory.path, isDirectory: hint)))
        }
    }

    func testRendererActuallyAppliesBackgroundAndCamera() throws {
        let renderer = VideoFrameRenderer()
        var project = VideoProject(duration: 1, width: 100, height: 60)
        project.edits.maximumDimension = 320
        project.edits.backgroundTop = .init(red: 0, green: 0, blue: 1)
        project.edits.backgroundBottom = project.edits.backgroundTop
        project.edits.padding = 100; project.edits.cornerRadius = 0; project.edits.shadow = 0
        project.edits.showsCursor = false; project.edits.showsClicks = false
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 60))
        let size = VideoGeometry.outputSize(for: project)
        let frame = renderer.render(screen: red, camera: nil, project: project, sourceTime: 0.5, size: size)
        XCTAssertGreaterThan(Self.pixel(frame, at: CGPoint(x: 2, y: 2), context: renderer.context)[2], 240)
        XCTAssertGreaterThan(Self.pixel(frame, at: CGPoint(x: size.width / 2, y: size.height / 2), context: renderer.context)[0], 240)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
        let withCamera = renderer.render(screen: red, camera: green, project: project, sourceTime: 0.5, size: size)
        let cameraRect = VideoGeometry.cameraRect(project: project, size: size)
        XCTAssertGreaterThan(Self.pixel(withCamera, at: CGPoint(x: cameraRect.midX, y: cameraRect.midY), context: renderer.context)[1], 240)
        project.edits.cameraFullScreen = true
        let fullCamera = renderer.render(screen: red, camera: green, project: project, sourceTime: 0.5, size: size)
        XCTAssertGreaterThan(Self.pixel(fullCamera, at: CGPoint(x: 3, y: 3), context: renderer.context)[1], 240)
        let waitingForCamera = renderer.render(screen: red, camera: nil, project: project, sourceTime: 0.5, size: size)
        XCTAssertGreaterThan(Self.pixel(waitingForCamera, at: CGPoint(x: size.width / 2, y: size.height / 2), context: renderer.context)[2], 240)
        let custom = renderer.render(screen: red, camera: nil, project: project, sourceTime: 0.5, size: size, backgroundImage: green)
        XCTAssertGreaterThan(Self.pixel(custom, at: CGPoint(x: 3, y: 3), context: renderer.context)[1], 240)
    }

    func testMP4AndGIFExportEditedFramesAndDuration() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.movie(at: directory.appendingPathComponent("screen.mov"))
        try FileManager.default.copyItem(at: directory.appendingPathComponent("screen.mov"), to: directory.appendingPathComponent("camera.mov"))
        var project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        project.cameraFile = "camera.mov"; project.cameraStartTime = 0.25
        project.edits.maximumDimension = 320
        project.edits.trimStart = 0.2; project.edits.trimEnd = 0.9
        project.edits.cuts = [.init(start: 0.4, end: 0.5)]
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let backgroundImage = try XCTUnwrap(CIContext().createCGImage(background, from: background.extent))
        try ImageFile.write(backgroundImage, to: directory.appendingPathComponent("background.png"))
        project.backgroundFiles = ["background.png"]; project.edits.backgroundFile = "background.png"
        project.edits.showsBackground = true
        project.cursorSamples = [.init(time: 0, position: .center)]
        let mp4 = directory.appendingPathComponent("edited.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: mp4, format: .mp4) { _ in }
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, project.editedDuration, accuracy: 0.11)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        XCTAssertEqual(image.width, 320)
        XCTAssertGreaterThan(Self.pixel(CIImage(cgImage: image), at: CGPoint(x: 2, y: 2), context: CIContext())[2], 220)
        let gif = directory.appendingPathComponent("edited.gif")
        try await VideoExporter.export(project: project, directory: directory, destination: gif, format: .gif) { _ in }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 6)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testCanceledExportPreservesExistingFile() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.movie(at: directory.appendingPathComponent("screen.mov"))
        let existing = directory.appendingPathComponent("existing.mp4")
        let original = Data("previous export".utf8)
        try original.write(to: existing)
        let project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        let task = Task { try await VideoExporter.export(project: project, directory: directory, destination: existing, format: .mp4) { _ in } }
        task.cancel()
        do { try await task.value; XCTFail("The export should have been cancelled") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    func testUnsavedBackgroundExportsWithoutChangingOriginalProject() async throws {
        let directory = try Self.directory()
        let workspace = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: workspace) }
        try await Self.movie(at: directory.appendingPathComponent("screen.mov"))
        var project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        project.edits.maximumDimension = 320
        try project.save(to: directory)
        let original = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        let image = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let background = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        try ImageFile.write(background, to: workspace.appendingPathComponent("pending.png"))
        project.backgroundFiles = ["pending.png"]; project.edits.backgroundFile = "pending.png"
        let output = workspace.appendingPathComponent("export.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: output, format: .mp4, backgroundDirectory: workspace) { _ in }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("project.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending.png").path))
        let frame = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: .zero).image
        XCTAssertGreaterThan(Self.pixel(CIImage(cgImage: frame), at: CGPoint(x: 2, y: 2), context: CIContext())[2], 220)
    }

    @MainActor
    func testUndoingBackgroundDoesNotSaveItsAssetIntoTheOriginalProject() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("recording.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try await Self.movie(at: package.appendingPathComponent("screen.mov"))
        var project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        project.edits.maximumDimension = 320
        try project.save(to: package)
        let image = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let background = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let imageURL = directory.appendingPathComponent("background.png")
        try ImageFile.write(background, to: imageURL)
        let model = VideoEditorModel(url: package) { _ in }
        defer { model.shutdown() }
        model.load()
        let deadline = Date().addingTimeInterval(5)
        while model.project == nil && model.errorMessage == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(model.project)
        try await model.importBackground(from: imageURL)
        let filename = try XCTUnwrap(model.project?.edits.backgroundFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent(filename).path))
        model.undo()
        let saved = await model.saveProject()
        XCTAssertTrue(saved, model.errorMessage ?? "Save failed")
        XCTAssertNil(try VideoProject.load(from: package).edits.backgroundFile)
        XCTAssertTrue(try VideoProject.load(from: package).backgroundFiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent(filename).path))
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-video-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pixel(_ image: CIImage, at point: CGPoint, context: CIContext) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    static func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GlintError.message("The test video couldn’t start.") }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? GlintError.message("The test video stopped encoding.") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { throw GlintError.message("The test video buffer couldn’t be created.") }
            let image = CIImage(color: CIColor(red: 1, green: Double(frame) / 20, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
            context.render(image, to: pixelBuffer)
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error ?? GlintError.message("The test video frame couldn’t be written.") }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? GlintError.message("The test video couldn’t be finished.") }
    }
}
