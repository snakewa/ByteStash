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
        let snippets: [Snippet]
    }

    private var sections: [MenuSection] {
        guard let store = app.store else { return [] }
        let search = SearchQuery(query)
        if !search.isEmpty {
            let hits = Library.sorted(store.library.everything.filter(search.matches), by: .updated, query: search)
            return [MenuSection(id: "results", title: "Results", snippets: Array(hits.prefix(40)))]
        }
        let recent = Array(store.library.recentSnippets.prefix(8))
        let recentIDs = Set(recent.map(\.id))
        let pinned = store.library.own.filter { ($0.isPinned || $0.isFavorite) && !recentIDs.contains($0.id) }
        let latest = Library.sorted(store.library.own, by: .updated, query: search)
            .filter { !recentIDs.contains($0.id) && !$0.isPinned && !$0.isFavorite }
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
            if app.store == nil {
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
                                ForEach(section.snippets) { snippet in
                                    let index = flat.firstIndex(where: { $0.id == snippet.id }) ?? -1
                                    MenuBarRow(snippet: snippet, selected: index == selected)
                                        .id("\(section.id)-\(snippet.id)")
                                        .contentShape(Rectangle())
                                        .onTapGesture { use(snippet) }
                                        .onHover { if $0 { selected = index } }
                                        .contextMenu {
                                            Button("Copy") { copyOnly(snippet) }
                                            Button("Open in ByteStash") { open(snippet) }
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
                            proxy.scrollTo("\(section.id)-\(id)")
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
            if let store = app.store {
                Button {
                    Task { await store.sync() }
                } label: {
                    Image(systemName: store.isOffline ? "wifi.slash" : "arrow.clockwise")
                }
                .help(store.isOffline ? "Offline" : "Sync now")
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

    /// Click or ↩: copy, and paste into the previous app when auto-paste is on.
    private func use(_ snippet: Snippet?) {
        guard let snippet, let code = snippet.fragments.first?.code else { return }
        app.store?.markUsed(snippet)
        dismiss()
        Paster.copyAndMaybePaste(code, into: previousApp)
    }

    private func copyOnly(_ snippet: Snippet) {
        app.store?.markUsed(snippet)
        Clipboard.copy(snippet.fragments.first?.code ?? "")
        dismiss()
    }

    private func open(_ snippet: Snippet) {
        dismiss()
        openWindow(id: "main")
        app.store?.markUsed(snippet)
        app.reveal(snippet.id)
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
