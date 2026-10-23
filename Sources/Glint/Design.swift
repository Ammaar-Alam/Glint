import AppKit
import SwiftUI

extension NSColor {
    // bright cyan on dark surfaces, deeper teal on light ones so contrast holds
    static let glint = NSColor(name: "glint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.89, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.58, blue: 0.65, alpha: 1)
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
}

extension Color {
    static let glint = Color(nsColor: .glint)
    static let onGlint = Color(nsColor: .onGlint)
    static let groupFill = Color(nsColor: .groupFill)
}

enum Radius {
    static let control: CGFloat = 7
    static let card: CGFloat = 12
    static let panel: CGFloat = 16
}

// icon-only toolbar button: quiet at rest, tinted when selected
struct ToolButtonStyle: ButtonStyle {
    var selected = false
    var size = CGSize(width: 30, height: 28)

    func makeBody(configuration: Configuration) -> some View {
        ToolButtonLabel(configuration: configuration, selected: selected, size: size)
    }
}

private struct ToolButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let size: CGSize
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(width: size.width, height: size.height)
            .foregroundStyle(selected ? Color.glint : Color.primary.opacity(enabled ? 0.85 : 0.3))
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? Color.glint.opacity(0.16) : Color.primary.opacity(hovering && enabled ? 0.08 : 0))
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
