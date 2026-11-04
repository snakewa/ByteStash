import SwiftUI

@main
struct ByteStashApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup("ByteStash", id: "main") {
            RootView()
                .environmentObject(appDelegate.state)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { AppCommands(state: appDelegate.state, quickSearch: { appDelegate.quickSearch?.show() }) }

        MenuBarExtra("ByteStash", systemImage: "curlybraces.square", isInserted: $showMenuBarIcon) {
            MenuBarPanel(newFromClipboard: { appDelegate.quickSearch?.newFromClipboard() })
                .environmentObject(appDelegate.state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) var quickSearch: QuickSearchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quickSearch = QuickSearchController(state: state)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for account in state.accounts where !account.needsSignIn {
            let store = account.store
            guard let last = store.library.lastSync, Date().timeIntervalSince(last) > 30 else { continue }
            Task { await store.sync() }
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState
    let quickSearch: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Snippet") { state.newSnippet() }
                .keyboardShortcut("n")
                .disabled(state.accounts.isEmpty)
            if state.hasMultipleAccounts {
                Menu("New Snippet in") {
                    ForEach(state.accounts) { account in
                        Button(account.info.displayName) { state.newSnippet(in: account.id) }
                    }
                }
            }
        }
        CommandGroup(after: .newItem) {
            Button("Quick Search…") { quickSearch() }
                .keyboardShortcut("k")
            Divider()
            Button("Sync Now") { Task { await state.syncAll() } }
                .keyboardShortcut("r")
                .disabled(state.accounts.isEmpty)
            Divider()
            Button("Add Account…") {
                NSApp.activate(ignoringOtherApps: true)
                state.beginAddAccount()
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Find Snippets") {
                NSApp.keyWindow?.toolbar?.items
                    .compactMap { $0 as? NSSearchToolbarItem }
                    .first?.beginSearchInteraction()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandMenu("Snippet") {
            // Every command here acts on the whole selection.
            let items = state.selectedItems
            let live = items.filter { !$0.snippet.isRecycled }
            let ownLive = live.filter { state.canMove($0) }
            let allFavorite = !ownLive.isEmpty && ownLive.allSatisfy(\.snippet.isFavorite)
            let allPinned = !ownLive.isEmpty && ownLive.allSatisfy(\.snippet.isPinned)
            Button(items.count > 1 ? "Copy Code of \(items.count) Snippets" : "Copy Code") { state.copyCode(items) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(items.isEmpty)
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") { state.setFavorite(ownLive, !allFavorite) }
                .keyboardShortcut("d")
                .disabled(ownLive.isEmpty)
            Button(allPinned ? "Unpin" : "Pin") { state.setPinned(ownLive, !allPinned) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(ownLive.isEmpty)
            if state.hasMultipleAccounts, !live.isEmpty {
                Divider()
                Menu("Copy to") {
                    ForEach(state.accounts) { account in
                        Button(account.info.displayName + "…") { state.requestTransfer(live, to: account.id, move: false) }
                            .disabled(!live.contains { $0.account != account.id })
                    }
                }
                Menu("Move to") {
                    ForEach(state.accounts) { account in
                        Button(account.info.displayName + "…") { state.requestTransfer(live, to: account.id, move: true) }
                            .disabled(!live.contains { $0.account != account.id })
                    }
                }
                .disabled(ownLive.isEmpty)
            }
            Divider()
            Button("Move to Recycle Bin") { state.recycle(ownLive) }
                .disabled(ownLive.isEmpty)
        }
        CommandGroup(before: .sidebar) {
            Button("as List") { UserDefaults.standard.set("list", forKey: "listLayout") }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("as Grid") { UserDefaults.standard.set("grid", forKey: "listLayout") }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(after: .sidebar) {
            if state.hasMultipleAccounts {
                Button("All Accounts") { state.scope = .all }
                    .keyboardShortcut("0", modifiers: [.command, .control])
                ForEach(Array(state.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                    Button(account.info.displayName) { state.scope = .account(account.id) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                }
                Divider()
            }
            Button("All Snippets") { state.selection = .all }.keyboardShortcut("1")
            Button("Favorites") { state.selection = .favorites }.keyboardShortcut("2")
            Button("Shared with Me") { state.selection = .shared }.keyboardShortcut("3")
            Button("Recycle Bin") { state.selection = .recycled }.keyboardShortcut("4")
        }
    }
}
