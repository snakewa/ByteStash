import AppKit
import SwiftUI

struct SnippetListView: View {
    @EnvironmentObject private var app: AppState
    @AppStorage("sortOrder") private var sort: SortOrder = .updated
    @AppStorage("listLayout") private var layout = "list"
    @Environment(\.colorScheme) private var colorScheme

    private var snippets: [AccountSnippet] {
        app.snippets(for: app.selection ?? .all, query: SearchQuery(app.searchText), sort: sort)
    }

    /// Account badges only help when the list mixes accounts.
    private var showsAccount: Bool { app.hasMultipleAccounts && app.scope == .all }

    var body: some View {
        let items = snippets
        Group {
            if layout == "grid" {
                grid(items)
            } else {
                List(selection: $app.selectedSnippet) {
                    ForEach(items) { item in
                        SnippetRow(snippet: item.snippet,
                                   pending: app.store(item.account)?.outbox.hasPending(for: item.snippet.id) ?? false,
                                   account: showsAccount ? app.account(item.account)?.info : nil)
                            .tag(item.id)
                            .contextMenu { SnippetActions(item: item) }
                    }
                }
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
        .navigationSubtitle(subtitle(count: items.count))
        .toolbar {
            ToolbarItemGroup {
                Picker("Layout", selection: $layout) {
                    Label("List", systemImage: "list.bullet").tag("list")
                    Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                }
                .pickerStyle(.segmented)
                .help("List or grid (⌥⌘1 / ⌥⌘2)")
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                if app.hasMultipleAccounts && app.scope == .all {
                    // In the merged view the user picks where the new snippet goes.
                    Menu {
                        ForEach(app.accounts) { account in
                            Button("New in \(account.info.displayName)") { app.newSnippet(in: account.id) }
                        }
                    } label: {
                        Label("New Snippet", systemImage: "square.and.pencil")
                    } primaryAction: {
                        app.newSnippet()
                    }
                    .help("New Snippet in \(app.defaultAccount?.info.displayName ?? "the default account") (⌘N). Hold to choose another account.")
                } else {
                    Button {
                        app.newSnippet()
                    } label: {
                        Label("New Snippet", systemImage: "square.and.pencil")
                    }
                    .help("New Snippet (⌘N)")
                }
            }
        }
        .onDeleteCommand {
            guard let item = app.selectedItem, let store = app.store(item.account) else { return }
            let snippet = item.snippet
            if snippet.isRecycled { store.deleteForever(snippet) } else if store.isOwn(snippet) { store.moveToRecycleBin(snippet) }
        }
    }

    private func subtitle(count: Int) -> String {
        let base = "\(count) snippet\(count == 1 ? "" : "s")"
        if app.hasMultipleAccounts, case let .account(id) = app.scope, let account = app.account(id) {
            return "\(account.info.displayName) · \(base)"
        }
        return base
    }

    private func grid(_ items: [AccountSnippet]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        SnippetCard(snippet: item.snippet, selected: app.selectedSnippet == item.id, dark: colorScheme == .dark,
                                    account: showsAccount ? app.account(item.account)?.info : nil)
                            .id(item.id)
                            .onTapGesture { app.selectedSnippet = item.id }
                            .contextMenu { SnippetActions(item: item) }
                    }
                }
                .padding(12)
            }
            .onChange(of: app.selectedSnippet) { _, ref in
                if let ref { withAnimation { proxy.scrollTo(ref) } }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            guard !items.isEmpty else { return }
            let index = items.firstIndex { $0.id == app.selectedSnippet } ?? -1
            let step = (direction == .left || direction == .up) ? -1 : 1
            let next = min(max(index + step, 0), items.count - 1)
            app.selectedSnippet = items[next].id
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
    /// Shown as a colored badge when the list mixes accounts.
    var account: AccountInfo?

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
                if let account {
                    AccountBadge(info: account)
                }
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
    let item: AccountSnippet

    private var snippet: Snippet { item.snippet }

    var body: some View {
        if let store = app.store(item.account) {
            actions(store)
        }
    }

    @ViewBuilder
    private func actions(_ store: SnippetStore) -> some View {
        Button("Copy Code") {
            app.markUsed(item)
            Clipboard.copy(snippet.fragments.first?.code ?? "")
        }
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
                app.selectedSnippet = SnippetRef(account: item.account, id: copy.id)
            }
            let others = app.accounts.filter { $0.id != item.account }
            if !others.isEmpty {
                Menu("Copy to") {
                    ForEach(others) { account in
                        Button(account.info.displayName + "…") { app.requestTransfer(item, to: account.id, move: false) }
                    }
                }
                if app.canMove(item) {
                    Menu("Move to") {
                        ForEach(others) { account in
                            Button(account.info.displayName + "…") { app.requestTransfer(item, to: account.id, move: true) }
                        }
                    }
                }
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

/// A grid card: title, tags and the first lines of highlighted code.
struct SnippetCard: View {
    let snippet: Snippet
    let selected: Bool
    let dark: Bool
    var account: AccountInfo?

    private var codePreview: String {
        let code = snippet.fragments.first?.code ?? ""
        return code.split(separator: "\n", omittingEmptySubsequences: false).prefix(10).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SyntaxHighlighter.highlight(codePreview, language: snippet.primaryLanguage, dark: dark, fontSize: 10.5))
                .lineLimit(10)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
                .padding(8)
                .background(SyntaxHighlighter.background(dark: dark))
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if snippet.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange).imageScale(.small) }
                    Text(snippet.title.isEmpty ? "Untitled" : snippet.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 2)
                    if snippet.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small) }
                    if let account { AccountBadge(info: account, showName: false) }
                }
                HStack(spacing: 6) {
                    Text(Languages.displayName(for: snippet.primaryLanguage))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if !snippet.categories.isEmpty {
                        Text(snippet.categories.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
