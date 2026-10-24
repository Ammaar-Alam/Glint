import AppKit
import SwiftUI

extension NSColor {
    // bright cyan on dark surfaces, deeper teal on light ones so contrast holds
    static let glint = NSColor(name: "glint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.89, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.58, blue: 0.65, alpha: 1)
    }

    // neutral surface behind a document being edited
    static let backdrop = NSColor(name: "backdrop") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.105, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.93, blue: 0.94, alpha: 1)
    }

    // text and glyphs placed on a glint fill
    static let onGlint = NSColor(name: "onGlint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.02, green: 0.13, blue: 0.15, alpha: 1)
            : .white
    }

    // grouped rows sitting on the window background
    static let groupFill = NSColor(name: "groupFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035)
    }

    // a control lifted off a recessed track
    static let raisedControl = NSColor(name: "raisedControl") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : .white
    }
}

extension Color {
    static let glint = Color(nsColor: .glint)
    static let onGlint = Color(nsColor: .onGlint)
    static let groupFill = Color(nsColor: .groupFill)
    static let backdrop = Color(nsColor: .backdrop)
}

enum Radius {
    static let control: CGFloat = 7
    static let card: CGFloat = 12
    static let panel: CGFloat = 16
}

// icon-only toolbar button: quiet at rest, tinted when selected
// a primary tint suits on/off toggles so the accent stays with the active tool
struct ToolButtonStyle: ButtonStyle {
    var selected = false
    var size = CGSize(width: 30, height: 28)
    var tint = Color.glint
    // a solid fill for the one active tool in a strip
    var prominent = false
    // the strip draws one sliding fill itself
    var drawsSelection = true

    func makeBody(configuration: Configuration) -> some View {
        ToolButtonLabel(configuration: configuration, selected: selected, size: size, tint: tint, prominent: prominent, drawsSelection: drawsSelection)
    }
}

private struct ToolButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let size: CGSize
    let tint: Color
    let prominent: Bool
    let drawsSelection: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            // a zero width lets a labeled button size to its content
            .frame(width: size.width > 0 ? size.width : nil, height: size.height)
            .foregroundStyle(selected ? (prominent ? Color.white : tint) : Color.primary.opacity(enabled ? 0.85 : 0.3))
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? (drawsSelection ? (prominent ? tint : tint.opacity(hovering ? 0.2 : 0.14)) : .clear) : Color.primary.opacity(hovering && enabled ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

// the one prominent action on a surface
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.onGlint)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(Color.glint.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

// secondary text action next to a primary one
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .contentShape(Capsule())
    }
}

// a floating group of controls over content, like the zoom controls on a canvas
struct Island<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: Radius.control + 4, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.control + 4, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
    }
}

// a color swatch that opens the color picker, a rainbow when there is no single color
struct ColorWellButton: View {
    let color: NSColor?
    let onChange: (NSColor) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Circle()
                .fill(color.map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Colors")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPickerPanel(color: color ?? .systemRed, onChange: onChange).padding(14)
        }
    }
}

struct ColorDot: View {
    let color: NSColor
    let selected: Bool
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                .frame(width: size, height: size)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.85) : .clear, lineWidth: 1.5))
                .scaleEffect(selected ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
                .frame(width: size + 10, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// the last colors picked from the wheel, shared by every picker
@MainActor
enum RecentColors {
    private static let key = "recentColors"
    private static let limit = 8

    static var all: [NSColor] {
        (UserDefaults.standard.array(forKey: key) as? [[Double]] ?? []).compactMap { rgb in
            rgb.count == 3 ? NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1) : nil
        }
    }

    static func add(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let entry = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { (Double($0) * 255).rounded() / 255 }
        let kept = (UserDefaults.standard.array(forKey: key) as? [[Double]] ?? []).filter { $0 != entry }
        UserDefaults.standard.set(Array(([entry] + kept).prefix(limit)), forKey: key)
    }
}

// recent colors, a hue and saturation wheel and a brightness bar, all in place
struct ColorPickerPanel: View {
    let color: NSColor
    let onChange: (NSColor) -> Void
    var onEditing: (Bool) -> Void = { _ in }
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 1
    @State private var brightness: CGFloat = 1
    @State private var editing = false
    @State private var recents: [NSColor] = []

    private static let wheel: CGFloat = 148
    private var current: NSColor { NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !recents.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.offset) { _, recent in
                        ColorDot(color: recent, selected: false, size: 14) { load(recent); onChange(recent); RecentColors.add(recent) }
                    }
                }
                .padding(.horizontal, -4)
            }
            ZStack {
                Circle().fill(AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: Self.wheel / 2))
                Circle().fill(Color.black.opacity(1 - brightness))
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                Circle()
                    .fill(Color(nsColor: current))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: cos(hue * 2 * .pi) * saturation * Self.wheel / 2, y: sin(hue * 2 * .pi) * saturation * Self.wheel / 2)
            }
            .frame(width: Self.wheel, height: Self.wheel)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - Self.wheel / 2, dy = value.location.y - Self.wheel / 2
                let angle = atan2(dy, dx) / (2 * .pi)
                hue = angle < 0 ? angle + 1 : angle
                saturation = min(1, hypot(dx, dy) / (Self.wheel / 2))
                changed()
            }.onEnded { _ in ended() })
            .frame(maxWidth: .infinity)
            GeometryReader { proxy in
                Capsule()
                    .fill(LinearGradient(colors: [.black, Color(nsColor: NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1))], startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(Color(nsColor: current))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .offset(x: brightness * (proxy.size.width - 16))
                    }
                    .contentShape(Capsule())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        brightness = min(1, max(0, (value.location.x - 8) / (proxy.size.width - 16)))
                        changed()
                    }.onEnded { _ in ended() })
            }
            .frame(height: 16)
        }
        .frame(width: Self.wheel + 8)
        .onAppear { load(color); recents = RecentColors.all }
        .onChange(of: color) { _, value in if !editing { load(value) } }
    }

    private func load(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        // grays keep the hue the wheel last showed
        if rgb.saturationComponent > 0.001 { hue = rgb.hueComponent }
        saturation = rgb.saturationComponent
        brightness = rgb.brightnessComponent
    }

    private func changed() {
        if !editing { editing = true; onEditing(true) }
        onChange(current)
    }

    private func ended() {
        editing = false
        onEditing(false)
        RecentColors.add(current)
        recents = RecentColors.all
    }
}

