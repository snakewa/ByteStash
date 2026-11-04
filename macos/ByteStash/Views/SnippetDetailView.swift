import AppKit
import SwiftUI

/// Editor for one snippet. Edits go into a local draft and are saved shortly after typing
/// stops (and when leaving the snippet), like SnippetsLab.
struct SnippetDetailView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: SnippetStore

    let snippet: Snippet
    /// The account the snippet lives on.
    let account: AccountInfo

    @State private var draft: Snippet
    @State private var dirty = false
    @State private var selectedFragment = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var showShareSheet = false
    @State private var showSharing = false
    @State private var copied = false
    @StateObject private var markdownController = MarkdownPreviewController()

    @AppStorage("markdownPreview") private var markdownPreview = true
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize: Double = 13
    @AppStorage(EditorSettings.wrapKey) private var wrapLines = false
    @AppStorage(EditorSettings.lineNumbersKey) private var lineNumbers = true
    @AppStorage(EditorSettings.lightThemeKey) private var lightTheme = EditorSettings.defaultLightTheme
    @AppStorage(EditorSettings.darkThemeKey) private var darkTheme = EditorSettings.defaultDarkTheme

    init(snippet: Snippet, account: AccountInfo) {
        self.snippet = snippet
        self.account = account
        _draft = State(initialValue: snippet)
    }

    private var editable: Bool { store.canEdit(snippet) }

    private var isMarkdown: Bool {
        guard draft.fragments.indices.contains(selectedFragment) else { return false }
        let fragment = draft.fragments[selectedFragment]
        return fragment.language == "markdown" || Languages.guess(fileName: fragment.fileName) == "markdown"
    }
    private var own: Bool { store.isOwn(snippet) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fragmentTabs
            Divider()
            if draft.fragments.indices.contains(selectedFragment),
               isMarkdown, markdownPreview {
                MarkdownPreview(text: draft.fragments[selectedFragment].code, controller: markdownController)
            } else if draft.fragments.indices.contains(selectedFragment) {
                CodeEditor(
                    text: $draft.fragments[selectedFragment].code,
                    language: draft.fragments[selectedFragment].language,
                    isEditable: editable,
                    fontSize: CGFloat(fontSize),
                    wrapLines: wrapLines,
                    showLineNumbers: lineNumbers,
                    lightTheme: lightTheme,
                    darkTheme: darkTheme
                )
                // Keyed by tab index, not fragment id: ids change when the server confirms a save.
                .id(selectedFragment)
                .clipped()
            } else {
                Spacer()
            }
        }
        .toolbar { toolbar }
        .onChange(of: draft) { _, newValue in
            guard newValue != snippet || dirty else { return }
            dirty = true
            scheduleSave()
        }
        .onChange(of: snippet) { _, newValue in
            // Picked up a newer copy from sync (or pin/favorite): take it if we have no edits.
            if !dirty {
                draft = newValue
                selectedFragment = min(selectedFragment, max(newValue.fragments.count - 1, 0))
            } else {
                draft.isPinned = newValue.isPinned
                draft.isFavorite = newValue.isFavorite
            }
        }
        .onDisappear { saveNow() }
        .sheet(isPresented: $showShareSheet) { ShareLinkSheet(snippet: snippet) }
        .sheet(isPresented: $showSharing) { SharingSheet(snippet: snippet) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .disabled(!editable)
                if snippet.isLocked {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(own ? "Editing is locked. Unlock it under Share → Sharing…" : "The owner locked this snippet.")
                } else if !editable {
                    Label("Read only", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Description", text: $draft.description, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
                .disabled(!editable)
            if snippet.visibility == "protected", !snippet.shares.isEmpty {
                ShareSummary(shares: snippet.shares)
            }
            HStack(spacing: 10) {
                TagEditor(tags: $draft.categories, editable: editable)
                Spacer()
                if app.hasMultipleAccounts {
                    AccountBadge(info: account)
                }
                if let owner = snippet.username, !own {
                    Label(owner, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Edited \(snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Fragments

    private var fragmentTabs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(draft.fragments.enumerated()), id: \.element.id) { index, fragment in
                        FragmentTab(
                            name: fragment.fileName.isEmpty ? "Untitled" : fragment.fileName,
                            selected: index == selectedFragment
                        ) {
                            selectedFragment = index
                        }
                        .contextMenu {
                            Button("Copy") { Clipboard.copy(fragment.code) }
                            if editable && draft.fragments.count > 1 {
                                Button("Remove File", role: .destructive) { removeFragment(at: index) }
                            }
                        }
                    }
                    if editable {
                        Button(action: addFragment) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add File")
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 12)
            }

            if draft.fragments.indices.contains(selectedFragment) {
                if isMarkdown {
                    Picker("Markdown view", selection: $markdownPreview) {
                        Text("Preview").tag(true)
                        Text("Source").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Rendered preview or Markdown source (⌥⌘P)")
                    .keyboardShortcut("p", modifiers: [.command, .option])
                }
                if editable {
                    TextField("File name", text: fileNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Picker("Language", selection: $draft.fragments[selectedFragment].language) {
                        ForEach(languageOptions, id: \.self) { language in
                            Text(Languages.displayName(for: language)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                } else {
                    Text(Languages.displayName(for: draft.fragments[selectedFragment].language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isMarkdown && markdownPreview {
                    Button {
                        markdownController.exportImage(suggestedName: draft.title.isEmpty ? draft.fragments[selectedFragment].fileName : draft.title)
                    } label: {
                        Image(systemName: "camera")
                    }
                    .buttonStyle(.borderless)
                    .help("Export the rendered preview as an image")
                }
                Button {
                    Clipboard.copy(draft.fragments[selectedFragment].code)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy file contents (⇧⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .padding(.trailing, 12)
            }
        }
        .frame(height: 36)
    }

    private var languageOptions: [String] {
        let current = draft.fragments.indices.contains(selectedFragment) ? draft.fragments[selectedFragment].language : "plaintext"
        return Languages.all.contains(current) ? Languages.all : [current] + Languages.all
    }

    /// Renaming a file to "x.py" also switches its language when it's still plain text.
    private var fileNameBinding: Binding<String> {
        Binding(
            get: { draft.fragments[selectedFragment].fileName },
            set: { name in
                draft.fragments[selectedFragment].fileName = name
                if draft.fragments[selectedFragment].language == "plaintext", let guess = Languages.guess(fileName: name) {
                    draft.fragments[selectedFragment].language = guess
                }
            }
        )
    }

    private func addFragment() {
        let language = draft.fragments.last?.language ?? "plaintext"
        draft.fragments.append(Fragment(fileName: "file\(draft.fragments.count + 1)", code: "", language: language, position: draft.fragments.count))
        selectedFragment = draft.fragments.count - 1
    }

    private func removeFragment(at index: Int) {
        guard draft.fragments.count > 1 else { return }
        draft.fragments.remove(at: index)
        selectedFragment = min(selectedFragment, draft.fragments.count - 1)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if snippet.isRecycled {
                Button {
                    store.restore(snippet)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            } else {
                if own {
                    Button {
                        store.setFavorite(snippet, !snippet.isFavorite)
                    } label: {
                        Label("Favorite", systemImage: snippet.isFavorite ? "star.fill" : "star")
                    }
                    .help(snippet.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                    Button {
                        store.setPinned(snippet, !snippet.isPinned)
                    } label: {
                        Label("Pin", systemImage: snippet.isPinned ? "pin.fill" : "pin")
                    }
                    .help(snippet.isPinned ? "Unpin" : "Pin")

                    Menu {
                        Button("Sharing…") {
                            saveNow()
                            showSharing = true
                        }
                        Button("Create Share Link…") { showShareSheet = true }
                            .disabled(snippet.id < 0)
                    } label: {
                        Label("Share", systemImage: visibilityIcon)
                    } primaryAction: {
                        saveNow()
                        showSharing = true
                    }
                    .help("Visibility and share links")
                }

                Menu {
                    SnippetActions(item: AccountSnippet(account: account.id, snippet: snippet))
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var visibilityIcon: String {
        switch draft.visibility {
        case "public": return "globe"
        case "protected": return "person.2"
        default: return "lock"
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard dirty, editable else { return }
        dirty = false
        store.save(draft)
    }
}

private struct FragmentTab: View {
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ShareLinkSheet: View {
    @EnvironmentObject private var store: SnippetStore
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet

    @State private var requiresAuth = false
    @State private var expiry = 0
    @State private var link: URL?
    @State private var error: String?
    @State private var working = false

    private let expiries: [(label: String, seconds: Int)] = [
        ("Never", 0), ("1 hour", 3600), ("1 day", 86_400), ("1 week", 604_800), ("30 days", 2_592_000),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Link").font(.headline)
            Text("Anyone with the link can view “\(snippet.title)”.")
                .foregroundStyle(.secondary)
            Toggle("Require sign-in to view", isOn: $requiresAuth)
            Picker("Expires", selection: $expiry) {
                ForEach(expiries, id: \.seconds) { Text($0.label).tag($0.seconds) }
            }
            if let link {
                HStack {
                    Text(link.absoluteString).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") { Clipboard.copy(link.absoluteString) }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button(link == nil ? "Create Link" : "Create Another") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        working = true
        error = nil
        Task {
            do {
                let url = try await store.createShareLink(for: snippet, requiresAuth: requiresAuth, expiresInSeconds: expiry == 0 ? nil : expiry)
                link = url
                Clipboard.copy(url.absoluteString)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }
}
