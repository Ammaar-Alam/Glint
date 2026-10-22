import AppKit
import SwiftUI

// the right-click menu for a capture, shared by popup cards and history
enum CaptureCommand: Hashable {
    case copy, save, saveAs, edit, pin, rename, reveal, copyPath, close, closeAll, trash

    enum Place { case popup, history }

    static func sections(for kind: CaptureKind, in place: Place) -> [[CaptureCommand]] {
        // video projects share only through an export
        var sections: [[CaptureCommand]] = [
            kind == .videoProject ? [.saveAs] : [.copy, .save, .saveAs],
            kind.isVideo ? [.edit] : [.edit, .pin],
            [.reveal, .copyPath]
        ]
        if place == .history { sections[1].append(.rename) }
        if place == .popup { sections.append([.close, .closeAll]) }
        sections.append([.trash])
        return sections
    }

    func title(for kind: CaptureKind) -> String {
        switch self {
        case .copy: "Copy"
        case .save: "Save"
        case .saveAs: kind == .videoProject ? "Export…" : "Save As…"
        case .edit: "Edit"
        case .pin: "Pin"
        case .rename: "Rename…"
        case .reveal: "Show in Finder"
        case .copyPath: "Copy File Path"
        case .close: "Close"
        case .closeAll: "Close All"
        case .trash: "Move to Trash"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .edit: "square.and.pencil"
        case .pin: "pin"
        case .rename: "character.cursor.ibeam"
        case .reveal: "folder"
        case .copyPath: "link"
        case .close: "xmark"
        case .closeAll: "xmark.circle"
        case .trash: "trash"
        }
    }

    @MainActor
    static func menu(for kind: CaptureKind, in place: Place, perform: @escaping (CaptureCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        for (index, section) in sections(for: kind, in: place).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in section {
                menu.addItem(HandlerMenuItem(command.title(for: kind), symbol: command.symbol) { perform(command) })
            }
        }
        return menu
    }
}

struct CaptureMenuItems: View {
    let kind: CaptureKind
    let perform: (CaptureCommand) -> Void

    var body: some View {
        let sections = CaptureCommand.sections(for: kind, in: .history)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self) { command in
                Button(command.title(for: kind), systemImage: command.symbol, role: command == .trash ? .destructive : nil) { perform(command) }
            }
        }
    }
}
