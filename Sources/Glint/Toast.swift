import AppKit
import SwiftUI

// a brief confirmation pill near the bottom of the active screen
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ title: String, detail: String? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ToastView(title: title, detail: detail))
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

// a white pill with a check that draws itself and one glint passing over, outcome first and place second
private struct ToastView: View {
    let title: String
    let detail: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var sheen = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.glint)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .symbolEffect(.drawOn, isActive: !shown)
            }
            .frame(width: 18, height: 18)
            .scaleEffect(shown ? 1 : 0.6)
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.12))
                if let detail { Text("·  \(detail)").font(.system(size: 13)).foregroundStyle(Color(white: 0.45)) }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 15)
        .frame(height: 34)
        .background {
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        }
        .overlay {
            // one soft streak in the accent passes over the pill
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Color.glint.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 44)
                    .rotationEffect(.degrees(18))
                    .offset(x: sheen ? proxy.size.width + 44 : -88)
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
        }
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.07)))
        .padding(14)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.easeOut(duration: 0.22)) { shown = true }
            withAnimation(.easeInOut(duration: 0.7).delay(0.12)) { sheen = true }
        }
    }
}
