import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if app.phase == .signedIn, let store = app.store {
                MainView()
                    .environmentObject(store)
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
    @EnvironmentObject private var store: SnippetStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            SnippetListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
        } detail: {
            if let id = app.selectedSnippetID, let snippet = store.library.snippet(id: id) {
                SnippetDetailView(snippet: snippet)
                    .id(snippet.id)
            } else {
                ContentUnavailableView("No Snippet Selected", systemImage: "curlybraces",
                                       description: Text("Pick a snippet, or press ⌘N to create one."))
            }
        }
        .alert("Couldn't sync", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: app.selection) { _, _ in
            if let id = app.selectedSnippetID,
               let selection = app.selection,
               !store.library.snippets(for: selection, query: SearchQuery(app.searchText), sort: .updated).contains(where: { $0.id == id }) {
                app.selectedSnippetID = nil
            }
        }
    }
}
