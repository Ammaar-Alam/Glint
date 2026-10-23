import Foundation

enum RecordingMode: String, CaseIterable, Identifiable, Sendable {
    case fullScreen = "Full screen", area = "Area", window = "Window"
    var id: String { rawValue }
}

enum RecordingState: String, Sendable {
    case idle, preparing, recording, paused, stopping
}

enum RecordingFormat: String, Sendable {
    case video, gif
}

struct RecordingOptions: Sendable {
    var mode: RecordingMode = .area
    var format: RecordingFormat = .video
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var capturesCamera = false
    var hideDesktop = false
    var showsCursor = true
    var showsClicks = true
    var showsKeystrokes = false
    var keystrokesOnlyShortcuts = true
    var countdown: Int = 3
    var framesPerSecond: Int = 30
    var maximumDimension: Int = 2560
    var microphoneDeviceID: String?
    var cameraDeviceID: String?
}

extension RecordingOptions {
    // the format is chosen per recording, everything else is remembered
    static func saved(_ defaults: UserDefaults = .standard) -> RecordingOptions {
        var options = RecordingOptions()
        guard let mode = defaults.string(forKey: "record.mode").flatMap(RecordingMode.init(rawValue:)) else { return options }
        options.mode = mode
        options.countdown = defaults.integer(forKey: "record.countdown")
        options.framesPerSecond = defaults.integer(forKey: "record.fps")
        options.maximumDimension = defaults.integer(forKey: "record.size")
        options.capturesSystemAudio = defaults.bool(forKey: "record.systemAudio")
        options.capturesMicrophone = defaults.bool(forKey: "record.microphone")
        options.capturesCamera = defaults.bool(forKey: "record.camera")
        options.showsCursor = defaults.bool(forKey: "record.cursor")
        options.hideDesktop = defaults.bool(forKey: "record.hideDesktop")
        options.showsClicks = defaults.bool(forKey: "record.clicks")
        options.showsKeystrokes = defaults.bool(forKey: "record.keys")
        options.keystrokesOnlyShortcuts = defaults.bool(forKey: "record.shortcutsOnly")
        return options
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: "record.mode")
        defaults.set(countdown, forKey: "record.countdown")
        defaults.set(framesPerSecond, forKey: "record.fps")
        defaults.set(maximumDimension, forKey: "record.size")
        defaults.set(capturesSystemAudio, forKey: "record.systemAudio")
        defaults.set(capturesMicrophone, forKey: "record.microphone")
        defaults.set(capturesCamera, forKey: "record.camera")
        defaults.set(showsCursor, forKey: "record.cursor")
        defaults.set(hideDesktop, forKey: "record.hideDesktop")
        defaults.set(showsClicks, forKey: "record.clicks")
        defaults.set(showsKeystrokes, forKey: "record.keys")
        defaults.set(keystrokesOnlyShortcuts, forKey: "record.shortcutsOnly")
    }
}
