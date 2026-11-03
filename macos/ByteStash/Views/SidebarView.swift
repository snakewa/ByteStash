import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        list
        .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        .confirmationDialog(emptyTitle, isPresented: Binding(
            get: { confirmEmpty != nil },
            set: { if !$0 { confirmEmpty = nil } }
        )) {
            Button("Empty Recycle Bin", role: .destructive) {
                for account in app.scopedAccounts where confirmEmpty == nil || account.id == confirmEmpty {
                    account.store.emptyRecycleBin()
                }
                confirmEmpty = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var list: some View {
        List(selection: $app.selection) {
            if app.hasMultipleAccounts {
                // Click to show one account or all of them. Drop snippets on an account to
                // copy them there (hold ⌘ to move).
                Section("Accounts") {
                    AccountRow(title: "All Accounts", color: nil, count: allCount, current: app.scope == .all) {
                        app.scope = .all
                    }
                    ForEach(app.accounts) { account in
                        AccountRow(title: account.info.displayName, color: account.info.color.color,
                                   count: account.store.library.own.count, current: app.scope == .account(account.id),
                                   targeted: dropTarget == .account(account.id)) {
                            app.scope = .account(account.id)
                        }
                        .help("\(account.info.username) on \(account.info.serverURL?.host ?? account.info.server). Drop snippets here to copy them; hold ⌘ to move.")
                        .dropDestination(for: SnippetDrag.self) { drops, _ in
                            app.drop(drops.flatMap(\.refs), on: .account(account.id), modifiers: NSEvent.modifierFlags)
                        } isTargeted: { over in
                            dropTarget = over ? .account(account.id) : (dropTarget == .account(account.id) ? nil : dropTarget)
                        }
                    }
                }
            }

            Section("Library") {
                row(.all)
                row(.pinned)
                row(.favorites)
                row(.untagged)
            }

            Section("Shared") {
                row(.shared)
                ForEach(app.scopedAccounts) { account in
                    ForEach(account.store.library.groups) { group in
                        let item = SidebarItem.group(group.id, group.name, account: account.id)
                        row(item, account: account.info)
                            .padding(.leading, 12)
                    }
                }
                row(.publicFeed)
            }

            let categories = app.categoryCounts
            if !categories.isEmpty {
                Section("Tags") {
                    ForEach(categories, id: \.name) { item in
                        row(.category(item.name), count: item.count)
                    }
                }
            }

            let languages = app.languageCounts
            if !languages.isEmpty {
                Section("Languages") {
                    ForEach(languages, id: \.name) { item in
                        row(.language(item.name), count: item.count)
                    }
                }
            }

            Section {
                row(.recycled)
                    .contextMenu {
                        if app.scopedAccounts.count > 1 {
                            ForEach(app.scopedAccounts) { account in
                                Button("Empty \(account.info.displayName) Recycle Bin…", role: .destructive) {
                                    confirmEmpty = account.id
                                }
                                .disabled(account.store.library.recycled.isEmpty)
                            }
                        } else if let account = app.scopedAccounts.first {
                            Button("Empty Recycle Bin…", role: .destructive) { confirmEmpty = account.id }
                                .disabled(account.store.library.recycled.isEmpty)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
    }

    /// The account whose Recycle Bin is about to be emptied.
    @State private var confirmEmpty: String?
    /// The row snippets are being dragged over.
    @State private var dropTarget: SidebarDropTarget?

    private var allCount: Int { app.accounts.reduce(0) { $0 + $1.store.library.own.count } }

    private var emptyTitle: String {
        guard app.hasMultipleAccounts, let id = confirmEmpty, let account = app.account(id) else {
            return "Delete all snippets in the Recycle Bin?"
        }
        return "Delete all snippets in \(account.info.displayName)'s Recycle Bin?"
    }

    @ViewBuilder
    private func row(_ item: SidebarItem, count: Int? = nil, account: AccountInfo? = nil) -> some View {
        let base = HStack(spacing: 6) {
            Label(item.title, systemImage: item.systemImage)
            if let account, app.hasMultipleAccounts, app.scope == .all {
                Spacer(minLength: 0)
                AccountBadge(info: account, showName: false)
            }
        }
        .badge(count ?? app.count(item))
        .tag(item)
        if SidebarDropTarget.accepts(item) {
            let target = SidebarDropTarget.item(item)
            base
                .listRowBackground(dropTarget == target ? Color.accentColor.opacity(0.25) : nil)
                .dropDestination(for: SnippetDrag.self) { drops, _ in
                    app.drop(drops.flatMap(\.refs), on: target, modifiers: NSEvent.modifierFlags)
                } isTargeted: { over in
                    dropTarget = over ? target : (dropTarget == target ? nil : dropTarget)
                }
                .help(dropHelp(item))
        } else {
            base
        }
    }

    private func dropHelp(_ item: SidebarItem) -> String {
        switch item {
        case .category: return "Drop snippets here to add this tag (hold ⌥ to replace their tags)"
        case .pinned: return "Drop snippets here to pin them"
        case .favorites: return "Drop snippets here to add them to Favorites"
        case .recycled: return "Drop snippets here to move them to the Recycle Bin"
        default: return ""
        }
    }
}

/// An account in the sidebar: click to show it, drop snippets on it to copy them there.
private struct AccountRow: View {
    let title: String
    let color: Color?
    let count: Int
    let current: Bool
    var targeted = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let color {
                Circle().fill(color).frame(width: 10, height: 10)
                    .frame(width: 18)
            } else {
                Image(systemName: "square.stack.3d.up").frame(width: 18)
            }
            Text(title).fontWeight(current ? .semibold : .regular)
            Spacer(minLength: 4)
            if current {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .listRowBackground(targeted ? Color.accentColor.opacity(0.25) : nil)
    }
}

struct SyncStatusBar: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(app.scopedAccounts) { account in
                AccountSyncRow(account: account, store: account.store, showName: app.hasMultipleAccounts)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct AccountSyncRow: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var account: Account
    @ObservedObject var store: SnippetStore
    let showName: Bool

    var body: some View {
        HStack(spacing: 6) {
            if showName {
                Circle().fill(account.info.color.color).frame(width: 7, height: 7)
            }
            if account.needsSignIn {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Button(showName ? "Sign in to \(account.info.displayName) again" : "Sign in again") {
                    app.beginSignInAgain(account.id)
                }
                .buttonStyle(.link)
            } else if store.isSyncing {
                ProgressView().controlSize(.small)
                Text(label("Syncing…"))
            } else if store.isOffline {
                Image(systemName: "wifi.slash")
                Text(label(store.outbox.isEmpty ? "Offline" : "Offline · \(store.outbox.count) pending"))
            } else if !store.outbox.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(label("\(store.outbox.count) pending"))
            } else if let last = store.library.lastSync {
                Image(systemName: "checkmark.circle")
                Text(label("Synced \(last.formatted(.relative(presentation: .named)))"))
            }
            Spacer()
            if !account.needsSignIn {
                Button {
                    Task { await store.sync() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Sync now (⌘R syncs every account)")
                .disabled(store.isSyncing)
            }
        }
        .lineLimit(1)
    }

    private func label(_ status: String) -> String {
        showName ? "\(account.info.displayName): \(status)" : status
    }
}
