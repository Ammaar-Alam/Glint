import SwiftUI
import AppKit

enum HistoryFilter: String, CaseIterable {
    case all, screenshots, recordings

    var title: String {
        switch self {
        case .all: "All"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        }
    }

    func includes(_ kind: CaptureKind) -> Bool {
        switch self {
        case .all: true
        case .screenshots: !kind.isVideo
        case .recordings: kind.isVideo
        }
    }
}

struct HistorySection: Identifiable, Equatable {
    let title: String
    var items: [CaptureItem]
    var id: String { title }

    static func make(_ items: [CaptureItem], filter: HistoryFilter, query: String, now: Date = Date(), calendar: Calendar = .current) -> [HistorySection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [HistorySection] = []
        for item in items.sorted(by: { $0.createdAt > $1.createdAt })
        where filter.includes(item.kind) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) {
            let title = group(item.createdAt, now: now, calendar: calendar)
            if sections.last?.title == title { sections[sections.count - 1].items.append(item) }
            else { sections.append(HistorySection(title: title, items: [item])) }
        }
        return sections
    }

    static func group(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2...7: return "Previous 7 Days"
        case 8...30: return "Previous 30 Days"
        default:
            var style = Date.FormatStyle.dateTime.month(.wide)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return date.formatted(sameYear ? style : style.year())
        }
    }

    // arrow keys move through rows inside a section and hop to the nearest column across sections
    static func neighbor(of id: UUID?, in sections: [[UUID]], columns: Int, dx: Int, dy: Int) -> UUID? {
        guard let first = sections.first?.first else { return nil }
        guard let id, let s = sections.firstIndex(where: { $0.contains(id) }), let i = sections[s].firstIndex(of: id) else { return first }
        if dx != 0 {
            let flat = sections.flatMap { $0 }
            let index = (flat.firstIndex(of: id) ?? 0) + dx
            return flat.indices.contains(index) ? flat[index] : id
        }
        let section = sections[s], column = i % columns
        if section.indices.contains(i + dy * columns) { return section[i + dy * columns] }
        if dy > 0 {
            if i / columns < (section.count - 1) / columns { return section.last }
            guard s + 1 < sections.count else { return id }
            return sections[s + 1][min(column, sections[s + 1].count - 1)]
        }
        guard s > 0 else { return id }
        let previous = sections[s - 1]
        return previous[min((previous.count - 1) / columns * columns + column, previous.count - 1)]
    }
}

struct HistoryView: View {
    let library: CaptureLibrary
    let shortcuts: ShortcutManager
    let onCommand: (CaptureCommand, CaptureItem) -> Void
    let onImport: () -> Void
    let onCapture: () -> Void
    let onRecord: () -> Void
    @State private var query = ""
    @State private var filter = HistoryFilter.all
    @State private var selected: UUID?
    @State private var columns = 3
    @State private var renameItem: CaptureItem?
    @State private var newName = ""
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool

    private static let cardWidth: CGFloat = 216
    private static let spacing: CGFloat = 20
    private static let margin: CGFloat = 28

    private var sections: [HistorySection] { HistorySection.make(library.items, filter: filter, query: query) }
    private var selectedItem: CaptureItem? { library.items.first { $0.id == selected } }

