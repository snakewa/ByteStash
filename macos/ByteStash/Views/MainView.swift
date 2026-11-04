import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if app.phase == .signedIn {
                MainView()
            } else {
                SignInView()
                    .frame(width: 440)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var app: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("listLayout") private var layout = "list"

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            SnippetListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: layout == "grid" ? 480 : 300, max: layout == "grid" ? 900 : 480)
        } detail: {
            if app.selectedSnippets.count > 1 {
                BulkSelectionView(items: app.selectedItems)
            } else if let item = app.selectedItem, let account = app.account(item.account) {
                SnippetDetailView(snippet: item.snippet, account: account.info)
                    .environmentObject(account.store)
                    .id(item.id)
            } else {
                ContentUnavailableView("No Snippet Selected", systemImage: "curlybraces",
                                       description: Text("Pick a snippet, or press ⌘N to create one."))
            }
        }
        .modifier(SyncErrorAlerts(accounts: app.accounts, multiple: app.hasMultipleAccounts))
        .sheet(isPresented: $app.showAddAccount) {
            SignInView(adding: true, reauth: app.reauthAccount)
                .frame(width: 440)
                .padding(24)
        }
        .confirmationDialog(transferTitle, isPresented: Binding(
            get: { app.pendingTransfer != nil },
            set: { if !$0 { app.pendingTransfer = nil } }
        ), presenting: app.pendingTransfer) { transfer in
            Button(transfer.move ? "Move" : "Copy") { app.performTransfer(transfer) }
            Button("Cancel", role: .cancel) { app.pendingTransfer = nil }
        } message: { transfer in
            Text(transferMessage(transfer))
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { app.pendingDelete != nil },
            set: { if !$0 { app.pendingDelete = nil } }
        ), presenting: app.pendingDelete) { refs in
            Button("Delete Forever", role: .destructive) { app.performDeleteForever(refs) }
            Button("Cancel", role: .cancel) { app.pendingDelete = nil }
        } message: { _ in
            Text("This can't be undone.")
        }
        .onChange(of: app.selection) { _, _ in clearHiddenSelection() }
        .onChange(of: app.scope) { _, _ in clearHiddenSelection() }
    }

    private func clearHiddenSelection() {
        guard !app.selectedSnippets.isEmpty, let selection = app.selection else { return }
        let visible = Set(app.snippets(for: selection, query: SearchQuery(app.searchText), sort: .updated).map(\.id))
        let kept = app.selectedSnippets.intersection(visible)
        if kept != app.selectedSnippets { app.selectedSnippets = kept }
    }

    private var deleteTitle: String {
        let count = app.pendingDelete?.count ?? 0
        return count == 1 ? "Delete this snippet forever?" : "Delete \(count) snippets forever?"
    }

    private var transferTitle: String {
        guard let transfer = app.pendingTransfer,
              let target = app.account(transfer.target)?.info else { return "" }
        let verb = transfer.move ? "Move" : "Copy"
        if transfer.sources.count == 1, let first = transfer.sources.first {
            let title = app.snippet(first).map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "snippet"
            return "\(verb) “\(title)” to \(target.displayName)?"
        }
        return "\(verb) \(transfer.sources.count) snippets to \(target.displayName)?"
    }

    private func transferMessage(_ transfer: SnippetTransfer) -> String {
        guard let target = app.account(transfer.target)?.info else { return "" }
        let host = target.serverURL?.host ?? target.server
        let sources = Set(transfer.sources.map(\.account)).compactMap { app.account($0)?.info.displayName }.sorted()
        let from = sources.joined(separator: " and ")
        let plural = transfer.sources.count > 1
        var text = "\(plural ? "Private copies are" : "A private copy is") created on \(host) as \(target.username). Sharing settings stay on \(from)."
        if transfer.move {
            let items = transfer.sources.compactMap { app.item($0) }
            let notOwn = items.filter { !app.canMove($0) }.count
            text += plural ? " Originals you own go to \(from)'s Recycle Bin." : " The original goes to \(from)'s Recycle Bin."
            if notOwn > 0 {
                text += " \(notOwn) owned by someone else \(notOwn == 1 ? "is" : "are") only copied."
            }
        }
        return text
    }
}

/// Shown instead of the editor when several snippets are selected.
private struct BulkSelectionView: View {
    @EnvironmentObject private var app: AppState
    let items: [AccountSnippet]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("\(items.count) Snippets Selected").font(.title2.weight(.semibold))
            if app.hasMultipleAccounts {
                let byAccount = Dictionary(grouping: items, by: \.account)
                HStack(spacing: 12) {
                    ForEach(app.accounts.filter { byAccount[$0.id] != nil }) { account in
                        HStack(spacing: 4) {
                            AccountBadge(info: account.info)
                            Text("\(byAccount[account.id]?.count ?? 0)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Drag them onto an account, tag, Pinned, Favorites or the Recycle Bin in the sidebar, or use the actions below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Menu("Actions") {
                BulkActions(items: items)
            }
            .fixedSize()
            HStack {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(addTag)
                Button("Add", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var newTag = ""

    private func addTag() {
        app.addTag(newTag, to: items)
        newTag = ""
    }
}

/// One "Couldn't sync" alert per account, so an error on the work server doesn't hide one
/// on the personal server.
private struct SyncErrorAlerts: ViewModifier {
    let accounts: [Account]
    let multiple: Bool

    func body(content: Content) -> some View {
        accounts.reduce(AnyView(content)) { view, account in
            AnyView(view.modifier(SyncErrorAlert(store: account.store, title: multiple ? "Couldn't sync \(account.info.displayName)" : "Couldn't sync")))
        }
    }
}

private struct SyncErrorAlert: ViewModifier {
    @ObservedObject var store: SnippetStore
    let title: String

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}
