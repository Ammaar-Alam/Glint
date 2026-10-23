import AppKit
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, screenshots, recording, popup, editor, shortcuts, about
    var id: Self { self }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .screenshots: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .popup: return "rectangle.on.rectangle"
        case .editor: return "pencil.tip.crop.circle"
        case .shortcuts: return "command"
        case .about: return "info"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .screenshots: return .blue
        case .recording: return .red
        case .popup: return .indigo
        case .editor: return .orange
        case .shortcuts: return Color(nsColor: .systemGray)
        case .about: return .glint
        }
    }

    // sidebar sections, separated like System Settings
    static let sections: [[SettingsPane]] = [[.general], [.screenshots, .recording, .popup, .editor], [.shortcuts, .about]]
}

struct SettingsView: View {
    let shortcuts: ShortcutManager
    @State var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(SettingsPane.sections, id: \.self) { section in
                    Section {
                        ForEach(section) { pane in
                            Label { Text(pane.title) } icon: { IconBadge(symbol: pane.symbol, color: pane.color) }
                                .tag(pane)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let current = pane ?? .general
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if current != .about {
                        Text(current.title).font(.system(size: 20, weight: .semibold))
                    }
                    switch current {
                    case .general: GeneralPane()
                    case .screenshots: ScreenshotsPane()
                    case .recording: RecordingPane()
                    case .popup: PopupPane()
                    case .editor: EditorPane()
                    case .shortcuts: ShortcutsPane(shortcuts: shortcuts)
                    case .about: AboutPane()
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.glint)
        .frame(minWidth: 720, minHeight: 520)
    }
}

// the white-on-color squircle used for each pane
private struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

// MARK: building blocks

private struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Divider().padding(.horizontal, 12) }
                        rows[index]
                    }
                }
            }
            .background(Color.groupFill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

private struct ToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, caption: caption) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

private struct MenuRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        SettingsRow(title) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

// the after-capture choices as a row of toggle tiles
private struct ActionTiles: View {
    let recording: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CaptureAction.allCases) { ActionTile(action: $0, recording: recording) }
        }
        .padding(10)
    }
}

private struct ActionTile: View {
    let action: CaptureAction
    @AppStorage private var isOn: Bool
    @State private var hovering = false

