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
            if let item = app.selectedItem, let account = app.account(item.account) {
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
        .onChange(of: app.selection) { _, _ in clearHiddenSelection() }
        .onChange(of: app.scope) { _, _ in clearHiddenSelection() }
    }

    private func clearHiddenSelection() {
        guard let ref = app.selectedSnippet, let selection = app.selection else { return }
        let visible = app.snippets(for: selection, query: SearchQuery(app.searchText), sort: .updated)
        if !visible.contains(where: { $0.id == ref }) { app.selectedSnippet = nil }
    }

    private var transferTitle: String {
        guard let transfer = app.pendingTransfer,
              let target = app.account(transfer.target)?.info else { return "" }
        let title = app.snippet(transfer.source).map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "snippet"
        return "\(transfer.move ? "Move" : "Copy") “\(title)” to \(target.displayName)?"
    }

    private func transferMessage(_ transfer: SnippetTransfer) -> String {
        guard let target = app.account(transfer.target)?.info,
              let source = app.account(transfer.source.account)?.info else { return "" }
        let host = target.serverURL?.host ?? target.server
        var text = "A private copy is created on \(host) as \(target.username). Its sharing settings stay on \(source.displayName)."
        if transfer.move { text += " The original goes to \(source.displayName)'s Recycle Bin." }
        return text
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
