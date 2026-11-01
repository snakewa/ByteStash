import AppKit
import SwiftUI

struct SnippetListView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: SnippetStore
    @AppStorage("sortOrder") private var sort: SortOrder = .updated

    private var snippets: [Snippet] {
        store.library.snippets(for: app.selection ?? .all, query: SearchQuery(app.searchText), sort: sort)
    }

    var body: some View {
        let items = snippets
        List(selection: $app.selectedSnippetID) {
            ForEach(items) { snippet in
                SnippetRow(snippet: snippet, pending: store.outbox.hasPending(for: snippet.id))
                    .tag(snippet.id)
                    .contextMenu { SnippetActions(snippet: snippet) }
            }
        }
        .overlay {
            if items.isEmpty {
                if app.searchText.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: (app.selection ?? .all).systemImage)
                } else {
                    ContentUnavailableView.search(text: app.searchText)
                }
            }
        }
        .searchable(text: $app.searchText, prompt: "Search  #tag  lang:swift")
        .navigationTitle((app.selection ?? .all).title)
        .navigationSubtitle("\(items.count) snippet\(items.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    app.newSnippet()
                } label: {
                    Label("New Snippet", systemImage: "square.and.pencil")
                }
                .help("New Snippet (⌘N)")
            }
        }
        .onDeleteCommand {
            guard let id = app.selectedSnippetID, let snippet = store.library.snippet(id: id) else { return }
            if snippet.isRecycled { store.deleteForever(snippet) } else if store.isOwn(snippet) { store.moveToRecycleBin(snippet) }
        }
    }

    private var emptyTitle: String {
        switch app.selection ?? .all {
        case .recycled: return "Recycle Bin is empty"
        case .shared: return "Nothing shared with you yet"
        case .publicFeed: return "No public snippets"
        default: return "No snippets"
        }
    }
}

struct SnippetRow: View {
    let snippet: Snippet
    var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if snippet.isPinned {
                    Image(systemName: "pin.fill").foregroundStyle(.orange).imageScale(.small)
                }
                Text(snippet.title.isEmpty ? "Untitled" : snippet.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if snippet.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
                }
                if pending {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary).imageScale(.small)
                        .help("Waiting to sync")
                }
            }
            if !snippet.preview.isEmpty {
                Text(snippet.preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Languages.displayName(for: snippet.primaryLanguage))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if snippet.fragments.count > 1 {
                    Text("\(snippet.fragments.count) files").font(.caption2).foregroundStyle(.secondary)
                }
                if snippet.visibility == "public" {
                    Image(systemName: "globe").imageScale(.small).foregroundStyle(.secondary)
                } else if snippet.visibility == "protected" {
                    Image(systemName: "person.2").imageScale(.small).foregroundStyle(.secondary)
                }
                if let owner = snippet.username, !owner.isEmpty, snippet.visibility != "private" {
                    Text(owner).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Text(snippet.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Shared actions for context menus and the detail toolbar.
struct SnippetActions: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: SnippetStore
    let snippet: Snippet

    var body: some View {
        Button("Copy Code") { Clipboard.copy(snippet.fragments.first?.code ?? "") }
        if snippet.fragments.count > 1 {
            Menu("Copy File") {
                ForEach(snippet.fragments) { fragment in
                    Button(fragment.fileName.isEmpty ? "Untitled" : fragment.fileName) { Clipboard.copy(fragment.code) }
                }
            }
        }
        Divider()
        if snippet.isRecycled {
            Button("Restore") { store.restore(snippet) }
            Button("Delete Forever", role: .destructive) { store.deleteForever(snippet) }
        } else {
            if store.isOwn(snippet) {
                Button(snippet.isPinned ? "Unpin" : "Pin") { store.setPinned(snippet, !snippet.isPinned) }
                Button(snippet.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.setFavorite(snippet, !snippet.isFavorite) }
            }
            Button("Duplicate") {
                let copy = store.duplicate(snippet)
                app.selection = .all
                app.selectedSnippetID = copy.id
            }
            if snippet.id > 0 {
                Button("Open in Browser") { NSWorkspace.shared.open(store.webURL(for: snippet)) }
            }
            if store.isOwn(snippet) {
                Divider()
                Button("Move to Recycle Bin", role: .destructive) { store.moveToRecycleBin(snippet) }
            }
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
