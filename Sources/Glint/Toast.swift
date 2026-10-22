import AppKit
import SwiftUI

// a brief confirmation pill near the bottom of the active screen
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        host.setFrameSize(host.fittingSize)
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = host.fittingSize
        let target = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 72, width: size.width, height: size.height)
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(motion ? target.offsetBy(dx: 0, dy: -10) : target, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } } })
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.glint)
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .padding(12)
    }
}
