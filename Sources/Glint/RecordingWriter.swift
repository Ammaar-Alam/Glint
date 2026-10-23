import AVFoundation
import CoreImage
import ScreenCaptureKit

struct RecordingTimeline: Equatable {
    var origin: Double?
    private(set) var pausedAt: Double?
    private(set) var pauses: [ClosedRange<Double>] = []

    mutating func pause(at time: Double) {
        guard origin != nil, pausedAt == nil else { return }
        pausedAt = time
    }

    mutating func resume(at time: Double) {
        guard let start = pausedAt else { return }
        pauses.append(start...max(start, time))
        pausedAt = nil
    }

    func presentationTime(for time: Double) -> Double? {
        guard let origin, time >= origin,
              pausedAt.map({ time < $0 }) ?? true,
              !pauses.contains(where: { $0.contains(time) && time < $0.upperBound }) else { return nil }
        return max(0, time - origin - pauses.reduce(0) { total, pause in
            total + (time >= pause.upperBound ? pause.upperBound - pause.lowerBound : 0)
        })
    }

    func elapsed(at time: Double) -> Double {
        guard let origin else { return 0 }
        let endpoint = min(time, pausedAt ?? time)
        return max(0, endpoint - origin - pauses.reduce(0) { total, pause in
            total + max(0, min(endpoint, pause.upperBound) - pause.lowerBound)
        })
    }

    func activeRanges(from start: Double, to end: Double) -> [Range<Double>] {
        guard let origin else { return [] }
        let end = min(end, pausedAt ?? end)
        var cursor = max(start, origin)
        guard cursor < end else { return [] }
        var ranges: [Range<Double>] = []
        for pause in pauses where pause.upperBound > cursor && pause.lowerBound < end {
            if pause.lowerBound > cursor { ranges.append(cursor..<min(end, pause.lowerBound)) }
            cursor = max(cursor, pause.upperBound)
        }
        if cursor < end { ranges.append(cursor..<end) }
        return ranges
    }
}

struct RecordingWriterResult {
    var duration: Double
    var cameraStartTime: Double?
    var droppedVideoFrames: Int
    var droppedAudioSamples: Int
}

