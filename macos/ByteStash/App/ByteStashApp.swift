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
        guard let store = state.store, let last = store.library.lastSync, Date().timeIntervalSince(last) > 30 else { return }
        Task { await store.sync() }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState
    let quickSearch: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Snippet") { state.newSnippet() }
                .keyboardShortcut("n")
                .disabled(state.store == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Quick Search…") { quickSearch() }
                .keyboardShortcut("k")
            Divider()
            Button("Sync Now") { Task { await state.store?.sync() } }
                .keyboardShortcut("r")
                .disabled(state.store == nil)
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
            let snippet = state.selectedSnippetID.flatMap { state.store?.library.snippet(id: $0) }
            Button("Copy Code") { Clipboard.copy(snippet?.fragments.first?.code ?? "") }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(snippet == nil)
            Button(snippet?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let snippet { state.store?.setFavorite(snippet, !snippet.isFavorite) }
            }
            .keyboardShortcut("d")
            .disabled(snippet == nil || snippet.map { state.store?.isOwn($0) != true } == true)
            Button(snippet?.isPinned == true ? "Unpin" : "Pin") {
                if let snippet { state.store?.setPinned(snippet, !snippet.isPinned) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(snippet == nil || snippet.map { state.store?.isOwn($0) != true } == true)
            Divider()
            Button("Move to Recycle Bin") {
                if let snippet { state.store?.moveToRecycleBin(snippet) }
            }
            .disabled(snippet == nil || snippet?.isRecycled == true || snippet.map { state.store?.isOwn($0) != true } == true)
        }
        CommandGroup(after: .sidebar) {
            Button("All Snippets") { state.selection = .all }.keyboardShortcut("1")
            Button("Favorites") { state.selection = .favorites }.keyboardShortcut("2")
            Button("Shared with Me") { state.selection = .shared }.keyboardShortcut("3")
            Button("Recycle Bin") { state.selection = .recycled }.keyboardShortcut("4")
        }
    }
}
