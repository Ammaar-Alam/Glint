import SwiftUI
import AppKit

struct HistoryView: View {
    let library: CaptureLibrary
    let onEdit: (CaptureItem) -> Void
    let onCopy: (CaptureItem) -> Void
    let onSave: (CaptureItem) -> Void
    let onPin: (CaptureItem) -> Void
    let onImport: () -> Void
    let onCapture: () -> Void
    @State private var query = ""
    @State private var filter = "all"
    @State private var selected: UUID?
    @State private var renameItem: CaptureItem?
    @State private var newName = ""
    @State private var error: String?

    private var filtered: [CaptureItem] {
        library.items.filter {
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) &&
            (filter == "all" || (filter == "video" ? $0.kind.isVideo : !$0.kind.isVideo))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selected) { item in
                HStack(spacing: 12) {
                    CaptureThumbnail(url: item.thumbnail(in: library.root), revision: item.modifiedAt)
                        .frame(width: 72, height: 50).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).lineLimit(2)
                        Text(item.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.kind.isVideo { Image(systemName: "video").foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
                .tag(item.id)
                .contextMenu {
                    Button("Edit") { onEdit(item) }
                    if item.kind != .videoProject { Button("Copy") { onCopy(item) } }
                    Button(item.kind == .videoProject ? "Export…" : "Save As…") { onSave(item) }
                    if !item.kind.isVideo { Button("Pin") { onPin(item) } }
                    Divider()
                    Button("Rename…") { newName = item.title; renameItem = item }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url(in: library.root)]) }
                    Button("Move to Trash", role: .destructive) { trash(item) }
                }
                .onTapGesture(count: 2) { onEdit(item) }
                .onDrag { item.shareURL(in: library.root).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
            }
            .searchable(text: $query, prompt: "Search captures")
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $filter) {
                    Text("All").tag("all")
                    Text("Images").tag("image")
                    Text("Videos").tag("video")
                }.pickerStyle(.segmented).padding(10)
            }
            .frame(minWidth: 280)
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 420)
        } detail: {
            if let item = filtered.first(where: { $0.id == selected }) {
                VStack(spacing: 20) {
                    CaptureThumbnail(url: item.thumbnail(in: library.root), revision: item.modifiedAt)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(30)
                        .onTapGesture(count: 2) { onEdit(item) }
                    VStack(spacing: 6) {
                        Text(item.title).font(.headline).textSelection(.enabled)
                        Text(item.createdAt, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        Button("Edit", systemImage: "pencil") { onEdit(item) }.buttonStyle(.borderedProminent)
                        if item.kind != .videoProject { Button("Copy", systemImage: "doc.on.doc") { onCopy(item) } }
                        Button(item.kind == .videoProject ? "Export" : "Save", systemImage: "square.and.arrow.down") { onSave(item) }
                        if !item.kind.isVideo { Button("Pin", systemImage: "pin") { onPin(item) } }
                    }.controlSize(.large)
                    Spacer().frame(height: 20)
                }
            } else {
                ContentUnavailableView {
                    Label(library.items.isEmpty ? "Your captures live here" : "Choose a capture", systemImage: "rectangle.stack")
                } description: {
                    if library.items.isEmpty { Text("Capture something worth keeping.") }
                } actions: {
                    Button("Capture Area", action: onCapture).buttonStyle(.borderedProminent)
                    Button("Open File…", action: onImport)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Capture", systemImage: "viewfinder", action: onCapture)
                Button("Open", systemImage: "folder", action: onImport)
            }
        }
        .overlay { if library.isLoading { ProgressView() } }
        .alert("Rename capture", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
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
        .frame(minWidth: 800, minHeight: 520)
    }

    private func trash(_ item: CaptureItem) {
        Task {
            do { try await library.trash(item); if selected == item.id { selected = nil } }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct CaptureThumbnail: View {
    let url: URL
    var revision: Date? = nil
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.tertiary).padding(12) }
        }
        .task(id: url.absoluteString + String(describing: revision)) {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