// media state is confined to queue and callbacks are installed before capture starts
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Glint.recording.writer", qos: .userInitiated)
    var onFailure: ((Error) -> Void)?
    var onWindowFrame: ((CGRect) -> Void)?
    var onCameraStartTime: ((Double) -> Void)?
    var onAudioLevel: ((Double) -> Void)?

    private let directory: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private let frameRate: Int
    private var timeline = RecordingTimeline()
    private var startWaiters: [CheckedContinuation<Double, Error>] = []
    private var failure: Error?
    private var isFinishing = false
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoTime: Double = 0
    private var cameraWriter: AVAssetWriter?
    private var cameraInput: AVAssetWriterInput?
    private var cameraClock: CMClock?
    private var cameraStartTime: Double?
    private var lastCameraSample: CMSampleBuffer?
    private var lastCameraTime: Double = 0
    private var droppedVideoFrames = 0
    private var droppedAudioSamples = 0
    private var audioLevelTimestamp = 0.0

    init(directory: URL, width: Int, height: Int, options: RecordingOptions) throws {
        self.directory = directory
        self.frameRate = options.framesPerSecond
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("screen.mov"), fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: width, height: height, fps: options.framesPerSecond))
        videoInput.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(videoInput) else { throw GlintError.message("The screen recording encoder isn’t available.") }
        writer.add(videoInput)
        if options.capturesSystemAudio { audioInput = try makeAudioInput(title: "System Audio", channels: 2) }
        if options.capturesMicrophone { microphoneInput = try makeAudioInput(title: "Microphone", channels: 1) }
    }

    private static func videoSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264,
         AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * fps / 7),
                                          AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalKey: fps * 2]]
    }

    private func makeAudioInput(title: String, channels: Int) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 128000 : 192000])
        input.expectsMediaDataInRealTime = true
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .quickTimeUserDataTrackName
        metadata.value = title as NSString
        input.metadata = [metadata]
        guard writer.canAdd(input) else { throw GlintError.message("The audio recording encoder isn’t available.") }
        writer.add(input)
        return input
    }

    func setCameraClock(_ clock: CMClock?) {
        queue.async { self.cameraClock = clock }
    }

    func waitForFirstFrame() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let failure = self.failure { continuation.resume(throwing: failure) }
                else if let origin = self.timeline.origin, self.lastVideoSample != nil { continuation.resume(returning: origin) }
                else {
                    self.startWaiters.append(continuation)
                    self.queue.asyncAfter(deadline: .now() + 8) {
                        guard self.lastVideoSample == nil, !self.startWaiters.isEmpty else { return }
                        self.fail(GlintError.message("No screen frames arrived. Check Screen Recording permission and try again."))
                    }
                }
            }
        }
    }

    func pause(at hostTime: Double) async {
        await withCheckedContinuation { continuation in
            queue.async { self.timeline.pause(at: hostTime); continuation.resume() }
        }
    }

    func resume(at hostTime: Double) async {
        await withCheckedContinuation { continuation in
            queue.async { self.timeline.resume(at: hostTime); continuation.resume() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if !self.isFinishing { self.fail(error) } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        consume(sampleBuffer, type: outputType)
    }

    func consume(_ sampleBuffer: CMSampleBuffer, type outputType: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinishing, failure == nil, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let hostTime = sampleBuffer.presentationTimeStamp.seconds
        guard hostTime.isFinite else { return }
        switch outputType {
        case .screen:
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            if let raw = attachments?.first?[.status] as? Int,
               raw != SCFrameStatus.complete.rawValue && raw != SCFrameStatus.started.rawValue { return }
            guard sampleBuffer.imageBuffer != nil else { return }
            if timeline.origin == nil {
                guard writer.startWriting() else { fail(writer.error ?? GlintError.message("The recording couldn’t be started.")); return }
                writer.startSession(atSourceTime: .zero)
                timeline.origin = hostTime
            }
            guard let time = timeline.presentationTime(for: hostTime) else { return }
            if let frame = attachments?.first?[.screenRect] as? CGRect { onWindowFrame?(frame) }
            else if let dictionary = attachments?.first?[.screenRect] as? [String: Any],
                    let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) { onWindowFrame?(frame) }
            append(sampleBuffer, time: time, to: videoInput, video: true)
            if failure == nil, lastVideoSample != nil, let origin = timeline.origin {
                startWaiters.forEach { $0.resume(returning: origin) }
                startWaiters.removeAll()
            }
        case .audio:
            if let input = audioInput { appendAudio(sampleBuffer, to: input) }
        case .microphone:
            if let input = microphoneInput {
                appendAudio(sampleBuffer, to: input)
                if timeline.presentationTime(for: hostTime) != nil { updateAudioLevel(sampleBuffer, at: hostTime) }
            }
        @unknown default: break
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard let format = sample.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mSampleRate.isFinite,
              description.mSampleRate > 0 else { fail(GlintError.message("The recording received an unsupported audio format.")); return }
        let rate = description.mSampleRate
        let count = sample.numSamples
        let start = sample.presentationTimeStamp.seconds
        for range in timeline.activeRanges(from: start, to: start + Double(count) / rate) {
            let frames = Self.audioFrameRange(range, sampleStart: start, frameCount: count, rate: rate)
            guard !frames.isEmpty else { continue }
            let time = timeline.elapsed(at: start + Double(frames.lowerBound) / rate)
            if frames.count == count { append(sample, time: time, to: input, video: false) }
            else {
                do { append(try Self.trimAudio(sample, frames: frames), time: time, to: input, video: false) }
                catch { fail(error); return }
            }
        }
    }

    static func audioFrameRange(_ range: Range<Double>, sampleStart: Double, frameCount: Int, rate: Double) -> Range<Int> {
        let tolerance = max(0.00001, max(sampleStart.ulp, max(range.lowerBound.ulp, range.upperBound.ulp)) * rate * 2)
        let first = range.lowerBound <= sampleStart ? 0 : max(0, min(frameCount, Int(ceil((range.lowerBound - sampleStart) * rate - tolerance))))
        let last = range.upperBound >= sampleStart + Double(frameCount) / rate ? frameCount : max(first, min(frameCount, Int(floor((range.upperBound - sampleStart) * rate + tolerance))))
        return first..<last
    }

    static func trimAudio(_ sample: CMSampleBuffer, frames: Range<Int>) throws -> CMSampleBuffer {
        guard frames.lowerBound >= 0, frames.upperBound <= sample.numSamples, !frames.isEmpty,
              frames.lowerBound <= Int32.max, frames.count <= Int32.max,
              let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)) else {
            throw GlintError.message("The recording received an invalid audio frame range or format.")
        }
        pcm.frameLength = pcm.frameCapacity
        // PCM may be planar and omit the sample sizes required by generic range copying
        var status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(frames.lowerBound), frameCount: Int32(frames.count), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw GlintError.message("The audio samples couldn’t be copied (CoreMedia \(status)).") }
        var timing = CMSampleTimingInfo()
        status = CMSampleBufferGetSampleTimingInfo(sample, at: frames.lowerBound, timingInfoOut: &timing)
        guard status == noErr else { throw GlintError.message("The audio timestamp couldn’t be read (CoreMedia \(status)).") }
        var trimmed: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: frames.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &trimmed)
        guard status == noErr, let trimmed else { throw GlintError.message("The trimmed audio couldn’t be prepared (CoreMedia \(status)).") }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(trimmed, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
        guard status == noErr else { throw GlintError.message("The trimmed audio couldn’t be stored (CoreMedia \(status)).") }
        status = CMSampleBufferSetDataReady(trimmed)
        guard status == noErr else { throw GlintError.message("The trimmed audio couldn’t be made ready (CoreMedia \(status)).") }
        return trimmed
    }

    private func append(_ sample: CMSampleBuffer, time: Double, to input: AVAssetWriterInput, video: Bool) {
        guard input.isReadyForMoreMediaData else {
            if video { droppedVideoFrames += 1 } else { droppedAudioSamples += 1 }
            return
        }
        do {
            let retimed = try Self.retime(sample, to: time)
            guard input.append(retimed) else { fail(writer.error ?? GlintError.message("The recording couldn’t be written. Check available disk space.")); return }
            if video { lastVideoSample = retimed; lastVideoTime = time }
        } catch { fail(error) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isFinishing, failure == nil, timeline.origin != nil, CMSampleBufferDataIsReady(sampleBuffer),
              let image = sampleBuffer.imageBuffer else { return }
        let timestamp = cameraClock.map { CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: $0, to: CMClockGetHostTimeClock()) } ?? sampleBuffer.presentationTimeStamp
        guard let time = timeline.presentationTime(for: timestamp.seconds) else { return }
        do {
            if cameraWriter == nil {
                let camera = try AVAssetWriter(outputURL: directory.appendingPathComponent("camera.mov"), fileType: .mov)
                camera.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), fps: frameRate))
                input.expectsMediaDataInRealTime = true
                guard camera.canAdd(input) else { throw GlintError.message("The camera recording encoder isn’t available.") }
                camera.add(input)
                guard camera.startWriting() else { throw camera.error ?? GlintError.message("The camera recording couldn’t start.") }
                camera.startSession(atSourceTime: .zero)
                cameraWriter = camera; cameraInput = input; cameraStartTime = time
                onCameraStartTime?(time)
            }
            guard let input = cameraInput, let cameraWriter, let start = cameraStartTime else { return }
            guard input.isReadyForMoreMediaData else { droppedVideoFrames += 1; return }
            let retimed = try Self.retime(sampleBuffer, to: max(0, time - start))
            guard input.append(retimed) else { throw cameraWriter.error ?? GlintError.message("The camera recording couldn’t be written.") }
            lastCameraSample = retimed; lastCameraTime = time - start
        } catch { fail(error) }
    }

    private func updateAudioLevel(_ sample: CMSampleBuffer, at hostTime: Double) {
        guard hostTime - audioLevelTimestamp > 0.08, let block = sample.dataBuffer,
              let format = sample.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32 else { return }
        audioLevelTimestamp = hostTime
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer, length >= MemoryLayout<Float>.size else { return }
        let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        let count = length / MemoryLayout<Float>.size
        var peak: Float = 0
        for index in 0..<count { peak = max(peak, abs(samples[index])) }
        onAudioLevel?(min(1, Double(peak)))
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        startWaiters.forEach { $0.resume(throwing: error) }
        startWaiters.removeAll()
        onFailure?(error)
    }

    static func retime(_ sample: CMSampleBuffer, to seconds: Double) throws -> CMSampleBuffer {
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { throw GlintError.message("The recording received an invalid timestamp.") }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        guard status == noErr else { throw GlintError.message("The recording timestamp couldn’t be read.") }
        let delta = CMTimeSubtract(sample.presentationTimeStamp, CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, delta)
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, delta) }
        }
        var result: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result)
        guard status == noErr, let result else { throw GlintError.message("The recording timestamp couldn’t be updated.") }
        return result
    }

    func finish(at hostTime: Double) async throws -> RecordingWriterResult {
        for attempt in 0..<250 {
            let ready = await withCheckedContinuation { continuation in
                queue.async {
                    self.isFinishing = true
                    continuation.resume(returning: self.writer.status != .writing ||
                        (self.videoInput.isReadyForMoreMediaData && (self.cameraWriter?.status != .writing || self.cameraInput?.isReadyForMoreMediaData == true)))
                }
            }
            if ready { break }
            if attempt == 249 { throw GlintError.message("The video encoder didn’t finish in time. The recorded media has been kept for recovery.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.isFinishing = true
                guard self.timeline.origin != nil else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: self.failure ?? GlintError.message("The recording contains no screen frames."))
                    return
                }
                guard self.writer.status == .writing else {
                    continuation.resume(throwing: self.writer.error ?? self.failure ?? GlintError.message("The recording writer stopped unexpectedly."))
                    return
                }
                let duration = max(self.timeline.elapsed(at: hostTime), self.lastVideoTime + 1 / Double(self.frameRate))
                do {
                    if let last = self.lastVideoSample, duration - 1 / Double(self.frameRate) > self.lastVideoTime {
                        guard self.videoInput.isReadyForMoreMediaData,
                              self.videoInput.append(try Self.retime(last, to: duration - 1 / Double(self.frameRate))) else {
                            throw self.writer.error ?? GlintError.message("The encoder couldn’t finish the last frame. The recorded media has been kept for recovery.")
                        }
                    }
                    self.writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
                    self.videoInput.markAsFinished()
                    self.audioInput?.markAsFinished(); self.microphoneInput?.markAsFinished()
                    if let camera = self.cameraWriter, camera.status == .writing, let input = self.cameraInput, let start = self.cameraStartTime {
                        let end = max(self.lastCameraTime + 1 / Double(self.frameRate), duration - start)
                        if let last = self.lastCameraSample, end - 1 / Double(self.frameRate) > self.lastCameraTime {
                            guard input.isReadyForMoreMediaData, input.append(try Self.retime(last, to: end - 1 / Double(self.frameRate))) else {
                                throw camera.error ?? GlintError.message("The encoder couldn’t finish the camera recording. The recorded media has been kept for recovery.")
                            }
                        }
                        camera.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600)); input.markAsFinished()
                    }
                    let group = DispatchGroup()
                    group.enter(); self.writer.finishWriting { group.leave() }
                    if let camera = self.cameraWriter, camera.status == .writing { group.enter(); camera.finishWriting { group.leave() } }
                    group.notify(queue: self.queue) {
                        if let error = self.writer.error ?? self.cameraWriter?.error { continuation.resume(throwing: error) }
                        else if self.writer.status != .completed { continuation.resume(throwing: self.failure ?? GlintError.message("The recording didn’t finish writing.")) }
                        else {
                            continuation.resume(returning: RecordingWriterResult(duration: duration, cameraStartTime: self.cameraStartTime,
                                droppedVideoFrames: self.droppedVideoFrames, droppedAudioSamples: self.droppedAudioSamples))
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                if self.writer.status == .writing || self.writer.status == .unknown { self.writer.cancelWriting() }
                if let camera = self.cameraWriter, camera.status == .writing || camera.status == .unknown { camera.cancelWriting() }
                self.startWaiters.forEach { $0.resume(throwing: CancellationError()) }; self.startWaiters.removeAll()
                continuation.resume()
            }
        }
    }
}
