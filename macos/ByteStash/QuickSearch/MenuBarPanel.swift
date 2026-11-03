import AppKit
import SwiftUI

/// The menu bar popover: search box, recent and pinned snippets, one click to copy (or
/// paste into the app you were using).
struct MenuBarPanel: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow

    let newFromClipboard: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @State private var previousApp: NSRunningApplication?
    @FocusState private var focused: Bool

    private struct MenuSection: Identifiable {
        let id: String
        let title: String
        let snippets: [AccountSnippet]
    }

    private var sections: [MenuSection] {
        let search = SearchQuery(query)
        if !search.isEmpty {
            let hits = Library.sorted(app.everything.filter { search.matches($0.snippet) }, by: .updated, query: search, snippet: \.snippet)
            return [MenuSection(id: "results", title: "Results", snippets: Array(hits.prefix(40)))]
        }
        let recent = Array(app.recentItems.prefix(8))
        let recentIDs = Set(recent.map(\.id))
        let own = app.accounts.flatMap { account in
            account.store.library.own.map { AccountSnippet(account: account.id, snippet: $0) }
        }
        let pinned = own.filter { ($0.snippet.isPinned || $0.snippet.isFavorite) && !recentIDs.contains($0.id) }
        let latest = Library.sorted(own, by: .updated, query: search, snippet: \.snippet)
            .filter { !recentIDs.contains($0.id) && !$0.snippet.isPinned && !$0.snippet.isFavorite }
        return [
            MenuSection(id: "recent", title: "Recent", snippets: recent),
            MenuSection(id: "pinned", title: "Pinned & Favorites", snippets: Array(pinned.prefix(12))),
            MenuSection(id: "latest", title: "Recently Edited", snippets: Array(latest.prefix(8))),
        ].filter { !$0.snippets.isEmpty }
    }

    var body: some View {
        let sections = sections
        let flat = sections.flatMap(\.snippets)

        VStack(spacing: 0) {
            if app.accounts.isEmpty {
                VStack(spacing: 10) {
                    Text("Not signed in").font(.headline)
                    Button("Open ByteStash") { openMain() }
                }
                .padding(24)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search snippets", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { use(flat.indices.contains(selected) ? flat[selected] : nil) }
                        .onKeyPress(.downArrow) { move(1, count: flat.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, count: flat.count); return .handled }
                }
                .padding(10)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(section.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(section.snippets) { item in
                                    let index = flat.firstIndex(where: { $0.id == item.id }) ?? -1
                                    MenuBarRow(snippet: item.snippet, selected: index == selected,
                                               account: app.hasMultipleAccounts ? app.account(item.account)?.info : nil)
                                        .id(rowID(section.id, item.id))
                                        .contentShape(Rectangle())
                                        .onTapGesture { use(item) }
                                        .onHover { if $0 { selected = index } }
                                        .contextMenu {
                                            Button("Copy") { copyOnly(item) }
                                            Button("Open in ByteStash") { open(item) }
                                        }
                                }
                            }
                            if flat.isEmpty {
                                Text(query.isEmpty ? "No snippets yet" : "No matches")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(24)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .onChange(of: selected) { _, value in
                        guard flat.indices.contains(value) else { return }
                        let id = flat[value].id
                        if let section = sections.first(where: { $0.snippets.contains { $0.id == id } }) {
                            proxy.scrollTo(rowID(section.id, id))
                        }
                    }
                }
                .frame(height: 340)

                Divider()
                footer
            }
        }
        .frame(width: 360)
        .onAppear {
            previousApp = app.lastExternalApp
            query = ""
            selected = 0
            focused = true
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
                newFromClipboard()
            } label: {
                Label("From Clipboard", systemImage: "doc.on.clipboard")
            }
            Button {
                openMain()
            } label: {
                Label("Open", systemImage: "macwindow")
            }
            Spacer()
            if !app.accounts.isEmpty {
                let offline = app.accounts.contains { $0.store.isOffline || $0.needsSignIn }
                Button {
                    Task { await app.syncAll() }
                } label: {
                    Image(systemName: offline ? "wifi.slash" : "arrow.clockwise")
                }
                .help(offline ? "An account is offline or needs sign-in" : "Sync now")
            }
            SettingsLink {
                Image(systemName: "gearshape")
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit ByteStash")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Closes the menu bar window (dismiss() doesn't reliably close MenuBarExtra windows).
    private func dismiss() {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("MenuBarExtra") }) {
            window.orderOut(nil)
        } else {
            NSApp.keyWindow?.orderOut(nil)
        }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func rowID(_ section: String, _ ref: SnippetRef) -> String {
        "\(section)-\(ref.account)-\(ref.id)"
    }

    /// Click or ↩: copy, and paste into the previous app when auto-paste is on.
    private func use(_ item: AccountSnippet?) {
        guard let item, let code = item.snippet.fragments.first?.code else { return }
        app.markUsed(item)
        dismiss()
        Paster.copyAndMaybePaste(code, into: previousApp)
    }

    private func copyOnly(_ item: AccountSnippet) {
        app.markUsed(item)
        Clipboard.copy(item.snippet.fragments.first?.code ?? "")
        dismiss()
    }

    private func open(_ item: AccountSnippet) {
        dismiss()
        openWindow(id: "main")
        app.markUsed(item)
        app.reveal(item.id)
    }

    private func openMain() {
        dismiss()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarRow: View {
    let snippet: Snippet
    let selected: Bool
    var account: AccountInfo?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snippet.isPinned ? "pin.fill" : (snippet.isFavorite ? "star.fill" : "curlybraces"))
                .foregroundStyle(snippet.isPinned ? Color.orange : (snippet.isFavorite ? Color.yellow : Color.secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.title.isEmpty ? "Untitled" : snippet.title).lineLimit(1)
                if !snippet.preview.isEmpty {
                    Text(snippet.preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let account {
                AccountBadge(info: account, showName: false)
            }
            Text(Languages.displayName(for: snippet.primaryLanguage))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
    }
}