// solid buttons over a dimmed capture, matching the popup card actions
struct HUDButtonStyle: ButtonStyle {
    var primary = false
    var icon = false

    func makeBody(configuration: Configuration) -> some View {
        HUDButtonLabel(configuration: configuration, primary: primary, icon: icon)
            .environment(\.colorScheme, .dark)
    }
}

private struct HUDButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let primary: Bool
    let icon: Bool
    @State private var hovering = false

    var body: some View {
        let fill = primary ? Color.glint : Color(white: 0.97)
        configuration.label
            .font(.system(size: icon ? 14 : 13, weight: icon ? .heavy : .semibold))
            .labelStyle(.iconOnly)
            .foregroundStyle(primary ? Color.onGlint : Color(white: 0.1))
            .padding(.horizontal, icon ? 0 : 16)
            .frame(minWidth: icon ? 28 : 88, minHeight: icon ? 28 : 30)
            .background(Capsule().fill(hovering ? fill.mix(with: .white, by: 0.18) : fill.opacity(0.94)))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { hovering = $0 }
    }
}

// one key of a shortcut
struct Keycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
    }
}

// capsule segmented control with a sliding selection
struct CapsulePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selection = option } } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(Color(nsColor: .raisedControl))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// thin vertical rule between groups in a bar
struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 5)
    }
}

// exclusive choices in a quiet track, pair with ToolButtonStyle(selected:size:tint: .primary) at 24 high
struct Segmented<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// tool button that opens a native menu, keeping the bar's hover and sizing
struct MenuButton<Label: View>: View {
    let help: String
    var width: CGFloat = 30
    let items: () -> [NSMenuItem]
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            let menu = NSMenu()
            menu.autoenablesItems = false
            items().forEach(menu.addItem)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: { label }
            .buttonStyle(ToolButtonStyle(size: CGSize(width: width, height: 28)))
            .help(help)
            .accessibilityLabel(help)
    }
}

// floating panels take the first click without the app being frontmost
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// a flat switch in the glint accent, replaces the native one everywhere
struct FlatToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Color.glint : Color.primary.opacity(0.14))
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: ""))
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// a flat menu button showing the current choice, checkmarks come from an inline picker inside
struct FlatMenu<Content: View>: View {
    let title: String
    var symbol: String? = nil
    // reads as plain text until hovered, for values that sit beside a primary action
    var quiet = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                Text(title).font(.system(size: quiet ? 12 : 13, weight: quiet ? .medium : .regular))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, quiet ? 8 : 10)
            .frame(height: 26)
            .background(Color.primary.opacity(quiet ? (hovering ? 0.06 : 0) : 0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

// a choice from a short list as a flat menu
struct FlatPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(String, Value)]
    var symbol: String? = nil
    var quiet = false

    var body: some View {
        FlatMenu(title: options.first { $0.1 == selection }?.0 ?? "", symbol: symbol, quiet: quiet) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

struct FlatTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

// content under a full-size title bar must not drag the window, a bar's empty background does that instead
final class StaticHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
