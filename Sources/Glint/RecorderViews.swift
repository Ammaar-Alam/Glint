import AppKit
import AVFoundation
import SwiftUI

// the recording half of the capture bar, just the format and the two inputs people switch most
struct RecordingBarControls: View {
    @Binding var options: RecordingOptions

    var body: some View {
        HStack(spacing: 2) {
            Segmented {
                format(.video, "Video")
                format(.gif, "GIF")
            }
            toggle($options.capturesMicrophone, on: "mic.fill", off: "mic.slash", help: "Microphone")
            toggle($options.capturesCamera, on: "video.fill", off: "video.slash", help: "Camera")
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
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ToolButtonStyle(selected: isOn.wrappedValue, tint: .primary))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    // everything else about a recording, for the bar's options menu
    static func menu(_ options: Binding<RecordingOptions>) -> [NSMenuItem] {
        func check(_ title: String, _ value: WritableKeyPath<RecordingOptions, Bool>, enabled: Bool = true) -> NSMenuItem {
            let item = HandlerMenuItem(title) { options.wrappedValue[keyPath: value].toggle() }
            item.state = options.wrappedValue[keyPath: value] ? .on : .off
            item.isEnabled = enabled
            return item
        }
        func devices(_ title: String, _ list: [AVCaptureDevice], _ selection: WritableKeyPath<RecordingOptions, String?>, _ enabled: WritableKeyPath<RecordingOptions, Bool>) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu()
            for device in [nil] + list.map(Optional.some) {
                let choice = HandlerMenuItem(device?.localizedName ?? "System Default") {
                    options.wrappedValue[keyPath: selection] = device?.uniqueID
                    options.wrappedValue[keyPath: enabled] = true
                }
                choice.state = options.wrappedValue[keyPath: selection] == device?.uniqueID ? .on : .off
                menu.addItem(choice)
            }
            item.submenu = menu
            return item
        }
        let value = options.wrappedValue
        return [check("System Audio", \.capturesSystemAudio),
                devices("Microphone", microphones, \.microphoneDeviceID, \.capturesMicrophone),
                devices("Camera", cameras, \.cameraDeviceID, \.capturesCamera),
                .separator(),
                check("Show Cursor", \.showsCursor),
                check("Highlight Clicks", \.showsClicks),
                check("Show Keystrokes", \.showsKeystrokes),
                check("Only Shortcuts", \.keystrokesOnlyShortcuts, enabled: value.showsKeystrokes),
                .separator(),
                CaptureBar.submenu("Frame Rate", [("24 fps", 24), ("30 fps", 30), ("60 fps", 60)], selected: value.framesPerSecond) { options.wrappedValue.framesPerSecond = $0 },
                CaptureBar.submenu("Resolution", [("1080p", 1920), ("1440p", 2560), ("4K", 3840)], selected: value.maximumDimension) { options.wrappedValue.maximumDimension = $0 },
                check("Hide Desktop Icons", \.hideDesktop)]
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
        .background(Color.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 3)
        .animation(.snappy(duration: 0.22), value: recorder.state)
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

// a thin outline marks what is being recorded, the countdown plays in the middle of it
struct RecordingFrame: View {
    let recorder: any RecordingStatus
    // in the panel's top-left coordinates, nil for the whole display
    let area: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let hole = area ?? CGRect(origin: .zero, size: proxy.size)
            let counting = recorder.countdownRemaining > 0
            ZStack {
                // the outside dims only while counting down, then gets out of the way
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(hole)
                }
                .fill(Color.black.opacity(counting && area != nil ? 0.3 : 0), style: FillStyle(eoFill: true))
                if area != nil {
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(width: hole.width + 3, height: hole.height + 3)
                        .position(x: hole.midX, y: hole.midY)
                }
                if counting {
                    Text("\(recorder.countdownRemaining)")
                        .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 168, height: 168)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .id(recorder.countdownRemaining)
                        .transition(reduceMotion ? .opacity : .scale(scale: 1.25).combined(with: .opacity))
                        .position(x: hole.midX, y: hole.midY)
                        .accessibilityLabel("Recording starts in \(recorder.countdownRemaining)")
                }
            }
            .animation(.easeOut(duration: 0.3), value: recorder.countdownRemaining)
        }
        .ignoresSafeArea()
    }
}

