import AppKit
import SwiftUI

enum VideoInspectorPanel: String, CaseIterable, Identifiable {
    case background = "Background", zoom = "Zoom", cursor = "Cursor", camera = "Camera", keys = "Keystrokes", audio = "Audio", export = "Export"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .background: return "photo.artframe"
        case .zoom: return "plus.magnifyingglass"
        case .cursor: return "cursorarrow.rays"
        case .camera: return "web.camera"
        case .keys: return "keyboard"
        case .audio: return "speaker.wave.2"
        case .export: return "square.and.arrow.up"
        }
    }

    func isAvailable(in project: VideoProject) -> Bool {
        switch self {
        case .cursor: return !project.cursorSamples.isEmpty
        case .camera: return project.cameraFile != nil
        case .keys: return !project.keystrokes.isEmpty
        default: return true
        }
    }
}

struct VideoInspectorView: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        let panels = VideoInspectorPanel.allCases.filter { $0.isAvailable(in: project) }
        let panel = panels.contains(model.panel) ? model.panel : .background
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(panels) { item in
                    Button { model.panel = item } label: { Image(systemName: item.symbol) }
                        .buttonStyle(ToolButtonStyle(selected: item == panel, size: CGSize(width: 34, height: 30)))
                        .help(item.rawValue)
                        .accessibilityLabel(item.rawValue)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(panel.rawValue).font(.system(size: 15, weight: .semibold)).padding(.leading, 2)
                    content(panel)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func content(_ panel: VideoInspectorPanel) -> some View {
        switch panel {
        case .background: BackgroundPanel(model: model, project: project)
        case .zoom: ZoomPanel(model: model, project: project)
        case .cursor: CursorPanel(model: model, project: project)
        case .camera: CameraPanel(model: model, project: project)
        case .keys: KeysPanel(model: model, project: project)
        case .audio: AudioPanel(model: model, project: project)
        case .export: ExportPanel(model: model, project: project)
        }
    }
}

// MARK: building blocks

private struct InspectorGroup<Content: View>: View {
    var title: String?
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || isOn != nil {
                HStack {
                    if let title { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                    Spacer()
                    if let isOn { Toggle(title ?? "", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                }
                .padding(.horizontal, 4)
            }
            if isOn?.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(enabled ? 0.85 : 0.35)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 12)
    }
}

private struct SwitchRow: View {
    let title: String
    let isOn: Binding<Bool>
    var body: some View {
        Row(title: title) { Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
    }
}

private struct SliderRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }

    var body: some View {
        Row(title: title) {
            Slider(value: value, in: range).controlSize(.small).frame(minWidth: 72, maxWidth: 128)
            Text(format(value.wrappedValue)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
}

private struct SegmentRow<Value: Hashable & Identifiable & RawRepresentable<String>>: View {
    let title: String
    let selection: Binding<Value>
    let options: [Value]
    var symbol: ((Value) -> String)?

    var body: some View {
        Row(title: title) {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    if let symbol { Image(systemName: symbol(option)).help(option.rawValue).tag(option) } else { Text(option.rawValue).tag(option) }
                }
            }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
        }
    }
}

private struct ColorRow: View {
    let title: String
    let model: VideoEditorModel
    let project: VideoProject
    let key: WritableKeyPath<VideoEdits, VideoColor>

