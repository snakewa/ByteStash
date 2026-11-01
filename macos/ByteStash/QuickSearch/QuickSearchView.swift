import AppKit
import SwiftUI

struct QuickSearchView: View {
    @EnvironmentObject private var app: AppState
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @State private var fragmentIndex = 0
    @State private var flash: String?
    @FocusState private var focused: Bool

    private var results: [Snippet] {
        guard let store = app.store else { return [] }
        let search = SearchQuery(query)
        let pool = store.library.everything
        if search.isEmpty {
            return Array(Library.sorted(pool, by: .updated, query: search).prefix(30))
        }
        return Array(Library.sorted(pool.filter(search.matches), by: .updated, query: search).prefix(50))
    }

    var body: some View {
        let items = results
        let current = items.indices.contains(selected) ? items[selected] : nil

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search snippets", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { copy(current) }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.tab) { cycleFragment(current); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) {
                            open(current)
                            return .handled
                        }
                        return .ignored
                    }
                if let flash {
                    Text(flash).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, snippet in
                        QuickSearchRow(snippet: snippet, selected: index == selected)
                            .id(snippet.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { copy(snippet) }
                            .onTapGesture { selected = index; fragmentIndex = 0 }
                            .listRowBackground(index == selected ? Color.accentColor.opacity(0.25) : Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(width: 300)
                    .onChange(of: selected) { _, value in
                        if items.indices.contains(value) { proxy.scrollTo(items[value].id) }
                    }
                }

                Divider()

                if let current {
                    QuickPreview(snippet: current, fragmentIndex: fragmentIndex)
                } else {
                    VStack {
                        Spacer()
                        Text(app.store?.library.own.isEmpty == false ? "No matches" : "No snippets yet")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↩", "Copy")
                hint("⌘↩", "Open")
                hint("⇥", "Next file")
                hint("esc", "Close")
                Spacer()
                Text("#tag  lang:python").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 760, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onReceive(NotificationCenter.default.publisher(for: .quickSearchWillShow)) { _ in
            query = ""
            selected = 0
            fragmentIndex = 0
            flash = nil
            focused = true
        }
        .onChange(of: query) { _, _ in
            selected = 0
            fragmentIndex = 0
        }
        .onAppear { focused = true }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced()).padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
        fragmentIndex = 0
    }

    private func cycleFragment(_ snippet: Snippet?) {
        guard let snippet, snippet.fragments.count > 1 else { return }
        fragmentIndex = (fragmentIndex + 1) % snippet.fragments.count
    }

    private func copy(_ snippet: Snippet?) {
        guard let snippet, snippet.fragments.indices.contains(fragmentIndex) else { return }
        Clipboard.copy(snippet.fragments[fragmentIndex].code)
        flash = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dismiss() }
    }

    private func open(_ snippet: Snippet?) {
        guard let snippet else { return }
        dismiss()
        app.reveal(snippet.id)
    }
}

private struct QuickSearchRow: View {
    let snippet: Snippet
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if snippet.isPinned { Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.orange) }
                Text(snippet.title.isEmpty ? "Untitled" : snippet.title).font(.body.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Languages.displayName(for: snippet.primaryLanguage))
                if !snippet.categories.isEmpty {
                    Text(snippet.categories.map { "#\($0)" }.joined(separator: " ")).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct QuickPreview: View {
    let snippet: Snippet
    let fragmentIndex: Int

    @AppStorage(EditorSettings.lightThemeKey) private var lightTheme = EditorSettings.defaultLightTheme
    @AppStorage(EditorSettings.darkThemeKey) private var darkTheme = EditorSettings.defaultDarkTheme

    var body: some View {
        let fragment = snippet.fragments.indices.contains(fragmentIndex) ? snippet.fragments[fragmentIndex] : nil
        VStack(alignment: .leading, spacing: 0) {
            if snippet.fragments.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(snippet.fragments.enumerated()), id: \.element.id) { index, f in
                        Text(f.fileName.isEmpty ? "file\(index + 1)" : f.fileName)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(index == fragmentIndex ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(8)
            }
            if !snippet.description.isEmpty {
                Text(snippet.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            CodeEditor(
                text: .constant(fragment?.code ?? ""),
                language: fragment?.language ?? "plaintext",
                isEditable: false,
                fontSize: 12,
                wrapLines: false,
                showLineNumbers: false,
                lightTheme: lightTheme,
                darkTheme: darkTheme
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
