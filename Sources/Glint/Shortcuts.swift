import AppKit
import Carbon
import Observation
import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case allInOne, area, fullScreen, window, previousArea, scrolling, text, record, history, reopen, hidePins
    var id: String { rawValue }
    var title: String {
        switch self {
        case .allInOne: return "All-in-One Capture"
        case .area: return "Capture Area"
        case .fullScreen: return "Capture Screen"
        case .window: return "Capture Window"
        case .previousArea: return "Capture Previous Area"
        case .scrolling: return "Scrolling Capture"
        case .text: return "Capture Text"
        case .record: return "Record / Stop"
        case .history: return "History"
        case .reopen: return "Reopen Last Popup"
        case .hidePins: return "Show / Hide Pins"
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.digits[keyCode] ?? key.uppercased())
    }

    // shift turns number keys into symbols, the label should still read 4 not $
    private static let digits: [UInt32: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]

    static func from(_ event: NSEvent) -> KeyboardShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return .init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }
}

@MainActor @Observable
final class ShortcutManager {
    private(set) var shortcuts: [ShortcutAction: KeyboardShortcut]
    private(set) var errors: [String] = []
    var onAction: ((ShortcutAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var suspended = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([ShortcutAction: KeyboardShortcut].self, from: data) {
            shortcuts = saved
        } else {
            let modifiers = UInt32(cmdKey | shiftKey)
            // the macOS screenshot keys, glint takes them over once the system ones are off
            shortcuts = [
                .allInOne: .init(keyCode: 23, modifiers: modifiers, key: "5"),
                .area: .init(keyCode: 21, modifiers: modifiers, key: "4"),
                .fullScreen: .init(keyCode: 20, modifiers: modifiers, key: "3"),
                .text: .init(keyCode: 19, modifiers: modifiers, key: "2"),
                .record: .init(keyCode: 22, modifiers: modifiers, key: "6")
            ]
        }
    }

    func start() {
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    guard identifier.signature == 0x434C5054,
                          identifier.id > 0, identifier.id <= ShortcutAction.allCases.count else { return }
                    manager.onAction?(ShortcutAction.allCases[Int(identifier.id) - 1])
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        register()
    }

    func set(_ shortcut: KeyboardShortcut?, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: "shortcuts") }
        register()
    }

    func suspend(_ value: Bool) {
        suspended = value
        register()
    }

    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    private func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        errors.removeAll()
        guard !suspended else { return }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: 0x434C5054, id: UInt32(index + 1)),
                                            GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) }
            else { errors.append("\(action.title): \(shortcut.label) is already in use.") }
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let action: ShortcutAction
    let manager: ShortcutManager

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.onCapture = { manager.set($0, for: action) }
        button.onRecording = { manager.suspend($0) }
        return button
    }

    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.shortcutTitle = manager.shortcuts[action]?.label ?? ""
        if !button.isRecording { button.showShortcut() }
    }

    static func dismantleNSView(_ button: ShortcutButton, coordinator: ()) { button.finish() }
}

@MainActor
final class ShortcutButton: NSButton {
    var onCapture: ((KeyboardShortcut?) -> Void)?
    var onRecording: ((Bool) -> Void)?
    var shortcutTitle = ""
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        updateLook()
        target = self
        action = #selector(begin)
        toolTip = "Press a shortcut, Delete to clear, or Escape to cancel"
        setAccessibilityLabel("Record keyboard shortcut")
    }

    required init?(coder: NSCoder) { nil }
    @objc private func begin() {
        isRecording = true
        updateLook()
        title = "Press shortcut…"
        onRecording?(true)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 51 || event.keyCode == 117 { onCapture?(nil); finish(); return }
        if let shortcut = KeyboardShortcut.from(event) { onCapture?(shortcut); finish() }
        else { NSSound.beep() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool { finish(); return true }

    func finish() {
        guard isRecording else { return }
        isRecording = false
        updateLook()
        showShortcut()
        onRecording?(false)
    }

    private func updateLook() {
        layer?.backgroundColor = (isRecording ? NSColor.glint.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
        layer?.borderWidth = isRecording ? 1 : 0
        layer?.borderColor = NSColor.glint.cgColor
    }

    func showShortcut() {
        if shortcutTitle.isEmpty {
            attributedTitle = NSAttributedString(string: "Record Shortcut", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        } else {
            title = shortcutTitle
        }
    }
}

enum SystemShortcuts {
    // macOS screenshot shortcuts, ⇧⌘3, ⇧⌘4 and ⇧⌘5, which win over any app while enabled
    static var screenshotsEnabled: Bool {
        guard let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return true }
        return ["28", "30", "184"].contains { ((hotkeys[$0] as? [String: Any])?["enabled"] as? Bool) ?? true }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}