    var body: some View {
        Row(title: title) {
            ColorPicker(title, selection: Binding(get: { Color(nsColor: project.edits[keyPath: key].nsColor) }, set: { model.set(key, VideoColor(NSColor($0))) }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

// a miniature frame with a dot for each placement
private struct PlacementPicker<Value: Hashable>: View {
    let options: [(Value, UnitPoint)]
    let selection: Binding<Value>
    var columns = 2
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { rowStart in
                GridRow {
                    ForEach(rowStart..<min(rowStart + columns, options.count), id: \.self) { index in
                        let (value, point) = options[index]
                        let selected = selection.wrappedValue == value
                        Button { selection.wrappedValue = value } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selected ? Color.glint.opacity(0.14) : Color.primary.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(selected ? Color.glint : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1))
                                .overlay(alignment: Alignment(horizontal: point.x < 0.3 ? .leading : point.x > 0.7 ? .trailing : .center, vertical: point.y < 0.5 ? .top : .bottom)) {
                                    RoundedRectangle(cornerRadius: 2).fill(selected ? Color.glint : Color.primary.opacity(0.4)).frame(width: 9, height: 6).padding(4)
                                }
                                .frame(width: 38, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(enabled ? 1 : 0.4)
                    }
                }
            }
        }
    }
}

// MARK: panels

private struct BackgroundPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    private static let presets: [(VideoColor, VideoColor)] = [
        (.blue, .purple),
        (.init(red: 0.05, green: 0.47, blue: 0.53), .init(red: 0.09, green: 0.18, blue: 0.36)),
        (.init(red: 0.98, green: 0.58, blue: 0.36), .init(red: 0.78, green: 0.22, blue: 0.46)),
        (.init(red: 0.58, green: 0.88, blue: 0.76), .init(red: 0.18, green: 0.52, blue: 0.70)),
        (.init(red: 0.96, green: 0.72, blue: 0.80), .init(red: 0.58, green: 0.47, blue: 0.86)),
        (.init(red: 0.95, green: 0.94, blue: 0.92), .init(red: 0.80, green: 0.81, blue: 0.85)),
        (.init(red: 0.24, green: 0.25, blue: 0.29), .init(red: 0.06, green: 0.06, blue: 0.08))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorGroup(title: "Shape") {
                HStack(spacing: 6) {
                    ForEach(VideoAspect.allCases) { aspect in aspectChip(aspect) }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            InspectorGroup(title: "Backdrop", isOn: model.binding(\.showsBackground, fallback: true)) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                    ForEach(Self.presets.indices, id: \.self) { index in swatch(Self.presets[index]) }
                    imageSwatch
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Row(title: "Colors") {
                    HStack(spacing: 6) {
                        ColorPicker("Top", selection: color(\.backgroundTop), supportsOpacity: false).labelsHidden()
                        ColorPicker("Bottom", selection: color(\.backgroundBottom), supportsOpacity: false).labelsHidden()
                    }
                }
                .disabled(project.edits.backgroundFile != nil)
                SliderRow(title: "Padding", value: model.binding(\.padding, fallback: 0), range: 0...200) { "\(Int($0))" }
                SliderRow(title: "Corners", value: model.binding(\.cornerRadius, fallback: 0), range: 0...80) { "\(Int($0))" }
                SliderRow(title: "Shadow", value: model.binding(\.shadow, fallback: 0), range: 0...60) { "\(Int($0))" }
            }
        }
    }

    private func aspectChip(_ aspect: VideoAspect) -> some View {
        let selected = project.edits.aspect == aspect
        let ratio = aspect.ratio ?? Double(project.width) / Double(max(1, project.height))
        let size = ratio >= 1 ? CGSize(width: 24, height: 24 / ratio) : CGSize(width: 24 * ratio, height: 24)
        return Button { model.set(\.aspect, aspect) } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(selected ? Color.glint : Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: aspect == .original ? [2.5, 2] : []))
                    .frame(width: max(10, size.width), height: max(10, size.height))
                    .frame(height: 26)
                Text(aspect.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(selected ? Color.glint : .secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(selected ? Color.glint.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ colors: (VideoColor, VideoColor)) -> some View {
        let selected = project.edits.backgroundFile == nil && project.edits.backgroundTop == colors.0 && project.edits.backgroundBottom == colors.1
        return Button { model.edit { $0.backgroundTop = colors.0; $0.backgroundBottom = colors.1; $0.backgroundFile = nil } } label: {
            Circle()
                .fill(LinearGradient(colors: [Color(nsColor: colors.0.nsColor), Color(nsColor: colors.1.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.glint : .clear, lineWidth: 2))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }

    private var imageSwatch: some View {
        let selected = project.edits.backgroundFile != nil
        return Button { selected ? model.edit { $0.backgroundFile = nil } : model.chooseBackground() } label: {
            Circle()
                .fill(Color.primary.opacity(0.07))
                .overlay(Image(systemName: selected ? "xmark" : "photo").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.glint : .clear, lineWidth: 2))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(selected ? "Remove image" : "Choose image")
    }

    private func color(_ key: WritableKeyPath<VideoEdits, VideoColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: project.edits[keyPath: key].nsColor) }, set: { model.set(key, VideoColor(NSColor($0))) })
    }
}

private struct ZoomPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Button { model.addZoom() } label: { Label("Add", systemImage: "plus") }.buttonStyle(SecondaryButtonStyle())
                Button(action: model.smartZooms) { Label("Auto", systemImage: "wand.and.sparkles") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(project.clicks.isEmpty).help("Zoom on clicks")
            }
            if project.edits.zooms.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 22, weight: .light))
                    Text("No zooms").font(.system(size: 12))
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).frame(height: 96)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                InspectorGroup {
                    ForEach(project.edits.zooms.sorted { $0.start < $1.start }) { zoom in row(zoom) }
                }
            }
            if let zoom = project.edits.zooms.first(where: { $0.id == model.selectedZoom }) {
                InspectorGroup(title: "Selected") {
                    SliderRow(title: "Scale", value: value(zoom, \.scale, 1...4), range: 1...4) { String(format: "%.1f×", $0) }
                    Row(title: "Timing") {
                        field(value(zoom, \.start, 0...max(0, project.duration - 0.1)))
                        Text("for").font(.system(size: 11)).foregroundStyle(.secondary)
                        field(value(zoom, \.duration, 0.1...max(0.1, project.duration - zoom.start)))
                    }
                    SwitchRow(title: "Follow cursor", isOn: Binding(get: { zoom.followsCursor }, set: { value in model.updateZoom(zoom.id) { $0.followsCursor = value } }))
                        .disabled(project.cursorSamples.isEmpty)
                    if !zoom.followsCursor {
                        Row(title: "Center") {
                            Button(model.pickingZoom == zoom.id ? "Cancel" : "Choose") { model.pickingZoom = model.pickingZoom == zoom.id ? nil : zoom.id }
                                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        }
                    }
                    Row(title: "") {
                        Button("Remove", role: .destructive) { model.removeZoom(zoom.id) }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12, weight: .medium))
                    }
                }
            }
            InspectorGroup(title: "Motion") {
                SliderRow(title: "Motion blur", value: model.binding(\.motionBlur, fallback: 0), range: 0...1)
            }
        }
    }

    private func row(_ zoom: VideoZoom) -> some View {
        let selected = model.selectedZoom == zoom.id
        return Button {
            model.selectedZoom = zoom.id
            model.seek(to: project.outputTime(at: zoom.start + min(0.5, zoom.duration / 2)))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: zoom.followsCursor ? "cursorarrow" : "scope").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.zoomLane)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.zoomLane.opacity(selected ? 1 : 0.18)))
                Text(String(format: "%.1f×", zoom.scale)).font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer()
                Text("\(VideoEditorView.clock(zoom.start)) – \(VideoEditorView.clock(zoom.start + zoom.duration))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(selected ? Color.primary.opacity(0.07) : .clear))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder).controlSize(.small).multilineTextAlignment(.trailing).frame(width: 52)
    }

    private func value(_ zoom: VideoZoom, _ key: WritableKeyPath<VideoZoom, Double>, _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { zoom[keyPath: key] }, set: { value in
            guard value.isFinite else { return }
            model.updateZoom(zoom.id) { $0[keyPath: key] = min(range.upperBound, max(range.lowerBound, value)) }
        })
    }
}

