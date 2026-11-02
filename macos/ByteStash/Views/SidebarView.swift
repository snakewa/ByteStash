import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: SnippetStore

    var body: some View {
        List(selection: $app.selection) {
            Section("Library") {
                row(.all, count: store.library.own.count)
                row(.pinned, count: store.library.own.filter(\.isPinned).count)
                row(.favorites, count: store.library.own.filter(\.isFavorite).count)
                row(.untagged, count: store.library.untaggedCount)
            }

            Section("Shared") {
                row(.shared, count: store.library.shared.count)
                ForEach(store.library.groups) { group in
                    let item = SidebarItem.group(group.id, group.name)
                    row(item, count: store.library.snippets(for: item, query: SearchQuery(""), sort: .updated).count)
                        .padding(.leading, 12)
                }
                row(.publicFeed, count: store.library.publicFeed.count)
            }

            let categories = store.library.categoryCounts
            if !categories.isEmpty {
                Section("Tags") {
                    ForEach(categories, id: \.name) { item in
                        row(.category(item.name), count: item.count)
                    }
                }
            }

            let languages = store.library.languageCounts
            if !languages.isEmpty {
                Section("Languages") {
                    ForEach(languages, id: \.name) { item in
                        row(.language(item.name), count: item.count)
                    }
                }
            }

            Section {
                row(.recycled, count: store.library.recycled.count)
                    .contextMenu {
                        Button("Empty Recycle Bin…", role: .destructive) { confirmEmpty = true }
                            .disabled(store.library.recycled.isEmpty)
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        .confirmationDialog("Delete all snippets in the Recycle Bin?", isPresented: $confirmEmpty) {
            Button("Empty Recycle Bin", role: .destructive) { store.emptyRecycleBin() }
        } message: {
            Text("This can't be undone.")
        }
    }

    @State private var confirmEmpty = false

    private func row(_ item: SidebarItem, count: Int) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .badge(count)
            .tag(item)
    }
}

struct SyncStatusBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: SnippetStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isSyncing {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            } else if store.isOffline {
                Image(systemName: "wifi.slash")
                Text(store.outbox.isEmpty ? "Offline" : "Offline · \(store.outbox.count) pending")
            } else if !store.outbox.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("\(store.outbox.count) pending")
            } else if let last = store.library.lastSync {
                Image(systemName: "checkmark.circle")
                Text("Synced \(last.formatted(.relative(presentation: .named)))")
            }
            Spacer()
            Button {
                Task { await store.sync() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Sync now (⌘R)")
            .disabled(store.isSyncing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
