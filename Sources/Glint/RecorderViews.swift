import AppKit
import AVFoundation
import SwiftUI

// what goes into a recording as one row of small switches, each named on hover
struct RecordingBarControls: View {
    @Binding var options: RecordingOptions

    var body: some View {
        HStack(spacing: 2) {
            toggle("System Audio", on: "speaker.wave.2.fill", off: "speaker.slash", isOn: $options.capturesSystemAudio)
            toggle("Microphone", on: "mic.fill", off: "mic.slash", isOn: $options.capturesMicrophone)
                .contextMenu { devices(Self.microphones, selection: \.microphoneDeviceID, enabled: \.capturesMicrophone) }
            toggle("Camera", on: "video.fill", off: "video.slash", isOn: $options.capturesCamera)
                .contextMenu { devices(Self.cameras, selection: \.cameraDeviceID, enabled: \.capturesCamera) }
            BarDivider()
            toggle("Cursor", on: "cursorarrow", off: "cursorarrow.slash", isOn: $options.showsCursor)
            toggle("Highlight Clicks", on: "cursorarrow.click.2", off: "cursorarrow.click", isOn: $options.showsClicks)
            toggle("Keystrokes", on: "keyboard.fill", off: "keyboard", isOn: $options.showsKeystrokes)
                .contextMenu { Toggle("Only Shortcuts", isOn: $options.keystrokesOnlyShortcuts) }
            BarDivider()
            toggle("Hide Desktop Icons", on: "eye.slash", off: "eye", isOn: $options.hideDesktop)
        }
    }

    private func toggle(_ title: String, on: String, off: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: isOn.wrappedValue ? on : off)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? Color.glint : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ToolButtonStyle(selected: isOn.wrappedValue, size: CGSize(width: 32, height: 28)))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    // right click picks the device, choosing one also turns the input on
    @ViewBuilder
    private func devices(_ list: [AVCaptureDevice], selection: WritableKeyPath<RecordingOptions, String?>, enabled: WritableKeyPath<RecordingOptions, Bool>) -> some View {
        ForEach([nil] + list.map(Optional.some), id: \.?.uniqueID) { device in
            Button {
                options[keyPath: selection] = device?.uniqueID
                options[keyPath: enabled] = true
            } label: {
                if options[keyPath: selection] == device?.uniqueID { Label(device?.localizedName ?? "System Default", systemImage: "checkmark") }
                else { Text(device?.localizedName ?? "System Default") }
            }
        }
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
        .background { Capsule().fill(Color.white).shadow(color: .black.opacity(0.2), radius: 12, y: 3) }
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
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

// the recorded area stays lit with an outline while the rest dims
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
                // everything outside the recording stays dimmed, a little deeper while counting down
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(hole)
                }
                .fill(Color.black.opacity(area == nil ? 0 : counting ? 0.4 : 0.25), style: FillStyle(eoFill: true))
                if area != nil {
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(width: hole.width + 3, height: hole.height + 3)
                        .position(x: hole.midX, y: hole.midY)
                }
            }
            .animation(.easeOut(duration: 0.3), value: recorder.countdownRemaining)
        }
        .ignoresSafeArea()
    }
}

