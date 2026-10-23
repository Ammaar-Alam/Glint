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

    func makeBody(configuration: Configuration) -> some View {
        ToolButtonLabel(configuration: configuration, selected: selected, size: size, tint: tint)
    }
}

private struct ToolButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let size: CGSize
    let tint: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(width: size.width, height: size.height)
            .foregroundStyle(selected ? tint : Color.primary.opacity(enabled ? 0.85 : 0.3))
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? tint.opacity(hovering ? 0.2 : 0.14) : Color.primary.opacity(hovering && enabled ? 0.08 : 0))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control + 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control + 4, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

// a color swatch that edits through the system color panel, a rainbow when there is no single color
struct ColorWellButton: View {
    let color: NSColor?
    let onChange: (NSColor) -> Void

    var body: some View {
        Button { ColorPanelBridge.shared.open(color ?? .systemRed, onChange: onChange) } label: {
            Circle()
                .fill(color.map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Colors")
    }
}

@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(_ color: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.showsAlpha = false
        panel.color = color
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { onChange?(panel.color) }
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
            .font(.system(size: icon ? 12 : 13, weight: .semibold))
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
