import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
import ImageIO
@testable import Clipt

final class VideoExportTests: XCTestCase {
    func testGIFCentisecondDelaysPreserveDurationAt15FPS() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await VideoTests.movie(at: directory.appendingPathComponent("screen.mov"))
        var project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 30)
        project.edits.maximumDimension = 320
        let output = directory.appendingPathComponent("timing.gif")
        try await VideoExporter.export(project: project, directory: directory, destination: output, format: .gif, gifFrameRate: 15) { _ in }
        let delays = try Self.gifDelays(at: output)
        XCTAssertEqual(delays.count, 15)
        XCTAssertEqual(Set(delays.map { Int(($0 * 100).rounded()) }), [6, 7])
        XCTAssertEqual(delays.reduce(0, +), 1, accuracy: 0.01)

        project.frameRate = 60; project.edits.trimEnd = 0.99
        try await VideoExporter.export(project: project, directory: directory, destination: output, format: .gif, gifFrameRate: 50) { _ in }
        let tailDelays = try Self.gifDelays(at: output)
        XCTAssertEqual(tailDelays.count, 49)
        XCTAssertTrue(tailDelays.allSatisfy { $0 >= 0.02 })
        XCTAssertEqual(tailDelays.reduce(0, +), 0.99, accuracy: 0.01)
    }

    func testGIFValidationAndCancellationPreserveExistingFile() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await VideoTests.movie(at: directory.appendingPathComponent("screen.mov"))
        let output = directory.appendingPathComponent("existing.gif")
        let original = Data("previous GIF".utf8)
        try original.write(to: output)
        let project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 30)
        for rate in [0, 51] {
            do {
                try await VideoExporter.export(project: project, directory: directory, destination: output, format: .gif, gifFrameRate: rate) { _ in }
                XCTFail("An invalid GIF frame rate must be rejected")
            } catch is CliptError {}
        }
        let task = Task { try await VideoExporter.export(project: project, directory: directory, destination: output, format: .gif) { _ in } }
        task.cancel()
        do { try await task.value; XCTFail("The GIF export should have been cancelled") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    private static func gifDelays(at url: URL) throws -> [Double] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try (0..<CGImageSourceGetCount(source)).map { index in
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            return try XCTUnwrap((gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? Double)
        }
    }

    func testExportCannotOverwriteProjectOriginal() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("screen.mov")
        try await VideoTests.movie(at: original)
        let bytes = try Data(contentsOf: original)
        let project = VideoProject(duration: 1, width: 96, height: 64, frameRate: 10)
        do {
            try await VideoExporter.export(project: project, directory: directory, destination: original, format: .original) { _ in }
            XCTFail("An export must preserve its editable source")
        } catch is CliptError {}
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testQualityChangesEncodedBitrateAndFileSize() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.noisyMovie(at: directory.appendingPathComponent("screen.mov"))
        var project = VideoProject(duration: 2, width: 640, height: 360, frameRate: 15)
        project.edits.maximumDimension = 640; project.edits.showsBackground = false
        project.edits.showsCursor = false; project.edits.audioEnabled = false
        project.edits.exportQuality = 0
        let lowRate = VideoExporter.videoBitRate(project: project)
        let lowEstimate = VideoExporter.estimatedSize(project: project)
        let low = directory.appendingPathComponent("low.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: low, format: .mp4) { _ in }
        project.edits.exportQuality = 1
        XCTAssertGreaterThan(VideoExporter.videoBitRate(project: project), lowRate * 4)
        XCTAssertGreaterThan(VideoExporter.estimatedSize(project: project), lowEstimate * 4)
        let high = directory.appendingPathComponent("high.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: high, format: .mp4) { _ in }
        let lowSize = try Data(contentsOf: low).count
        let highSize = try Data(contentsOf: high).count
        XCTAssertGreaterThan(highSize, lowSize)
    }

    func testTrimOnlyRetainsOriginalDimensionsAndTransform() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await VideoTests.movie(at: directory.appendingPathComponent("screen.mov"))
        let sourceAsset = AVURLAsset(url: directory.appendingPathComponent("screen.mov"))
        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let rotated = AVMutableComposition()
        let rotatedTrack = try XCTUnwrap(rotated.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try rotatedTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: XCTUnwrap(sourceVideoTracks.first), at: .zero)
        rotatedTrack.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
        let rotationExport = try XCTUnwrap(AVAssetExportSession(asset: rotated, presetName: AVAssetExportPresetPassthrough))
        try await rotationExport.export(to: directory.appendingPathComponent("rotated.mov"), as: .mov)
        var project = VideoProject(duration: 1, width: 64, height: 96, frameRate: 10)
        project.screenFile = "rotated.mov"
        project.edits.customWidth = 480; project.edits.customHeight = 270
        project.edits.trimStart = 0.2; project.edits.trimEnd = 0.8
        project.edits.cuts = [.init(start: 0.4, end: 0.5)]
        let original = directory.appendingPathComponent("trim.mov")
        try await VideoExporter.export(project: project, directory: directory, destination: original, format: .original) { _ in }
        let source = AVURLAsset(url: directory.appendingPathComponent(project.screenFile))
        let asset = AVURLAsset(url: original)
        let sourceTracks = try await source.loadTracks(withMediaType: .video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let sourceTransform = try await XCTUnwrap(sourceTracks.first).load(.preferredTransform)
        XCTAssertEqual(size, CGSize(width: 96, height: 64))
        XCTAssertEqual(transform, sourceTransform)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, project.editedDuration, accuracy: 0.02)
        let edited = directory.appendingPathComponent("edited.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: edited, format: .mp4) { _ in }
        let image = try await AVAssetImageGenerator(asset: AVURLAsset(url: edited)).image(at: .zero).image
        XCTAssertEqual(image.width, 480); XCTAssertEqual(image.height, 270)
    }

    func testAudioMixVolumesAndAudioRemovalReachExport() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions(); options.capturesMicrophone = true
        let writer = try RecordingWriter(directory: directory, width: 64, height: 64, options: options)
        try await RecordingTests.enqueue(writer, type: .screen) { try RecordingTests.frame(at: 100) }
        _ = try await writer.waitForFirstFrame()
        try await RecordingTests.enqueue(writer, type: .audio) { try RecordingTests.audio(at: 100.1, sampleRate: 48000, channels: 2, amplitude: 0.2) }
        try await RecordingTests.enqueue(writer, type: .microphone) { try RecordingTests.audio(at: 100.1, sampleRate: 44100, channels: 1, amplitude: 0.4) }
        _ = try await writer.finish(at: 101)
        let asset = AVURLAsset(url: directory.appendingPathComponent("screen.mov"))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var project = VideoProject(duration: 1, width: 64, height: 64, frameRate: 30)
        project.systemAudioTrackID = audioTracks.first?.trackID; project.microphoneAudioTrackID = audioTracks.last?.trackID
        project.edits.maximumDimension = 320; project.edits.showsBackground = false
        let audible = directory.appendingPathComponent("audible.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: audible, format: .mp4) { _ in }
        let audiblePeak = try await Self.audioPeak(at: audible)
        XCTAssertGreaterThan(audiblePeak, 0.1)
        project.edits.systemVolume = 0; project.edits.microphoneVolume = 0
        let muted = directory.appendingPathComponent("muted.mp4")
        try await VideoExporter.export(project: project, directory: directory, destination: muted, format: .mp4) { _ in }
        let mutedPeak = try await Self.audioPeak(at: muted)
        XCTAssertLessThan(mutedPeak, 0.001)
        project.edits.audioEnabled = false
        for format in [VideoExportFormat.mp4, .original] {
            let silent = directory.appendingPathComponent("silent.\(format.fileExtension)")
            try await VideoExporter.export(project: project, directory: directory, destination: silent, format: format) { _ in }
            let tracks = try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)
            XCTAssertTrue(tracks.isEmpty)
        }
    }

    private static func audioPeak(at url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CliptError.message("The audio test couldn’t start reading.") }
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
            let bytes = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: bytes / 4)
            _ = samples.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: pointer.baseAddress!)
            }
            peak = max(peak, samples.map(abs).max() ?? 0)
        }
        guard reader.status == .completed else { throw reader.error ?? CliptError.message("The audio test didn’t finish reading.") }
        return peak
    }

    private static func noisyMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640, AVVideoHeightKey: 360, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CliptError.message("The video test fixture couldn’t start.") }
        writer.startSession(atSourceTime: .zero)
        var seed: UInt32 = 42
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CliptError.message("The video test fixture stopped encoding.") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CliptError.message("The video test fixture couldn’t allocate a frame.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<360 {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<640 {
                        seed = seed &* 1664525 &+ 1013904223
                        row[x] = seed | 0xff000000
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)) else { throw writer.error ?? CliptError.message("The video test fixture couldn’t write a frame.") }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CliptError.message("The video test fixture couldn’t finish.") }
    }
}