private struct CursorPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorGroup(title: "Pointer", isOn: model.binding(\.showsCursor, fallback: true)) {
                SegmentRow(title: "Style", selection: model.binding(\.cursorStyle, fallback: .arrow), options: VideoCursorStyle.allCases)
                SliderRow(title: "Size", value: model.binding(\.cursorScale, fallback: 1), range: 0.5...4) { String(format: "%.1f×", $0) }
                SegmentRow(title: "Movement", selection: model.binding(\.cursorMovement, fallback: .smooth), options: VideoCursorMovement.allCases)
                if project.edits.cursorMovement == .smooth {
                    SliderRow(title: "Smoothing", value: model.binding(\.cursorSmoothing, fallback: 0), range: 0...1)
                }
                SwitchRow(title: "Hide when idle", isOn: model.binding(\.cursorHideWhenStationary, fallback: false))
                SwitchRow(title: "Hide while typing", isOn: model.binding(\.cursorHideWhileTyping, fallback: false))
                    .disabled(project.keystrokes.isEmpty)
                SwitchRow(title: "Press effect", isOn: model.binding(\.cursorPressEffect, fallback: true))
            }
            InspectorGroup(title: "Clicks", isOn: model.binding(\.showsClicks, fallback: true)) {
                ColorRow(title: "Color", model: model, project: project, key: \.clickColor)
                SliderRow(title: "Size", value: model.binding(\.clickSize, fallback: 1), range: 0.25...3) { String(format: "%.1f×", $0) }
                SwitchRow(title: "Filled", isOn: model.binding(\.clickFilled, fallback: false))
                SwitchRow(title: "Animate", isOn: model.binding(\.clickAnimated, fallback: true))
            }
        }
    }
}