    init(action: CaptureAction, recording: Bool) {
        self.action = action
        _isOn = AppStorage(wrappedValue: false, CaptureAction.key(action, recording: recording))
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 7) {
                Image(systemName: action.symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                Text(action.title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.glint : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
                    .fill(isOn ? Color.glint.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
                    .strokeBorder(isOn ? Color.glint.opacity(0.55) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

// MARK: panes

private struct GeneralPane: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("captureSound") private var sound = false
    @AppStorage("automationEnabled") private var automation = false
    @AppStorage("saveFolder") private var folder = ""
    @AppStorage("filenameTemplate") private var filename = "Glint {date} at {time}"
    @AppStorage("retentionDays") private var retention = 0
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    private static let choose = "\u{0}choose"
    private static let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
    private static let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].path

    var body: some View {
        SettingsGroup {
            ToggleRow("Launch at login", isOn: $login)
                .onChange(of: login) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { Task { do { try await SMAppService.mainApp.unregister() } catch { self.error = error.localizedDescription } } }
                    } catch { self.error = error.localizedDescription; login = false }
                }
            ToggleRow("Show menu bar icon", caption: showMenuBarIcon ? nil : "Open Glint again to get back here.", isOn: $showMenuBarIcon)
            ToggleRow("Play sounds", isOn: $sound)
        }
        SettingsGroup(title: "Files") {
            SettingsRow("Save to") {
                Picker("Save to", selection: Binding(get: { folder }, set: { $0 == Self.choose ? chooseFolder() : (folder = $0) })) {
                    Text("Ask Every Time").tag("")
                    Divider()
                    Text("Desktop").tag(Self.desktop)
                    Text("Pictures").tag(Self.pictures)
                    if ![Self.desktop, Self.pictures, ""].contains(folder) {
                        Text(URL(fileURLWithPath: folder).lastPathComponent).tag(folder)
                    }
                    Divider()
                    Text("Choose…").tag(Self.choose)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("File name", caption: "Use {date} and {time}") {
                TextField("File name", text: $filename).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 210)
            }
            MenuRow("Keep history", selection: $retention, options: [("Forever", 0), ("1 Day", 1), ("1 Week", 7), ("1 Month", 30)])
        }
        SettingsGroup(title: "Automation") {
            ToggleRow("Allow capture URLs", caption: "Lets other apps start captures with glint:// links.", isOn: $automation)
        }
        .alert("Couldn’t update settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        panel.begin { response in
            if response == .OK, let url = panel.url { folder = url.path }
        }
    }
}

private struct ScreenshotsPane: View {
    @AppStorage("includeCursor") private var includeCursor = false
    @AppStorage("windowShadow") private var windowShadow = true
    @AppStorage("freezeScreen") private var freezeScreen = false
    @AppStorage("hideDesktop") private var hideDesktop = false
    @AppStorage("showMagnifier") private var magnifier = true
    @AppStorage("captureDelay") private var delay = 0
    @AppStorage("screenshotFormat") private var format = ScreenshotFormat.png.rawValue

    var body: some View {
        SettingsGroup(title: "After capture") {
            ActionTiles(recording: false)
            SettingsRow("Save as") {
                Picker("Save as", selection: $format) {
                    ForEach(ScreenshotFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        SettingsGroup(title: "Capture") {
            MenuRow("Timer", selection: $delay, options: [("Off", 0), ("3 Seconds", 3), ("5 Seconds", 5), ("10 Seconds", 10)])
            ToggleRow("Show magnifier", isOn: $magnifier)
            ToggleRow("Freeze screen while selecting", isOn: $freezeScreen)
            ToggleRow("Include cursor", isOn: $includeCursor)
            ToggleRow("Window shadow", isOn: $windowShadow)
            ToggleRow("Hide desktop icons", isOn: $hideDesktop)
        }
    }
}

private struct RecordingPane: View {
    @AppStorage("record.countdown") private var countdown = 3
    @AppStorage("record.fps") private var fps = 30
    @AppStorage("record.size") private var size = 2560
    @AppStorage("record.systemAudio") private var systemAudio = true
    @AppStorage("record.microphone") private var microphone = false
    @AppStorage("record.camera") private var camera = false
    @AppStorage("record.cursor") private var cursor = true
    @AppStorage("record.clicks") private var clicks = true
    @AppStorage("record.keys") private var keys = false
    @AppStorage("record.shortcutsOnly") private var shortcutsOnly = true
    @AppStorage("record.hideDesktop") private var hideDesktop = false

    var body: some View {
        SettingsGroup(title: "After recording") {
            ActionTiles(recording: true)
        }
        SettingsGroup(title: "Video") {
            MenuRow("Countdown", selection: $countdown, options: [("None", 0), ("3 Seconds", 3), ("5 Seconds", 5), ("10 Seconds", 10)])
            MenuRow("Frame rate", selection: $fps, options: [("24 fps", 24), ("30 fps", 30), ("60 fps", 60)])
            MenuRow("Resolution", selection: $size, options: [("1080p", 1920), ("1440p", 2560), ("4K", 3840)])
            ToggleRow("Hide desktop icons", isOn: $hideDesktop)
        }
        SettingsGroup(title: "Audio and camera") {
            ToggleRow("System audio", isOn: $systemAudio)
            ToggleRow("Microphone", isOn: $microphone)
            ToggleRow("Camera", isOn: $camera)
        }
        SettingsGroup(title: "Pointer and keys") {
            ToggleRow("Show cursor", isOn: $cursor)
            ToggleRow("Highlight clicks", isOn: $clicks)
            ToggleRow("Record keys", caption: keys ? "Typed keys are stored in the project. Keep off for sensitive work." : nil, isOn: $keys)
            if keys { ToggleRow("Shortcuts only", isOn: $shortcutsOnly) }
        }
        .onAppear(perform: Self.seedDefaults)
    }

    // the recorder ignores saved options until a full set exists, so fill in its defaults first
    static func seedDefaults() {
        let options = RecordingOptions()
        let values: [String: Any] = [
            "record.mode": options.mode.rawValue, "record.countdown": options.countdown, "record.fps": options.framesPerSecond,
            "record.size": options.maximumDimension, "record.systemAudio": options.capturesSystemAudio,
            "record.microphone": options.capturesMicrophone, "record.camera": options.capturesCamera,
            "record.cursor": options.showsCursor, "record.hideDesktop": options.hideDesktop, "record.clicks": options.showsClicks,
            "record.keys": options.showsKeystrokes, "record.shortcutsOnly": options.keystrokesOnlyShortcuts
        ]
        for (key, value) in values where UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

private struct PopupPane: View {
    @AppStorage("shelfPosition") private var position = "bottomLeft"
    @AppStorage("shelfScale") private var scale = 1.0
    @AppStorage("shelfAutoDismiss") private var dismiss = 0.0
    @AppStorage("shelfCloseAfterDrag") private var closeAfterDrag = false
    @AppStorage("shelfFollowsPointer") private var followsPointer = true

    var body: some View {
        SettingsGroup {
            PopupPreview(position: $position, scale: scale).padding(14)
            SettingsRow("Size") {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    Slider(value: $scale, in: 0.75...1.5).frame(width: 170).labelsHidden()
                    Image(systemName: "rectangle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            MenuRow("Show on", selection: $followsPointer, options: [("Display with Pointer", true), ("Main Display", false)])
        }
        SettingsGroup(title: "Closing") {
            MenuRow("Close after", selection: $dismiss, options: [("Never", 0), ("5 Seconds", 5), ("10 Seconds", 10), ("30 Seconds", 30), ("1 Minute", 60)])
            ToggleRow("Close after dragging out", isOn: $closeAfterDrag)
        }
    }
}

// a small screen with the popup at its corner and size, click a corner to move it
private struct PopupPreview: View {
    @Binding var position: String
    let scale: Double
    @Environment(\.colorScheme) private var scheme
    private static let corners: [(id: String, name: String, alignment: Alignment)] = [
        ("topLeft", "Top left", .topLeading), ("topRight", "Top right", .topTrailing),
        ("bottomLeft", "Bottom left", .bottomLeading), ("bottomRight", "Bottom right", .bottomTrailing)
    ]
    // the preview screen stands in for a 1280 point wide display
    private static let screen = CGSize(width: 320, height: 200)
    private var card: CGSize {
        let ratio = Self.screen.width / 1280 * CGFloat(scale)
        return CGSize(width: QuickAccessPanel.baseCardSize.width * ratio, height: QuickAccessPanel.baseCardSize.height * ratio)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(red: 0.13, green: 0.16, blue: 0.27), Color(red: 0.22, green: 0.15, blue: 0.30)]
                                                   : [Color(red: 0.72, green: 0.80, blue: 0.93), Color(red: 0.86, green: 0.78, blue: 0.90)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack {
                Rectangle().fill(.white.opacity(scheme == .dark ? 0.08 : 0.35)).frame(height: 8)
                Spacer()
            }
            ForEach(Self.corners, id: \.id) { corner in
                let selected = corner.id == position
                Button { withAnimation(.easeOut(duration: 0.2)) { position = corner.id } } label: {
                    ZStack(alignment: corner.id.hasPrefix("top") ? .top : .bottom) {
                        if selected {
                            // an older capture peeks out behind the newest one
                            MiniCard(size: card).scaleEffect(0.92).offset(y: corner.id.hasPrefix("top") ? card.height + 4 : -(card.height + 4)).opacity(0.6)
                            MiniCard(size: card)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: card.width, height: card.height)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 6, bottom: 6, trailing: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(corner.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            }
        }
        .frame(width: Self.screen.width, height: Self.screen.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: scale)
    }
}

private struct MiniCard: View {
    let size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: max(3, size.height * 0.1), style: .continuous)
            .fill(.white)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: size.height * 0.1) {
                    Capsule().fill(Color.glint.opacity(0.7)).frame(width: size.width * 0.35, height: size.height * 0.1)
                    Capsule().fill(.black.opacity(0.12)).frame(width: size.width * 0.7, height: size.height * 0.08)
                    Capsule().fill(.black.opacity(0.12)).frame(width: size.width * 0.5, height: size.height * 0.08)
                }
                .padding(size.height * 0.16)
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

private struct EditorPane: View {
    @AppStorage("annotationColor") private var colorData = Data()
    @AppStorage("annotationLineWidth") private var lineWidth = 5.0
    @AppStorage("defaultBackgroundPreset") private var presetData = Data()
    private let presets = EditorDefaults.backgroundPresets
    private static let swatches: [AnnotationColor] = [
        .coral, AnnotationColor(red: 1, green: 0.62, blue: 0.04), AnnotationColor(red: 1, green: 0.84, blue: 0.04),
        AnnotationColor(red: 0.2, green: 0.78, blue: 0.35), AnnotationColor(red: 0.04, green: 0.52, blue: 1),
        AnnotationColor(red: 0.69, green: 0.32, blue: 0.87), .ink, .white
    ]

    private var color: AnnotationColor {
        (try? JSONDecoder().decode(AnnotationColor.self, from: colorData)).flatMap { $0.isValid ? $0 : nil } ?? .coral
    }
    private var preset: ImageBackground? {
        (try? JSONDecoder().decode(ImageBackground.self, from: presetData)).flatMap { presets.contains($0) ? $0 : nil }
    }

    var body: some View {
        SettingsGroup {
            AnnotationPreview(color: color, lineWidth: lineWidth, background: preset).padding(14)
        }
        SettingsGroup(title: "Annotations") {
            SettingsRow("Color") {
                HStack(spacing: 7) {
                    ForEach(Self.swatches.indices, id: \.self) { index in
                        let swatch = Self.swatches[index]
                        Button { setColor(swatch) } label: { Swatch(color: swatch, selected: swatch == color) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color \(index + 1)")
                    }
                    ColorPicker("Custom color", selection: Binding(get: { Color(nsColor: color.nsColor) }, set: { setColor(AnnotationColor(NSColor($0))) }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            SettingsRow("Stroke") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { lineWidth }, set: { lineWidth = $0.rounded() }), in: EditorDefaults.lineWidthRange).frame(width: 170).labelsHidden()
                    Text("\(Int(lineWidth)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
        }
        SettingsGroup(title: "Background") {
            if presets.isEmpty {
                SettingsRow("Default style", caption: "Save a style in the editor to use it for new screenshots.") { EmptyView() }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Default style").padding(.horizontal, 12)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            PresetTile(preset: nil, selected: preset == nil) { presetData = Data() }
                            ForEach(presets.indices, id: \.self) { index in
                                PresetTile(preset: presets[index], selected: preset == presets[index]) {
                                    presetData = (try? JSONEncoder().encode(presets[index])) ?? Data()
                                }
                                .accessibilityLabel("Style \(index + 1)")
                            }
                        }
                        .padding(.horizontal, 9)
                    }
                    .scrollIndicators(.never)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func setColor(_ value: AnnotationColor) {
        colorData = (try? JSONEncoder().encode(value)) ?? Data()
    }
}

private struct Swatch: View {
    let color: AnnotationColor
    let selected: Bool

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .frame(width: 18, height: 18)
            .padding(2.5)
            .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(Circle())
    }
}

private struct BackgroundFill: View {
    let background: ImageBackground

    var body: some View {
        if let id = background.imageID, let image = NSImage(contentsOf: ImageEditorModel.presetDirectory.appendingPathComponent("\(id.uuidString).png")) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if background.gradient {
            LinearGradient(colors: [Color(nsColor: background.color.nsColor), Color(nsColor: background.secondColor.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color(nsColor: background.color.nsColor)
        }
    }
}

private struct PresetTile: View {
    let preset: ImageBackground?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let preset {
                    BackgroundFill(background: preset)
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.white.opacity(0.92)).padding(10).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                } else {
                    Color.primary.opacity(0.05)
                    Image(systemName: "nosign").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: Radius.control + 3, style: .continuous).strokeBorder(selected ? Color.glint : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset == nil ? "None" : "Style")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// a sample capture marked up with the current defaults
private struct AnnotationPreview: View {
    let color: AnnotationColor
    let lineWidth: Double
    let background: ImageBackground?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let background { BackgroundFill(background: background) } else { Color.primary.opacity(0.04) }
            SampleWindow()
                .overlay { Markup(color: Color(nsColor: color.nsColor), width: max(1, lineWidth * 0.5)) }
                .padding(background == nil ? 18 : 30)
                .shadow(color: .black.opacity(background == nil ? 0.08 : 0.22), radius: background == nil ? 3 : 8, y: 2)
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .animation(.easeOut(duration: 0.15), value: background)
    }
}

private struct SampleWindow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = scheme == .dark ? Color.white : Color.black
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 6, height: 6)
                }
            }
            .padding(8)
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(ink.opacity(0.22)).frame(width: 110, height: 7)
                Capsule().fill(ink.opacity(0.1)).frame(width: 190, height: 5)
                Capsule().fill(ink.opacity(0.1)).frame(width: 160, height: 5)
                Capsule().fill(ink.opacity(0.1)).frame(width: 175, height: 5)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme == .dark ? Color(white: 0.17) : .white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct Markup: View {
    let color: Color
    let width: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let box = CGRect(x: size.width * 0.58, y: size.height * 0.42, width: size.width * 0.3, height: size.height * 0.34)
            let start = CGPoint(x: size.width * 0.3, y: size.height * 0.8)
            let end = CGPoint(x: box.minX - 6, y: box.midY + 4)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = 7 + width * 1.6
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(color, lineWidth: width)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                Path { path in
                    path.move(to: start)
                    path.addLine(to: CGPoint(x: end.x - cos(angle) * head * 0.6, y: end.y - sin(angle) * head * 0.6))
                }
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                Path { path in
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
                    path.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
                    path.closeSubpath()
                }
                .fill(color)
            }
        }
        .animation(.easeOut(duration: 0.12), value: width)
    }
}

private struct ShortcutsPane: View {
    let shortcuts: ShortcutManager
    private static let capture: [ShortcutAction] = [.allInOne, .area, .fullScreen, .window, .previousArea, .scrolling, .text]

    var body: some View {
        SettingsGroup(title: "Capture") {
            ForEach(Self.capture) { row($0) }
        }
        SettingsGroup(title: "Recording and windows") {
            ForEach(ShortcutAction.allCases.filter { !Self.capture.contains($0) }) { row($0) }
        }
        ForEach(shortcuts.errors, id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        SettingsRow(action.title) { ShortcutRecorder(action: action, manager: shortcuts).frame(width: 150) }
    }
}

private struct AboutPane: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("Glint").font(.system(size: 26, weight: .semibold)).padding(.top, 4)
            if !version.isEmpty { Text("Version \(version)").foregroundStyle(.secondary) }
            Text("Free and open source.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/Ammaar-Alam/Glint")!) { Text("GitHub") }
                    .buttonStyle(SecondaryButtonStyle())
                if let license = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
                    Button("License") { NSWorkspace.shared.open(license) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}