    var body: some View {
        let sections = sections
        Group {
            if library.isLoading && library.items.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid(sections)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 640, minHeight: 440)
        .onCommand(#selector(NSText.copy(_:))) { if let item = selectedItem { run(.copy, item) } }
        .alert("Rename Capture", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renameItem = nil }
            Button("Rename") {
                guard let item = renameItem else { return }
                Task { do { try await library.rename(item, to: newName) } catch { self.error = error.localizedDescription } }
                renameItem = nil
            }
        }
        .alert("Couldn’t update history", isPresented: Binding(get: { error != nil || library.error != nil }, set: { if !$0 { error = nil; library.error = nil } })) {
            Button("OK") { error = nil; library.error = nil }
        } message: { Text(error ?? library.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CapsulePicker(selection: $filter, options: HistoryFilter.allCases, title: \.title)
            Spacer(minLength: 16)
            searchField
            Button("Open", systemImage: "folder", action: onImport)
                .labelStyle(.iconOnly)
                .buttonStyle(ToolButtonStyle())
                .help("Open")
            Button(action: onCapture) {
                Label("Capture", systemImage: "viewfinder").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.leading, 86)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background { Rectangle().fill(.bar).gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand { query = ""; gridFocused = true }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 28)
        .background(Capsule().fill(Color.primary.opacity(searchFocused ? 0.09 : 0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(searchFocused ? 0.16 : 0), lineWidth: 0.5))
    }

    private func grid(_ sections: [HistorySection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(section.title).font(.system(size: 13, weight: .semibold))
                            Text("\(section.items.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                        }
                        .padding(.top, 22)
                        .padding(.bottom, 12)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columns), spacing: 22) {
                            ForEach(section.items) { item in
                                HistoryCard(item: item, root: library.root, selected: item.id == selected) { run($0, item) }
                                    .id(item.id)
                                    .simultaneousGesture(TapGesture().onEnded { selected = item.id; gridFocused = true })
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.margin)
            }
            .onGeometryChange(for: Int.self) { geometry in
                max(1, Int((geometry.size.width - Self.margin * 2 + Self.spacing) / (Self.cardWidth + Self.spacing)))
            } action: { columns = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
                if press.key == .return {
                    guard let item = selectedItem else { return .ignored }
                    run(.edit, item)
                    return .handled
                }
                let dx = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : 0
                let dy = press.key == .upArrow ? -1 : press.key == .downArrow ? 1 : 0
                selected = HistorySection.neighbor(of: selected, in: sections.map { $0.items.map(\.id) }, columns: columns, dx: dx, dy: dy)
                if let selected { proxy.scrollTo(selected) }
                return .handled
            }
            .onDeleteCommand { if let item = selectedItem { run(.trash, item) } }
            .onExitCommand { selected = nil }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text("No Results").font(.system(size: 15, weight: .semibold))
                Text("Nothing matches “\(query)”").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        } else {
            let recordings = filter == .recordings
            let shortcut = shortcuts.shortcuts[recordings ? .record : .area]
            VStack(spacing: 0) {
                EmptyStack(symbol: recordings ? "record.circle" : "viewfinder")
                    .padding(.bottom, 26)
                Text(recordings ? "No recordings yet" : filter == .screenshots ? "No screenshots yet" : "No captures yet")
                    .font(.system(size: 17, weight: .semibold))
                if let shortcut {
                    HStack(spacing: 4) {
                        ForEach(Array(shortcut.label.enumerated()), id: \.offset) { Keycap(key: String($0.element)) }
                        Text(recordings ? "to record your screen" : "to capture an area")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    .padding(.top, 12)
                }
                HStack(spacing: 8) {
                    if recordings {
                        Button("Record", action: onRecord).buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Capture", action: onCapture).buttonStyle(PrimaryButtonStyle())
                        Button("Open…", action: onImport).buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 22)
            }
            .padding(.bottom, 40)
        }
    }

    private func run(_ command: CaptureCommand, _ item: CaptureItem) {
        switch command {
        case .rename:
            newName = item.title
            renameItem = item
        case .trash:
            // keep a selection so repeated deletes walk through the grid
            if selected == item.id {
                let ids = sections.flatMap { $0.items.map(\.id) }
                let index = ids.firstIndex(of: item.id) ?? 0
                selected = ids.indices.contains(index + 1) ? ids[index + 1] : index > 0 ? ids[index - 1] : nil
            }
            onCommand(command, item)
        default:
            onCommand(command, item)
        }
    }
}

struct HistoryCard: View {
    let item: CaptureItem
    let root: URL
    let selected: Bool
    let perform: (CaptureCommand) -> Void
    @State var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(dateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { perform(.edit) }
        .onDrag { item.shareURL(in: root).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
        .contextMenu { CaptureMenuItems(kind: item.kind, perform: perform) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Color.clear
            .aspectRatio(232.0 / 146.0, contentMode: .fit)
            .overlay { CaptureThumbnail(url: item.thumbnail(in: root), revision: item.modifiedAt, symbol: item.kind.isVideo ? "video" : "photo") }
            .overlay(alignment: .bottomLeading) {
                if item.kind.isVideo {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 18)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(8)
                        .accessibilityLabel("Recording")
                }
            }
            .overlay { actions.opacity(hovering ? 1 : 0).allowsHitTesting(hovering) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(hovering ? 0.2 : 0.12), radius: hovering ? 9 : 4, y: hovering ? 4 : 2)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                        .strokeBorder(Color.glint, lineWidth: 2.5)
                        .padding(-4)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: hovering ? 0.12 : 0.18), value: hovering)
    }

    private var actions: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 8) {
                if item.kind != .videoProject {
                    Button("Copy") { perform(.copy) }.buttonStyle(HUDButtonStyle(primary: true))
                }
                Button(item.kind == .videoProject ? "Export" : "Save") { perform(.saveAs) }.buttonStyle(HUDButtonStyle())
            }
        }
        .overlay(alignment: .topTrailing) { corner("Edit", "pencil", .edit) }
        .overlay(alignment: .bottomLeading) { if !item.kind.isVideo { corner("Pin", "pin.fill", .pin) } }
        .overlay(alignment: .bottomTrailing) { corner("Move to Trash", "trash", .trash) }
    }

    private func corner(_ title: String, _ symbol: String, _ command: CaptureCommand) -> some View {
        Button(title, systemImage: symbol) { perform(command) }
            .buttonStyle(HUDButtonStyle(icon: true))
            .help(title)
            .padding(8)
    }

    private var dateText: String {
        let calendar = Calendar.current
        let recent = calendar.isDateInToday(item.createdAt) || calendar.isDateInYesterday(item.createdAt)
        return item.createdAt.formatted(date: recent ? .omitted : .abbreviated, time: .shortened)
    }
}

// a small stack of capture cards for the empty library
private struct EmptyStack: View {
    let symbol: String

    var body: some View {
        ZStack {
            card.rotationEffect(.degrees(-9)).offset(x: -26, y: 6).brightness(-0.04)
            card.rotationEffect(.degrees(7)).offset(x: 26, y: 2).brightness(-0.02)
            card.overlay {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.glint)
            }
        }
        .accessibilityHidden(true)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape.fill(Color(nsColor: .windowBackgroundColor))
            .overlay(shape.fill(Color(nsColor: .raisedControl)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .frame(width: 104, height: 66)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

struct CaptureThumbnail: View {
    let url: URL
    var revision: Date? = nil
    var symbol = "photo"
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary) }
        }
        .task(id: url.absoluteString + String(describing: revision)) {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