private struct CameraPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        InspectorGroup(title: "Overlay", isOn: model.binding(\.showsCamera, fallback: true)) {
            SwitchRow(title: "Full screen", isOn: model.binding(\.cameraFullScreen, fallback: false))
            Group {
                Row(title: "Position") {
                    PlacementPicker(options: [(VideoCameraPosition.topLeft, UnitPoint.topLeading), (.topRight, .topTrailing), (.bottomLeft, .bottomLeading), (.bottomRight, .bottomTrailing)],
                                    selection: model.binding(\.cameraPosition, fallback: .bottomRight))
                }
                .padding(.vertical, 6)
                SegmentRow(title: "Shape", selection: model.binding(\.cameraShape, fallback: .circle), options: VideoCameraShape.allCases) { shape in
                    switch shape {
                    case .circle: return "circle"
                    case .rounded: return "app"
                    case .square: return "square"
                    }
                }
                SliderRow(title: "Size", value: model.binding(\.cameraSize, fallback: 0.2), range: 0.08...0.5)
                SwitchRow(title: "Smaller during zoom", isOn: model.binding(\.cameraSmallerDuringZoom, fallback: false))
            }
            .disabled(project.edits.cameraFullScreen)
            SwitchRow(title: "Mirror", isOn: model.binding(\.cameraMirrored, fallback: true))
        }
    }
}

private struct KeysPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        InspectorGroup(title: "Display", isOn: model.binding(\.showsKeystrokes, fallback: true)) {
            SwitchRow(title: "Shortcuts only", isOn: model.binding(\.keystrokesOnlyShortcuts, fallback: true))
            Row(title: "Position") {
                PlacementPicker(options: [(VideoKeyPosition.topLeft, UnitPoint.topLeading), (.top, .top), (.topRight, .topTrailing),
                                          (.bottomLeft, .bottomLeading), (.bottom, .bottom), (.bottomRight, .bottomTrailing)],
                                selection: model.binding(\.keystrokePosition, fallback: .bottom), columns: 3)
            }
            .padding(.vertical, 6)
            SegmentRow(title: "Style", selection: model.binding(\.keystrokeStyle, fallback: .dark), options: VideoKeyStyle.allCases)
            SliderRow(title: "Size", value: model.binding(\.keystrokeScale, fallback: 1), range: 0.5...2) { String(format: "%.1f×", $0) }
        }
    }
}

