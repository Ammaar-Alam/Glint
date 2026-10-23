import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
@testable import Glint

final class RecordingTests: XCTestCase {
    func testPlanarScreenAudioCrossingFirstFrameDoesNotStopRecording() async throws {
        let directory = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try RecordingWriter(directory: directory, width: 64, height: 64, options: RecordingOptions())
        writer.onFailure = { error in XCTFail("Recording stopped early: \(error.localizedDescription)") }
        try await Self.enqueue(writer, type: .screen) { try Self.frame(at: 100) }
        _ = try await writer.waitForFirstFrame()
        try await Self.enqueue(writer, type: .audio) { try Self.planarAudio(at: 99.95, sampleRate: 48000, channels: 2) }
        _ = try await writer.finish(at: 100.2)
        let tracks = try await AVURLAsset(url: directory.appendingPathComponent("screen.mov")).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let range = try await XCTUnwrap(tracks.first).load(.timeRange)
        XCTAssertGreaterThan(range.duration.seconds, 0.04)
        XCTAssertLessThan(range.duration.seconds, 0.08)
    }

    func testPCMTrimPreservesPlanesSamplesAndNativeTiming() throws {
        for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            for interleaved in [false, true] {
                for channels: AVAudioChannelCount in [1, 2] {
                    for rate in [44_100.0, 48_000.0] {
                        let sample = try Self.planarAudio(at: 10_000_000.12345, sampleRate: rate, channels: channels,
                            interleaved: interleaved, frameCount: 1024, pattern: true, commonFormat: commonFormat)
                        let frames = 257..<901
                        let trimmed = try RecordingWriter.trimAudio(sample, frames: frames)
                        XCTAssertEqual(trimmed.numSamples, frames.count)
                        XCTAssertTrue(CMSampleBufferDataIsReady(trimmed))
                        XCTAssertEqual(trimmed.duration.seconds, Double(frames.count) / rate, accuracy: 0.000000000001)
                        var expected = CMSampleTimingInfo()
                        XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(sample, at: frames.lowerBound, timingInfoOut: &expected), noErr)
                        XCTAssertEqual(CMTimeCompare(trimmed.presentationTimeStamp, expected.presentationTimeStamp), 0)
                        XCTAssertFalse(trimmed.decodeTimeStamp.isValid)
                        let description = try XCTUnwrap(trimmed.formatDescription)
                        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
                        let format = try XCTUnwrap(AVAudioFormat(streamDescription: asbd))
                        XCTAssertEqual(format.channelCount, channels)
                        XCTAssertEqual(format.isInterleaved, interleaved)
                        XCTAssertEqual(format.sampleRate, rate)
                        XCTAssertEqual(format.commonFormat, commonFormat)
                        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)))
                        pcm.frameLength = pcm.frameCapacity
                        XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(trimmed, at: 0, frameCount: Int32(frames.count), into: pcm.mutableAudioBufferList), noErr)
                        for channel in 0..<Int(channels) {
                            for frame in 0..<frames.count {
                                let plane = interleaved ? 0 : channel
                                let index = interleaved ? frame * Int(channels) + channel : frame
                                let value: Float
                                if let samples = pcm.floatChannelData { value = samples[plane][index] }
                                else { value = Float(try XCTUnwrap(pcm.int16ChannelData)[plane][index]) }
                                XCTAssertEqual(value, Float(channel * 10_000 + frames.lowerBound + frame))
                            }
                        }
                    }
                }
            }
        }
    }

    func testAudioFrameBoundsPreserveAllSamplesAtLargeHostTimes() {
        for start in [100.1, 86_400.12345, 1_000_000.12345, 10_000_000.12345] {
            for rate in [44_100.0, 48_000.0, 96_000.0] {
                let whole = start..<(start + 1024 / rate)
                XCTAssertEqual(RecordingWriter.audioFrameRange(whole, sampleStart: start, frameCount: 1024, rate: rate), 0..<1024)
                let exact = (start + 257 / rate)..<(start + 901 / rate)
                XCTAssertEqual(RecordingWriter.audioFrameRange(exact, sampleStart: start, frameCount: 1024, rate: rate), 257..<901)
                let fractional = (start + 257.25 / rate)..<(start + 900.75 / rate)
                XCTAssertEqual(RecordingWriter.audioFrameRange(fractional, sampleStart: start, frameCount: 1024, rate: rate), 258..<900)
            }
        }
    }

    func testRecoveryKeepsUnimportedProjectsAndRejectsMalformedImportMarker() async throws {
        let root = try VideoTests.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = root.appendingPathComponent("completed.glintvideo", isDirectory: true)
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try await VideoTests.movie(at: completed.appendingPathComponent("screen.mov"))
        try VideoProject(duration: 1, width: 96, height: 64, frameRate: 10).save(to: completed)
        let interrupted = root.appendingPathComponent("interrupted.glintvideo", isDirectory: true)
        try FileManager.default.copyItem(at: completed, to: interrupted)
        try Data().write(to: interrupted.appendingPathComponent("recording-in-progress"))
        let imported = root.appendingPathComponent("imported.glintvideo", isDirectory: true)
        try FileManager.default.copyItem(at: completed, to: imported)
        try Data(UUID().uuidString.utf8).write(to: imported.appendingPathComponent("imported-to-library"))
        let malformed = root.appendingPathComponent("malformed.glintvideo", isDirectory: true)
        try FileManager.default.copyItem(at: completed, to: malformed)
        try Data("invalid marker".utf8).write(to: malformed.appendingPathComponent("imported-to-library"))
        let recovered = try await RecordingController.recoverInterruptedRecordings(in: root)
        XCTAssertEqual(Set(recovered.map { $0.resolvingSymlinksInPath() }), Set([completed, interrupted, malformed].map { $0.resolvingSymlinksInPath() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.appendingPathComponent("screen.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.appendingPathComponent("screen.mov").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.appendingPathComponent("recording-in-progress").path))
    }

    func testPauseTimeIsRemovedFromAllStreamsAndEvents() {
        var clock = RecordingTimeline(origin: 100)
        XCTAssertEqual(clock.presentationTime(for: 102), 2)
        clock.pause(at: 103)
        XCTAssertNil(clock.presentationTime(for: 104))
        XCTAssertEqual(clock.elapsed(at: 108), 3)
        clock.resume(at: 108)
        XCTAssertEqual(clock.presentationTime(for: 108), 3)
        XCTAssertNil(clock.presentationTime(for: 105))
        XCTAssertEqual(clock.presentationTime(for: 110), 5)
        clock.pause(at: 111); clock.resume(at: 113)
        XCTAssertEqual(clock.presentationTime(for: 114), 7)
        XCTAssertEqual(clock.elapsed(at: 114), 7)
        XCTAssertNil(clock.presentationTime(for: 99))
        XCTAssertEqual(clock.activeRanges(from: 102.9, to: 103.1), [102.9..<103])
        XCTAssertEqual(clock.activeRanges(from: 107.9, to: 108.1), [108..<108.1])
        XCTAssertEqual(clock.activeRanges(from: 102, to: 114), [102..<103, 108..<111, 113..<114])
    }

    @MainActor
    func testRecordingDimensionsAreBoundedAndEven() {
        let size = RecordingController.outputSize(for: CGSize(width: 1512, height: 982), scale: 2, maximumDimension: 1920)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertEqual(size.width / size.height, 1512 / 982, accuracy: 0.005)
        XCTAssertEqual(RecordingController.outputSize(for: CGSize(width: 1, height: 1), scale: 1, maximumDimension: 1920), CGSize(width: 2, height: 2))
    }

    func testWriterEncodesSeparateAudioTracksAndHoldsFinalFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glint-recording-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions(); options.capturesMicrophone = true
        let writer = try RecordingWriter(directory: directory, width: 64, height: 64, options: options)
        writer.onFailure = { error in XCTFail("Recording stopped early: \(error.localizedDescription)") }
        try await Self.enqueue(writer, type: .screen) { try Self.frame(at: 100) }
        let origin = try await writer.waitForFirstFrame()
        XCTAssertEqual(origin, 100, accuracy: 0.001)
        try await Self.enqueue(writer, type: .audio) { try Self.audio(at: 100.1, sampleRate: 48000, channels: 2) }
        try await Self.enqueue(writer, type: .microphone) { try Self.audio(at: 100.1, sampleRate: 44100, channels: 1) }
        await writer.pause(at: 101)
        try await Self.enqueue(writer, type: .screen) { try Self.frame(at: 101.5) }
        try await Self.enqueue(writer, type: .microphone) { try Self.audio(at: 100.95, sampleRate: 44100, channels: 1) }
        await writer.resume(at: 102)
        try await Self.enqueue(writer, type: .screen) { try Self.frame(at: 102.5) }
        try await Self.enqueue(writer, type: .microphone) { try Self.audio(at: 101.95, sampleRate: 44100, channels: 1) }
        let result = try await writer.finish(at: 103)
        XCTAssertEqual(result.duration, 2, accuracy: 0.001)
        XCTAssertEqual(result.droppedAudioSamples, 0)
        let asset = AVURLAsset(url: directory.appendingPathComponent("screen.mov"))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 2)
        var titles: Set<String> = []
        for track in audioTracks {
            for metadata in try await track.load(.metadata) where metadata.identifier == .quickTimeUserDataTrackName {
                if let title = try await metadata.load(.stringValue) { titles.insert(title) }
            }
        }
        XCTAssertEqual(titles, ["System Audio", "Microphone"])
        let generator = AVAssetImageGenerator(asset: asset)
        let final = try await generator.image(at: CMTime(seconds: 1.9, preferredTimescale: 600))
        XCTAssertEqual(final.image.width, 64)
    }

    static func enqueue(_ writer: RecordingWriter, type: SCStreamOutputType, sample: @escaping @Sendable () throws -> CMSampleBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.queue.async {
                do { writer.consume(try sample(), type: type); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func frame(at time: Double) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw GlintError.message("Couldn’t create the video test fixture.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let pointer = CVPixelBufferGetBaseAddress(buffer) { memset(pointer, 128, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw GlintError.message("Couldn’t create the video test sample.") }
        return sample
    }

    static func planarAudio(at time: Double, sampleRate: Double, channels: AVAudioChannelCount,
                            interleaved: Bool = false, frameCount: Int? = nil, pattern: Bool = false,
                            commonFormat: AVAudioCommonFormat = .pcmFormatFloat32) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: channels, interleaved: interleaved))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount ?? Int(sampleRate / 10))))
        pcm.frameLength = pcm.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        if pattern {
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(pcm.frameLength) {
                    let plane = interleaved ? 0 : channel
                    let index = interleaved ? frame * Int(channels) + channel : frame
                    let value = channel * 10_000 + frame
                    if let samples = pcm.floatChannelData { samples[plane][index] = Float(value) }
                    else if let samples = pcm.int16ChannelData { samples[plane][index] = Int16(value) }
                }
            }
        }
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw GlintError.message("Couldn’t create the planar audio test format.") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample else { throw GlintError.message("Couldn’t create the planar audio test sample.") }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(sample) == noErr else { throw GlintError.message("Couldn’t attach the planar audio test buffers.") }
        return sample
    }

    static func audio(at time: Double, sampleRate: Double, channels: UInt32, amplitude: Float = 0) throws -> CMSampleBuffer {
        let frameCount = Int(sampleRate / 10)
        let bytes = frameCount * Int(channels) * MemoryLayout<Float>.size
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: channels * 4,
            mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { throw GlintError.message("Couldn’t create the audio test format.") }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw GlintError.message("Couldn’t create the audio test buffer.") }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        if amplitude > 0 {
            let samples = (0..<(frameCount * Int(channels))).map { index in
                amplitude * Float(sin(Double(index / Int(channels)) * 440 * 2 * .pi / sampleRate))
            }
            _ = samples.withUnsafeBytes { pointer in
                CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample else { throw GlintError.message("Couldn’t create the audio test sample.") }
        return sample
    }
}
