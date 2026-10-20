import Foundation

enum RecordingMode: String, CaseIterable, Identifiable, Sendable {
    case fullScreen = "Full screen", area = "Area", window = "Window"
    var id: String { rawValue }
}

enum RecordingState: String, Sendable {
    case idle, preparing, recording, paused, stopping
}

struct RecordingOptions: Sendable {
    var mode: RecordingMode = .area
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
