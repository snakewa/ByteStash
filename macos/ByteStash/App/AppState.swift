import AppKit
import Combine
import SwiftUI

/// Who is signed in to which server, plus the store for that account.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case signedIn
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var user: User?
    @Published private(set) var serverURL: URL?
    @Published private(set) var store: SnippetStore?
    @Published var selection: SidebarItem? = .all
    @Published var selectedSnippetID: Int?
    @Published var searchText = ""

    private var savedServer: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverURL") }
    }
    private var savedUsername: String {
        get { UserDefaults.standard.string(forKey: "username") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "username") }
    }
    private var savedUserID: Int {
        get { UserDefaults.standard.integer(forKey: "userID") }
        set { UserDefaults.standard.set(newValue, forKey: "userID") }
    }

    private let oidc = OIDCLogin()
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .snippetIDChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self,
                      let old = note.userInfo?["old"] as? Int,
                      let new = note.userInfo?["new"] as? Int,
                      self.selectedSnippetID == old else { return }
                self.selectedSnippetID = new
            }
            .store(in: &idCancellables)
        restore()
    }

    private var idCancellables = Set<AnyCancellable>()

    var api: APIClient? {
        guard let serverURL else { return nil }
        return APIClient(baseURL: serverURL, token: KeychainStore.load(account: Self.accountKey(serverURL)))
    }

    var lastServer: String { savedServer }

    static func accountKey(_ url: URL) -> String {
        let raw = (url.host ?? "server") + (url.port.map { "-\($0)" } ?? "") + url.path
        return raw.replacingOccurrences(of: "/", with: "_")
    }

    /// Reopens the last session from the keychain and disk cache, even when offline.
    private func restore() {
        guard let url = APIClient.normalize(serverURL: savedServer),
              let token = KeychainStore.load(account: Self.accountKey(url)) else { return }
        let user = User(id: savedUserID, username: savedUsername)
        activate(server: url, token: token, user: user)
        Task { await verifySession() }
    }

    private func verifySession() async {
        guard let api else { return }
        do {
            let fresh = try await api.verify()
            user = fresh
            savedUsername = fresh.username
            savedUserID = fresh.id
            store?.currentUserID = fresh.id
        } catch APIError.unauthorized {
            signOut(keepServer: true)
        } catch {
            // Offline: keep working from the cache.
        }
    }

    private func activate(server: URL, token: String, user: User) {
        KeychainStore.save(token, account: Self.accountKey(server))
        savedServer = server.absoluteString
        savedUsername = user.username
        savedUserID = user.id
        serverURL = server
        self.user = user

        let store = SnippetStore(api: APIClient(baseURL: server, token: token), accountKey: Self.accountKey(server))
        store.currentUserID = user.id
        store.onUnauthorized = { [weak self] in self?.signOut(keepServer: true) }
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.store = store
        phase = .signedIn
        store.startAutoSync()
        Task { await store.sync() }
    }

    // MARK: Sign in

    func signIn(server raw: String, username: String, password: String) async throws {
        guard let server = APIClient.normalize(serverURL: raw) else { throw APIError.invalidServerURL }
        let api = APIClient(baseURL: server)
        let response = try await api.login(username: username, password: password)
        try await finishSignIn(server: server, token: response.token, user: response.user)
    }

    func signInAnonymously(server raw: String) async throws {
        guard let server = APIClient.normalize(serverURL: raw) else { throw APIError.invalidServerURL }
        let response = try await APIClient(baseURL: server).anonymousLogin()
        try await finishSignIn(server: server, token: response.token, user: response.user)
    }

    func signInWithSSO(server raw: String) async throws {
        guard let server = APIClient.normalize(serverURL: raw) else { throw APIError.invalidServerURL }
        let token = try await oidc.start(url: APIClient(baseURL: server).oidcLoginURL)
        try await finishSignIn(server: server, token: token, user: nil)
    }

    private func finishSignIn(server: URL, token: String, user: User?) async throws {
        var user = user
        if user == nil {
            user = try await APIClient(baseURL: server, token: token).verify()
        }
        guard let user else { throw APIError.unauthorized }
        if let previous = serverURL, previous != server {
            KeychainStore.delete(account: Self.accountKey(previous))
        }
        activate(server: server, token: token, user: user)
    }

    func signOut(keepServer: Bool = true) {
        if let serverURL { KeychainStore.delete(account: Self.accountKey(serverURL)) }
        store?.stopAutoSync()
        if !keepServer { store?.clearCache() }
        cancellables.removeAll()
        store = nil
        user = nil
        selectedSnippetID = nil
        phase = .signedOut
        if !keepServer { savedServer = "" }
    }

    // MARK: Navigation helpers

    func reveal(_ snippetID: Int) {
        guard let store else { return }
        if store.library.own.contains(where: { $0.id == snippetID }) {
            selection = .all
        } else if store.library.shared.contains(where: { $0.id == snippetID }) {
            selection = .shared
        } else if store.library.publicFeed.contains(where: { $0.id == snippetID }) {
            selection = .publicFeed
        }
        searchText = ""
        selectedSnippetID = snippetID
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func newSnippet() {
        guard let store else { return }
        var categories: [String] = []
        var language = UserDefaults.standard.string(forKey: "defaultLanguage") ?? "plaintext"
        switch selection {
        case let .category(name): categories = [name]
        case let .language(name): language = name
        default: break
        }
        if selection == .recycled || selection == .publicFeed || selection == .shared {
            selection = .all
        }
        let snippet = store.create(language: language, categories: categories)
        searchText = ""
        selectedSnippetID = snippet.id
    }
}
