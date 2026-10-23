import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let shortcuts: ShortcutManager
    @AppStorage("includeCursor") private var includeCursor = false
    @AppStorage("windowShadow") private var windowShadow = true
    @AppStorage("freezeScreen") private var freezeScreen = false
    @AppStorage("hideDesktop") private var hideDesktop = false
    @AppStorage("captureDelay") private var delay = 0
    @AppStorage("autoCopy") private var autoCopy = false
    @AppStorage("afterCapture") private var afterCapture = "popup"
    @AppStorage("shelfPosition") private var position = "bottomLeft"
    @AppStorage("shelfAutoDismiss") private var dismiss = 0.0
    @AppStorage("filenameTemplate") private var filename = "Glint {date} at {time}"
    @AppStorage("retentionDays") private var retention = 0
    @AppStorage("captureSound") private var sound = false
    @AppStorage("automationEnabled") private var automation = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        TabView {
            Form {
                Section("Capture") {
                    Toggle("Include cursor", isOn: $includeCursor)
                    Toggle("Window shadow", isOn: $windowShadow)
                    Toggle("Freeze screen while selecting", isOn: $freezeScreen)
                    Toggle("Hide desktop items in captures", isOn: $hideDesktop)
                    Toggle("Play a sound", isOn: $sound)
                    Picker("Timer", selection: $delay) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    Picker("After capture", selection: $afterCapture) {
                        Text("Quick access popup").tag("popup")
                        Text("Open editor").tag("editor")
                        Text("Save as…").tag("save")
                    }
                    Toggle("Also copy to clipboard", isOn: $autoCopy)
                }
                Section("Files") {
                    TextField("Filename", text: $filename)
                    Text("Use {date} and {time} in the filename.").font(.caption).foregroundStyle(.secondary)
                    Picker("Keep history", selection: $retention) {
                        Text("Forever").tag(0)
                        Text("1 day").tag(1)
                        Text("1 week").tag(7)
                        Text("1 month").tag(30)
                    }
                    Text("Expired captures move to Trash. Files saved elsewhere are kept.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Launch at login", isOn: $login)
                        .onChange(of: login) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { Task { do { try await SMAppService.mainApp.unregister() } catch { self.error = error.localizedDescription } } }
                            } catch { self.error = error.localizedDescription; login = false }
                        }
                    Toggle("Allow capture URLs", isOn: $automation)
                    Text("Allows glint:// commands to start captures. Keep off unless you use an automation tool.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Position", selection: $position) {
                    Text("Bottom left").tag("bottomLeft")
                    Text("Bottom right").tag("bottomRight")
                    Text("Top left").tag("topLeft")
                    Text("Top right").tag("topRight")
                }
                Picker("Dismiss", selection: $dismiss) {
                    Text("Manually").tag(0.0)
                    Text("After 10 seconds").tag(10.0)
                    Text("After 30 seconds").tag(30.0)
                    Text("After 1 minute").tag(60.0)
                }
                Text("The popup stays open while your pointer is over it or you’re dragging a capture.")
                    .foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("Popup", systemImage: "rectangle.bottomthird.inset.filled") }

            Form {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action, manager: shortcuts).frame(width: 160) }
                }
                ForEach(shortcuts.errors, id: \.self) { message in Text(message).foregroundStyle(.red).font(.caption) }
            }.formStyle(.grouped).tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 600, height: 590)
        .alert("Couldn’t update settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
