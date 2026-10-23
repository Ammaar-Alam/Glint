@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ImageIO
import UniformTypeIdentifiers

enum VideoExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4", gif = "GIF", original = "Trim Only"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .gif: return "gif"
        case .original: return "mov"
        }
    }
}

enum VideoExporter {
    static func videoBitRate(project: VideoProject) -> Int {
        let size = VideoGeometry.outputSize(for: project)
        let pixels = min(7680, max(2, size.width)) * min(7680, max(2, size.height))
        let quality = min(1, max(0, project.edits.exportQuality))
        let bitsPerPixel = 0.025 + 0.275 * pow(quality, 1.5)
        return Int(min(120_000_000, max(200_000, pixels * Double(min(60, max(1, project.frameRate))) * bitsPerPixel)))
    }

    static func estimatedSize(project: VideoProject) -> Int64 {
        let seconds = project.editedDuration
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let rate = videoBitRate(project: project) + (project.edits.audioEnabled ? 192_000 : 0)
        let bytes = seconds * Double(rate) / 8 * 1.02
        return bytes >= Double(Int64.max) ? Int64.max : Int64(bytes)
    }

    static func export(project: VideoProject, directory: URL, destination: URL, format: VideoExportFormat, backgroundDirectory: URL? = nil, gifFrameRate: Int = 15,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        _ = try project.validated()
        if format == .gif, !(1...50).contains(gifFrameRate) { throw CliptError.message("Choose a GIF frame rate between 1 and 50.") }
        guard destination.isFileURL else { throw CliptError.message("Choose a local destination for the export.") }
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let projectFiles = [project.screenFile, project.cameraFile, "project.json"].compactMap { $0 } + project.backgroundFiles
        let protectedURLs = projectFiles.map { directory.appendingPathComponent($0) }
            + (backgroundDirectory.map { workspace in project.backgroundFiles.map { workspace.appendingPathComponent($0) } } ?? [])
        guard !protectedURLs.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL == resolvedDestination
        }) else { throw CliptError.message("Choose a different destination to preserve the editable project’s original media.") }
        let composition = try await VideoCompositionBuilder.make(project: project, directory: directory, includeEffects: format != .original, backgroundDirectory: backgroundDirectory)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Clipt-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress(0)
        switch format {
        case .mp4:
            try await encodeMP4(composition: composition, project: project, destination: temporary, progress: progress)
        case .original:
            try await passthrough(composition: composition, destination: temporary, progress: progress)
        case .gif:
            try await encodeGIF(composition: composition, project: project, destination: temporary, frameRate: gifFrameRate, progress: progress)
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        progress(1)
    }

    private static func encodeMP4(composition: VideoCompositionResult, project: VideoProject, destination: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: composition.asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let videoTracks = try await composition.asset.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = composition.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw CliptError.message("The video couldn’t be prepared for export.") }
        reader.add(videoOutput)
        let size = composition.videoComposition.renderSize
        let fps = min(60, project.frameRate)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitRate(project: project),
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw CliptError.message("Choose a smaller export size for this Mac’s encoder.") }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw CliptError.message("The video encoder couldn’t be started.") }
        writer.add(videoInput)
        let audioTracks = try await composition.asset.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            output.audioMix = composition.audioMix; output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
            guard reader.canAdd(output), writer.canAdd(input) else { throw CliptError.message("The recording’s audio couldn’t be prepared for export.") }
            reader.add(output); writer.add(input)
            audioOutput = output; audioInput = input
        }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard writer.startWriting() else { throw writer.error ?? CliptError.message("The video encoder couldn’t start.") }
                writer.startSession(atSourceTime: .zero)
                guard reader.startReading() else { throw reader.error ?? CliptError.message("The video couldn’t be read.") }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await transfer(output: videoOutput, input: videoInput, reader: reader, writer: writer, duration: composition.duration, progress: progress) }
                    if let audioOutput, let audioInput {
                        group.addTask { try await transfer(output: audioOutput, input: audioInput, reader: reader, writer: writer, duration: composition.duration, progress: nil) }
                    }
                    do { while try await group.next() != nil {} }
                    catch {
                        group.cancelAll(); reader.cancelReading(); writer.cancelWriting()
                        throw error
                    }
                }
                try Task.checkCancellation()
                guard reader.status == .completed else { throw reader.error ?? CliptError.message("The video couldn’t be read completely.") }
                writer.endSession(atSourceTime: CMTime(seconds: composition.duration, preferredTimescale: 600))
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw writer.error ?? CliptError.message("The export couldn’t finish. Check available disk space.") }
            } catch {
                reader.cancelReading()
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
                throw error
            }
        } onCancel: {
            reader.cancelReading()
            if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        }
    }

    private static func transfer(output: AVAssetReaderOutput, input: AVAssetWriterInput, reader: AVAssetReader,
                                 writer: AVAssetWriter, duration: Double, progress: (@Sendable (Double) -> Void)?) async throws {
        while true {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? CliptError.message("The export stopped writing.") }
            guard reader.status != .failed else { throw reader.error ?? CliptError.message("The export stopped reading.") }
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(4))
                continue
            }
            guard let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) else {
                if reader.status == .failed { throw reader.error ?? CliptError.message("A video frame couldn’t be decoded.") }
                try Task.checkCancellation()
                input.markAsFinished()
                return
            }
            guard input.append(sample) else { throw writer.error ?? CliptError.message("The export couldn’t write a frame.") }
            progress?(min(0.99, max(0, sample.presentationTimeStamp.seconds / duration)))
        }
    }

    private static func passthrough(composition: VideoCompositionResult, destination: URL,
                                     progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: composition.asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mov) else { throw CliptError.message("This source can’t be exported without conversion. Choose MP4 instead.") }
        let monitor = Task {
            for await state in session.states(updateInterval: 0.15) {
                if case .exporting(let value) = state { progress(min(0.99, value.fractionCompleted)) }
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await session.export(to: destination, as: .mov)
            try Task.checkCancellation()
        } onCancel: { session.cancelExport() }
    }

    private static func encodeGIF(composition: VideoCompositionResult, project: VideoProject, destination: URL, frameRate: Int,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let renderTask = Task.detached(priority: .userInitiated) {
            let fps = min(frameRate, project.frameRate)
            let ticks = max(2, Int((composition.duration * 100).rounded()))
            func boundary(_ frame: Int) -> Int { (frame * 100 + fps / 2) / fps }
            var frameCount = max(1, (ticks * fps + 99) / 100)
            if frameCount > 1, ticks - boundary(frameCount - 1) < 2 { frameCount -= 1 }
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { throw CliptError.message("The GIF couldn’t be created.") }
            CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let generator = AVAssetImageGenerator(asset: composition.asset)
            generator.videoComposition = composition.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            do {
                for frame in 0..<frameCount {
                    try Task.checkCancellation()
                    let time = CMTime(seconds: min(composition.duration - 0.001, Double(frame) / Double(fps)), preferredTimescale: 600)
                    let image = try await generator.image(at: time).image
                    let end = frame == frameCount - 1 ? ticks : boundary(frame + 1)
                    let delay = Double(end - boundary(frame)) / 100
                    autoreleasepool {
                        CGImageDestinationAddImage(output, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
                    }
                    progress(min(0.99, Double(frame + 1) / Double(frameCount)))
                }
                guard CGImageDestinationFinalize(output) else { throw CliptError.message("The GIF couldn’t be finished. Check available disk space.") }
            } catch { generator.cancelAllCGImageGeneration(); throw error }
        }
        try await withTaskCancellationHandler { try await renderTask.value } onCancel: { renderTask.cancel() }
    }
}
