import AppKit
import ApplicationServices
import Combine
import SwiftUI

// first run, and whenever a capture finds screen recording missing
struct OnboardingView: View {
    let relaunch: () -> Void
    let finish: () -> Void
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    @State private var systemShortcuts = SystemShortcuts.screenshotsEnabled
    @State private var celebrating: Set<Step> = []
    @State private var appeared = false
    // survives the relaunch macOS needs before a new screen grant applies
    @AppStorage("screenAccessRequested") private var screenRequested = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum Step { case screen, accessibility, shortcuts }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
                .padding(.top, 40)
            Text(screen ? "You’re all set" : "Welcome to Glint")
                .font(.system(size: 26, weight: .semibold))
                .contentTransition(.opacity)
                .padding(.top, 14)
            Text(screen ? "Press ⇧⌘4 to capture anything." : "Three quick things and you’re set.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .padding(.top, 4)
            VStack(spacing: 10) {
                SetupRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording", detail: screen ? "Allowed" : "Required to capture your screen",
                         done: screen, celebrating: celebrating.contains(.screen)) {
                    if screenRequested {
                        Button("Relaunch", action: relaunch).buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Allow") {
                            screenRequested = true
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                SetupRow(symbol: "accessibility", title: "Accessibility", detail: accessibility ? "Allowed" : "Optional, for showing keystrokes",
                         done: accessibility, celebrating: celebrating.contains(.accessibility)) {
                    Button("Allow") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                SetupRow(symbol: "command", title: "⇧⌘3, ⇧⌘4 and ⇧⌘5", detail: systemShortcuts ? "Turn off Screenshots in Keyboard Shortcuts" : "Glint answers the screenshot keys",
                         done: !systemShortcuts, celebrating: celebrating.contains(.shortcuts)) {
                    Button("Open") { NSWorkspace.shared.open(SystemShortcuts.settingsURL) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .offset(y: appeared ? 0 : 12)
            .opacity(appeared ? 1 : 0)
            Spacer(minLength: 20)
            Button(screen ? "Get Started" : "Later", action: finish)
                .buttonStyle(screen ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                .keyboardShortcut(.defaultAction)
                .scaleEffect(screen && celebrating.contains(.screen) ? 1.06 : 1)
                .padding(.bottom, 32)
        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: screen)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
            // back from the relaunch with access granted, confirm it
            if screen && screenRequested {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { celebrate(.screen) }
            }
        }
        .onReceive(poll) { _ in
            update(&screen, to: CGPreflightScreenCaptureAccess(), step: .screen)
            update(&accessibility, to: AXIsProcessTrusted(), step: .accessibility)
            var off = !systemShortcuts
            update(&off, to: !SystemShortcuts.screenshotsEnabled, step: .shortcuts)
            systemShortcuts = !off
        }
    }

    private func update(_ value: inout Bool, to next: Bool, step: Step) {
        guard value != next else { return }
        value = next
        if next { celebrate(step) }
    }

    private func celebrate(_ step: Step) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { _ = celebrating.insert(step) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.6)) { _ = celebrating.remove(step) }
        }
    }
}

private struct SetupRow<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let done: Bool
    let celebrating: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(done ? Color.green : Color.glint)
                .frame(width: 38, height: 38)
                .background((done ? Color.green : Color.glint).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.green)
                    .scaleEffect(celebrating ? 1.25 : 1)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            } else {
                action.transition(.opacity)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .background(Color.green.opacity(celebrating ? 0.25 : 0), in: RoundedRectangle(cornerRadius: Radius.card + 3, style: .continuous).inset(by: -3))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(celebrating ? Color.green.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: celebrating ? 1.5 : 1))
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: done)
    }
}

// lets one call site switch between two concrete button styles
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