private struct AudioPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject

    var body: some View {
        InspectorGroup(title: "Sound", isOn: model.binding(\.audioEnabled, fallback: true)) {
            SliderRow(title: "System", value: model.binding(\.systemVolume, fallback: 1), range: 0...2) { "\(Int(($0 * 100).rounded()))%" }
            if project.microphoneAudioTrackID != nil {
                SliderRow(title: "Microphone", value: model.binding(\.microphoneVolume, fallback: 1), range: 0...2) { "\(Int(($0 * 100).rounded()))%" }
            }
        }
    }
}

private struct ExportPanel: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject
    @State private var customWidth = 1920
    @State private var customHeight = 1080

    var body: some View {
        let size = VideoGeometry.outputSize(for: project)
        VStack(alignment: .leading, spacing: 18) {
            InspectorGroup(title: "Size") {
                Row(title: "Resolution") {
                    Picker("Resolution", selection: resolution) {
                        ForEach([1280, 1920, 2560, 3840], id: \.self) { Text("\(String($0)) px").tag($0) }
                        Divider()
                        Text("Custom").tag(0)
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
                if project.edits.customWidth != nil {
                    Row(title: "Pixels") {
                        HStack(spacing: 4) {
                            TextField("Width", value: $customWidth, format: .number.grouping(.never)).frame(width: 52)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Height", value: $customHeight, format: .number.grouping(.never)).frame(width: 52)
                        }
                        .textFieldStyle(.roundedBorder).controlSize(.small).multilineTextAlignment(.trailing)
                        .onSubmit(applyCustomSize)
                        Button("Apply", action: applyCustomSize).buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    }
                } else {
                    Row(title: "Output") {
                        Text("\(String(Int(size.width))) × \(String(Int(size.height)))").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            InspectorGroup(title: "Video") {
                SliderRow(title: "Quality", value: model.binding(\.exportQuality, fallback: 0.85), range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                Row(title: "Estimated size") {
                    Text(ByteCountFormatter.string(fromByteCount: VideoExporter.estimatedSize(project: project), countStyle: .file))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            InspectorGroup(title: "GIF") {
                Row(title: "Frame rate") {
                    Picker("Frame rate", selection: $model.gifFrameRate) {
                        ForEach(Array(Set([5, 10, 15, 20, 25, 30, 50, min(50, project.frameRate)])).filter { $0 <= project.frameRate }.sorted(), id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
            }
        }
        .onAppear {
            customWidth = project.edits.customWidth ?? Int(size.width)
            customHeight = project.edits.customHeight ?? Int(size.height)
        }
    }

    private var resolution: Binding<Int> {
        Binding(get: { project.edits.customWidth == nil ? project.edits.maximumDimension : 0 }, set: { value in
            if value == 0 {
                let size = VideoGeometry.outputSize(for: project)
                customWidth = Int(size.width); customHeight = Int(size.height)
                model.edit { $0.customWidth = customWidth; $0.customHeight = customHeight }
            } else {
                model.edit { $0.maximumDimension = value; $0.customWidth = nil; $0.customHeight = nil }
            }
        })
    }

    private func applyCustomSize() {
        guard (64...7680).contains(customWidth), (64...7680).contains(customHeight) else {
            model.errorMessage = "Choose a width and height between 64 and 7680 pixels."
            return
        }
        customWidth = customWidth / 2 * 2; customHeight = customHeight / 2 * 2
        model.edit { $0.customWidth = customWidth; $0.customHeight = customHeight }
    }
}
