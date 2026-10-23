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
    @State private var askedForScreen = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 40)
            Text("Welcome to Glint")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 14)
            Text("Three quick things and you’re set.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(spacing: 10) {
                SetupRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording", detail: "Required to capture your screen", done: screen) {
                    if askedForScreen {
                        Button("Relaunch", action: relaunch).buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Allow") {
                            askedForScreen = true
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                SetupRow(symbol: "accessibility", title: "Accessibility", detail: "Optional, for scrolling capture and keystrokes", done: accessibility) {
                    Button("Allow") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                SetupRow(symbol: "command", title: "⇧⌘3, ⇧⌘4 and ⇧⌘5", detail: systemShortcuts ? "Turn off Screenshots in Keyboard Shortcuts" : "Glint answers the screenshot keys", done: !systemShortcuts) {
                    Button("Open") { NSWorkspace.shared.open(SystemShortcuts.settingsURL) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            Spacer(minLength: 20)
            Button(screen ? "Get Started" : "Later", action: finish)
                .buttonStyle(screen ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 32)
        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(poll) { _ in
            screen = CGPreflightScreenCaptureAccess()
            accessibility = AXIsProcessTrusted()
            systemShortcuts = SystemShortcuts.screenshotsEnabled
        }
    }
}

private struct SetupRow<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.glint)
                .frame(width: 38, height: 38)
                .background(Color.glint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                action
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.easeOut(duration: 0.2), value: done)
    }
}

// lets one call site switch between two concrete button styles
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
