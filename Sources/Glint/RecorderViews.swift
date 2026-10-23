import AppKit
import AVFoundation
import SwiftUI

// the recording half of the capture bar
struct RecordingBarControls: View {
    @Binding var options: RecordingOptions

    var body: some View {
        HStack(spacing: 2) {
            Segmented {
                format(.video, "Video")
                format(.gif, "GIF")
            }
            BarDivider()
            toggle($options.capturesSystemAudio, on: "speaker.wave.2.fill", off: "speaker.slash", help: "System audio")
            toggle($options.capturesMicrophone, on: "mic.fill", off: "mic.slash", help: "Microphone")
            devices(Self.microphones, selection: $options.microphoneDeviceID, enabled: $options.capturesMicrophone, help: "Choose microphone")
            toggle($options.capturesCamera, on: "video.fill", off: "video.slash", help: "Camera")
            devices(Self.cameras, selection: $options.cameraDeviceID, enabled: $options.capturesCamera, help: "Choose camera")
            BarDivider()
            toggle($options.showsCursor, on: "cursorarrow", off: "cursorarrow.slash", help: "Cursor")
            toggle($options.showsClicks, on: "cursorarrow.click.2", off: "cursorarrow.click", help: "Clicks")
            toggle($options.showsKeystrokes, on: "keyboard.fill", off: "keyboard", help: "Keystrokes. Every key you type is saved with the recording")
            MenuButton(help: "Options", items: menu) { Image(systemName: "slider.horizontal.3") }
        }
    }

    private func format(_ value: RecordingFormat, _ title: String) -> some View {
        Button { options.format = value } label: { Text(title).font(.system(size: 12, weight: .semibold)) }
            .buttonStyle(ToolButtonStyle(selected: options.format == value, size: CGSize(width: 44, height: 24), tint: .primary))
            .accessibilityAddTraits(options.format == value ? .isSelected : [])
    }

    private func toggle(_ isOn: Binding<Bool>, on: String, off: String, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: isOn.wrappedValue ? on : off)
                .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
        }
        .buttonStyle(ToolButtonStyle(selected: isOn.wrappedValue, tint: .primary))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private func devices(_ list: [AVCaptureDevice], selection: Binding<String?>, enabled: Binding<Bool>, help: String) -> some View {
        MenuButton(help: help, width: 14, items: {
            ([nil] + list.map(Optional.some)).map { device in
                let item = HandlerMenuItem(device?.localizedName ?? "System Default") {
                    selection.wrappedValue = device?.uniqueID
                    enabled.wrappedValue = true
                }
                item.state = selection.wrappedValue == device?.uniqueID ? .on : .off
                return item
            }
        }) {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.leading, -2)
    }

    private func menu() -> [NSMenuItem] {
        func submenu(_ title: String, _ choices: [(String, Int)], _ value: WritableKeyPath<RecordingOptions, Int>) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu()
            for (name, number) in choices {
                let choice = HandlerMenuItem(name) { options[keyPath: value] = number }
                choice.state = options[keyPath: value] == number ? .on : .off
                menu.addItem(choice)
            }
            item.submenu = menu
            return item
        }
        let desktop = HandlerMenuItem("Hide Desktop Icons") { options.hideDesktop.toggle() }
        desktop.state = options.hideDesktop ? .on : .off
        let shortcuts = HandlerMenuItem("Only Show Shortcuts") { options.keystrokesOnlyShortcuts.toggle() }
        shortcuts.state = options.keystrokesOnlyShortcuts ? .on : .off
        shortcuts.isEnabled = options.showsKeystrokes
        return [submenu("Frame Rate", [("24 fps", 24), ("30 fps", 30), ("60 fps", 60)], \.framesPerSecond),
                submenu("Resolution", [("1080p", 1920), ("1440p", 2560), ("4K", 3840)], \.maximumDimension),
                .separator(), desktop, shortcuts]
    }

    private static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    private static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }
}

@MainActor
protocol RecordingStatus: AnyObject {
    var state: RecordingState { get }
    var elapsed: TimeInterval { get }
    var countdownRemaining: Int { get }
    var microphoneLevel: Double { get }
}

extension RecordingController: RecordingStatus {}

// floating capsule shown while a recording runs
struct RecordingControls: View {
    let recorder: any RecordingStatus
    var showsMicrophone = false
    var saving = false
    let onPause: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void
    let onRestart: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 2) {
            if saving || recorder.state == .stopping {
                ProgressView().controlSize(.small).padding(.leading, 8)
                Text("Saving").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
            } else if recorder.state == .preparing || recorder.state == .idle {
                status(recorder.countdownRemaining > 0 ? "\(recorder.countdownRemaining)" : nil)
                tool("xmark", help: "Cancel", action: onCancel)
            } else {
                status(AppDelegate.duration(recorder.elapsed))
                if showsMicrophone { microphone }
                BarDivider()
                tool(recorder.state == .paused ? "play.fill" : "pause.fill", help: recorder.state == .paused ? "Resume" : "Pause", action: onPause)
                tool("arrow.counterclockwise", help: "Restart", action: onRestart)
                tool("trash", help: "Delete", action: onDelete)
                Button(action: onStop) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white).frame(width: 10, height: 10)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red))
                }
                .buttonStyle(.plain)
                .help("Stop")
                .accessibilityLabel("Stop")
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
        .padding(16)
        .onAppear { pulse = !reduceMotion }
    }

    private func status(_ text: String?) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(recorder.state == .paused ? Color.secondary : Color.red)
                .frame(width: 8, height: 8)
                .opacity(recorder.state == .recording && pulse ? 0.35 : 1)
                .animation(recorder.state == .recording && pulse ? .easeInOut(duration: 0.9).repeatForever() : .default, value: pulse)
            if let text {
                Text(text)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(recorder.state == .paused ? Color.secondary : Color.primary)
                    .contentTransition(.numericText())
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recorder.state == .paused ? "Paused" : "Recording")
        .accessibilityValue(text ?? "")
    }

    private var microphone: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(Color.green).frame(height: max(2, 14 * min(1, recorder.microphoneLevel)))
            }
            .frame(width: 3, height: 14)
        }
        .padding(.trailing, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(recorder.microphoneLevel * 100)) percent")
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ToolButtonStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}
