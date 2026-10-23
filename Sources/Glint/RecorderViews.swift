import AppKit
import AVFoundation
import SwiftUI

struct RecordingSetupView: View {
    let onRecord: (RecordingOptions) -> Void
    @State private var options = RecordingOptions()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Capture", selection: $options.mode) {
                        ForEach(RecordingMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Countdown", selection: $options.countdown) {
                        Text("None").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                }
                Section("Audio & camera") {
                    Toggle("System audio", isOn: $options.capturesSystemAudio)
                    Toggle("Microphone", isOn: $options.capturesMicrophone)
                    if options.capturesMicrophone {
                        Picker("Microphone", selection: $options.microphoneDeviceID) {
                            Text("System default").tag(String?.none)
                            ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                        }
                    }
                    Toggle("Camera", isOn: $options.capturesCamera)
                    if options.capturesCamera {
                        Picker("Camera", selection: $options.cameraDeviceID) {
                            Text("System default").tag(String?.none)
                            ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                        }
                    }
                }
                Section("Appearance") {
                    Toggle("Hide desktop items", isOn: $options.hideDesktop)
                    Toggle("Show cursor", isOn: $options.showsCursor)
                    Toggle("Highlight clicks", isOn: $options.showsClicks)
                    Toggle("Record keys", isOn: $options.showsKeystrokes)
                    if options.showsKeystrokes {
                        Toggle("Show shortcuts only", isOn: $options.keystrokesOnlyShortcuts)
                        Text("All keys typed during recording are stored in the editable project. Only enable for non-sensitive recordings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Quality") {
                    Picker("Frame rate", selection: $options.framesPerSecond) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("Resolution", selection: $options.maximumDimension) {
                        Text("1080p").tag(1920)
                        Text("1440p").tag(2560)
                        Text("4K").tag(3840)
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Record", systemImage: "record.circle") {
                    saveOptions()
                    onRecord(options)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }.padding(16)
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear { loadOptions() }
    }

    private var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    private var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    private func saveOptions() {
        let defaults = UserDefaults.standard
        defaults.set(options.mode.rawValue, forKey: "record.mode")
        defaults.set(options.countdown, forKey: "record.countdown")
        defaults.set(options.framesPerSecond, forKey: "record.fps")
        defaults.set(options.maximumDimension, forKey: "record.size")
        defaults.set(options.capturesSystemAudio, forKey: "record.systemAudio")
        defaults.set(options.capturesMicrophone, forKey: "record.microphone")
        defaults.set(options.capturesCamera, forKey: "record.camera")
        defaults.set(options.showsCursor, forKey: "record.cursor")
        defaults.set(options.hideDesktop, forKey: "record.hideDesktop")
        defaults.set(options.showsClicks, forKey: "record.clicks")
        defaults.set(options.showsKeystrokes, forKey: "record.keys")
        defaults.set(options.keystrokesOnlyShortcuts, forKey: "record.shortcutsOnly")
    }

    private func loadOptions() {
        let defaults = UserDefaults.standard
        guard let mode = defaults.string(forKey: "record.mode").flatMap(RecordingMode.init(rawValue:)) else { return }
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
    }
}

struct RecordingControls: View {
    let recorder: RecordingController
    let onPause: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Circle().fill(recorder.state == .paused ? Color.orange : .red).frame(width: 10, height: 10)
                if recorder.state == .preparing {
                    Text(recorder.countdownRemaining > 0 ? "\(recorder.countdownRemaining)" : "Preparing…").monospacedDigit()
                    Spacer()
                    Button("Cancel", action: onCancel)
                } else if recorder.state == .stopping {
                    ProgressView().controlSize(.small)
                    Text("Finishing…")
                    Spacer()
                } else {
                    Text(AppDelegate.duration(recorder.elapsed)).font(.system(.title3, design: .monospaced))
                    Spacer()
                    Button(recorder.state == .paused ? "Resume" : "Pause", systemImage: recorder.state == .paused ? "play.fill" : "pause.fill", action: onPause)
                    Button("Stop", systemImage: "stop.fill", action: onStop).buttonStyle(.borderedProminent)
                }
            }
            if recorder.microphoneLevel > 0 {
                ProgressView(value: recorder.microphoneLevel).tint(.green).accessibilityLabel("Microphone level")
            }
        }.padding(16).frame(minWidth: 350, minHeight: 70)
    }
}
