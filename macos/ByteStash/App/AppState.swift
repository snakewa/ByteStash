import AppKit
import Combine
import SwiftUI

/// The accounts the user is signed in to (for example a personal and a work server), each
/// with its own store, plus what the main window shows.
///
/// Accounts never sync with each other. Content only moves between them when the user
/// copies or moves a snippet, and that always asks first.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case signedIn
    }

    @Published private(set) var accounts: [Account] = []
    @Published var scope: AccountScope = .all {
        didSet { saveScope() }
    }
    @Published var selection: SidebarItem? = .all
    @Published var selectedSnippet: SnippetRef?
    @Published var searchText = ""

    /// Shows the "Add Account" sheet; `reauthAccount` prefills it to sign in again.
    @Published var showAddAccount = false
    @Published private(set) var reauthAccount: AccountInfo?
    /// A copy or move to another account that is waiting for confirmation.
    @Published var pendingTransfer: SnippetTransfer?

    /// Snippets copied or opened most recently, across accounts.
    @Published private(set) var recent: [SnippetRef] = []

    var phase: Phase { accounts.isEmpty ? .signedOut : .signedIn }

    private let oidc = OIDCLogin()
    private var accountCancellables: [String: Set<AnyCancellable>] = [:]
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .snippetIDChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self,
                      let account = note.userInfo?["account"] as? String,
                      let old = note.userInfo?["old"] as? Int,
                      let new = note.userInfo?["new"] as? Int else { return }
                let oldRef = SnippetRef(account: account, id: old)
                let newRef = SnippetRef(account: account, id: new)
                if self.selectedSnippet == oldRef { self.selectedSnippet = newRef }
                if let index = self.recent.firstIndex(of: oldRef) {
                    self.recent[index] = newRef
                    self.saveRecent()
                }
            }
            .store(in: &cancellables)
        trackFrontmostApp()
        loadRecent()
        restore()
    }

    /// The last app other than ByteStash that was frontmost: where auto-paste goes.
    @Published private(set) var lastExternalApp: NSRunningApplication?

    private func trackFrontmostApp() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0 != NSRunningApplication.current }
            .receive(on: RunLoop.main)
            .sink { [weak self] app in self?.lastExternalApp = app }
            .store(in: &cancellables)
    }

    // MARK: Accounts

    var hasMultipleAccounts: Bool { accounts.count > 1 }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    func store(_ id: String) -> SnippetStore? { account(id)?.store }

    /// The accounts the main window currently shows.
    var scopedAccounts: [Account] {
        accounts.filter { scope.includes($0.id) }
    }

    /// Where new snippets go when the user doesn't pick an account: the one being viewed,
    /// else the default chosen in Settings, else the first account (normally "Personal").
    var defaultAccount: Account? {
        if case let .account(id) = scope, let account = self.account(id) { return account }
        return preferredAccount
    }

    /// The account chosen under Settings → Accounts, else the first one. Global hotkeys and
    /// the menu bar always use this, whatever the main window is showing.
    var preferredAccount: Account? {
        if let saved = UserDefaults.standard.string(forKey: "defaultAccount"), let account = self.account(saved) { return account }
        return accounts.first
    }

    var defaultAccountID: String {
        get { defaultAccountSetting ?? accounts.first?.id ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "defaultAccount")
            objectWillChange.send()
        }
    }

    private var defaultAccountSetting: String? {
        UserDefaults.standard.string(forKey: "defaultAccount").flatMap { id in account(id) == nil ? nil : id }
    }

    var lastServer: String { accounts.first?.info.server ?? UserDefaults.standard.string(forKey: "serverURL") ?? "" }

    func api(for accountID: String) -> APIClient? {
        guard let info = account(accountID)?.info, let url = info.serverURL else { return nil }
        return APIClient(baseURL: url, token: KeychainStore.load(account: info.id))
    }

    /// Kept for code that predates multiple accounts.
    static func accountKey(_ url: URL) -> String { AccountInfo.key(for: url) }

    /// Reopens every saved account from the keychain and disk cache, even when offline.
    private func restore() {
        let saved = AccountList.load()
        for info in saved {
            guard let token = KeychainStore.load(account: info.id) else { continue }
            attach(info: info, token: token)
        }
        // Accounts whose token is gone (signed out elsewhere) are dropped from the list.
        persistAccounts()
        if let data = UserDefaults.standard.data(forKey: "scope"),
           let saved = try? JSONDecoder().decode(AccountScope.self, from: data),
           case let .account(id) = saved, account(id) != nil {
            scope = saved
        }
        for account in accounts {
            Task { await verifySession(account) }
        }
    }

    private func verifySession(_ account: Account) async {
        guard let api = self.api(for: account.id) else { return }
        do {
            let fresh = try await api.verify()
            account.info.username = fresh.username
            account.info.userID = fresh.id
            account.store.currentUserID = fresh.id
            persistAccounts()
        } catch APIError.unauthorized {
            markNeedsSignIn(account)
        } catch {
            // Offline: keep working from the cache.
        }
    }

    /// Adds the account, or swaps in the new token when it is already in the list.
    private func attach(info: AccountInfo, token: String) {
        guard let url = info.serverURL else { return }
        KeychainStore.save(token, account: info.id)
        let api = APIClient(baseURL: url, token: token)

        if let existing = account(info.id) {
            existing.info.username = info.username
            existing.info.userID = info.userID
            existing.needsSignIn = false
            existing.store.updateAPI(api)
            existing.store.currentUserID = info.userID
            existing.store.startAutoSync()
            Task { await existing.store.sync() }
            persistAccounts()
            return
        }

        let store = SnippetStore(api: api, accountKey: info.id, persistsLibrary: info.keepsOfflineCache)
        store.currentUserID = info.userID
        let account = Account(info: info, store: store)
        store.onUnauthorized = { [weak self, weak account] in
            guard let self, let account else { return }
            self.markNeedsSignIn(account)
        }
        var bag = Set<AnyCancellable>()
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        account.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        accountCancellables[info.id] = bag
        accounts.append(account)
        persistAccounts()
        store.startAutoSync()
        Task { await store.sync() }
    }

    private func markNeedsSignIn(_ account: Account) {
        account.needsSignIn = true
        account.store.stopAutoSync()
    }

    private func persistAccounts() {
        AccountList.save(accounts.map { $0.info })
    }

    func updateInfo(_ accountID: String, _ change: (inout AccountInfo) -> Void) {
        guard let account = self.account(accountID) else { return }
        var info = account.info
        change(&info)
        account.info = info
        account.store.persistsLibrary = info.keepsOfflineCache
        persistAccounts()
    }

    func moveAccount(_ accountID: String, by offset: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let target = min(max(index + offset, 0), accounts.count - 1)
        guard target != index else { return }
        accounts.swapAt(index, target)
        persistAccounts()
    }

    func syncAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where !account.needsSignIn {
                let store = account.store
                group.addTask { await store.sync() }
            }
        }
    }

    // MARK: Sign in

    func beginAddAccount() {
        reauthAccount = nil
        showAddAccount = true
    }

    func beginSignInAgain(_ accountID: String) {
        reauthAccount = account(accountID)?.info
        showAddAccount = true
    }

    func signIn(server raw: String, username: String, password: String, name: String? = nil) async throws {
        guard let server = APIClient.normalize(serverURL: raw) else { throw APIError.invalidServerURL }
        let api = APIClient(baseURL: server)
        let response = try await api.login(username: username, password: password)
        try await finishSignIn(server: server, token: response.token, user: response.user, name: name)
    }

    func signInAnonymously(server raw: String, name: String? = nil) async throws {
        guard let server = APIClient.normalize(serverURL: raw) else { throw APIError.invalidServerURL }
        let response = try await APIClient(baseURL: server).anonymousLogin()
        try await finishSignIn(server: server, token: response.token, user: response.user, name: name)
    }

    func signInWithSSO(server raw: String, name: String? = nil) async throws {
        guard let server = APIClient.normalize(serverURL: raw) else { throw APIError.invalidServerURL }
        let token = try await oidc.start(url: APIClient(baseURL: server).oidcLoginURL)
        try await finishSignIn(server: server, token: token, user: nil, name: name)
    }

    private func finishSignIn(server: URL, token: String, user: User?, name: String?) async throws {
        var user = user
        if user == nil {
            user = try await APIClient(baseURL: server, token: token).verify()
        }
        guard let user else { throw APIError.unauthorized }
        let key = AccountInfo.key(for: server)
        let existing = accounts.map { $0.info }
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let info = AccountInfo(
            id: key,
            server: server.absoluteString,
            username: user.username,
            userID: user.id,
            name: trimmed.isEmpty ? AccountInfo.suggestedName(existing: existing) : trimmed,
            color: AccountInfo.suggestedColor(existing: existing)
        )
        attach(info: info, token: token)
        if !trimmed.isEmpty, account(key)?.info.name != trimmed {
            updateInfo(key) { $0.name = trimmed }
        }
        showAddAccount = false
        reauthAccount = nil
    }

    /// Signs out of one account and removes it from the app. With `clearCache`, its
    /// offline copy (and any changes not yet sent) is deleted too.
    func signOut(_ accountID: String, clearCache: Bool = false) {
        guard let account = self.account(accountID) else { return }
        KeychainStore.delete(account: accountID)
        account.store.stopAutoSync()
        if clearCache { account.store.clearCache() }
        accountCancellables[accountID] = nil
        accounts.removeAll { $0.id == accountID }
        persistAccounts()
        if selectedSnippet?.account == accountID { selectedSnippet = nil }
        if scope == .account(accountID) { scope = .all }
        if case let .group(_, _, owner) = selection, owner == accountID { selection = .all }
        recent.removeAll { $0.account == accountID }
        saveRecent()
    }

    private func saveScope() {
        if let data = try? JSONEncoder().encode(scope) {
            UserDefaults.standard.set(data, forKey: "scope")
        }
    }

    // MARK: Merged views

    func snippet(_ ref: SnippetRef) -> Snippet? {
        store(ref.account)?.library.snippet(id: ref.id)
    }

    func item(_ ref: SnippetRef) -> AccountSnippet? {
        snippet(ref).map { AccountSnippet(account: ref.account, snippet: $0) }
    }

    var selectedItem: AccountSnippet? { selectedSnippet.flatMap { self.item($0) } }

    /// The sidebar item's snippets from every account in scope, sorted together.
    func snippets(for item: SidebarItem, query: SearchQuery, sort: SortOrder) -> [AccountSnippet] {
        var result: [AccountSnippet] = []
        for account in scopedAccounts {
            if case let .group(_, _, owner) = item, owner != account.id { continue }
            result += account.store.library.snippets(for: item, query: query, sort: sort)
                .map { AccountSnippet(account: account.id, snippet: $0) }
        }
        return Library.sorted(result, by: sort, query: query, snippet: \.snippet)
    }

    func count(_ item: SidebarItem) -> Int {
        snippets(for: item, query: SearchQuery(""), sort: .updated).count
    }

    /// Everything searchable from the quick panel and the menu bar, across all accounts.
    var everything: [AccountSnippet] {
        accounts.flatMap { account in
            account.store.library.everything.map { AccountSnippet(account: account.id, snippet: $0) }
        }
    }

    var recentItems: [AccountSnippet] { recent.compactMap { self.item($0) } }

    var categoryCounts: [(name: String, count: Int)] {
        merged(scopedAccounts.map { $0.store.library.categoryCounts })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var languageCounts: [(name: String, count: Int)] {
        merged(scopedAccounts.map { $0.store.library.languageCounts })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private func merged(_ lists: [[(name: String, count: Int)]]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for list in lists {
            for entry in list { counts[entry.name, default: 0] += entry.count }
        }
        return counts.map { ($0.key, $0.value) }
    }

    func markUsed(_ item: AccountSnippet) {
        store(item.account)?.markUsed(item.snippet)
        recent.removeAll { $0 == item.id }
        recent.insert(item.id, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        saveRecent()
    }

    private func loadRecent() {
        if let data = UserDefaults.standard.data(forKey: "recentSnippets"),
           let saved = try? JSONDecoder().decode([SnippetRef].self, from: data) {
            recent = saved
        }
    }

    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: "recentSnippets")
        }
    }

    // MARK: Navigation helpers

    func reveal(_ ref: SnippetRef) {
        guard let store = self.store(ref.account) else { return }
        if !scope.includes(ref.account) { scope = .all }
        if store.library.own.contains(where: { $0.id == ref.id }) {
            selection = .all
        } else if store.library.shared.contains(where: { $0.id == ref.id }) {
            selection = .shared
        } else if store.library.publicFeed.contains(where: { $0.id == ref.id }) {
            selection = .publicFeed
        } else if store.library.recycled.contains(where: { $0.id == ref.id }) {
            selection = .recycled
        }
        searchText = ""
        selectedSnippet = ref
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Creates an empty snippet in `accountID`, or in the default account.
    func newSnippet(in accountID: String? = nil) {
        guard let account = accountID.flatMap({ self.account($0) }) ?? defaultAccount else { return }
        var categories: [String] = []
        var language = UserDefaults.standard.string(forKey: "defaultLanguage") ?? "plaintext"
        switch selection {
        case let .category(name): categories = [name]
        case let .language(name): language = name
        default: break
        }
        switch selection {
        case .recycled, .publicFeed, .shared, .group: selection = .all
        default: break
        }
        if !scope.includes(account.id) { scope = .all }
        let snippet = account.store.create(language: language, categories: categories)
        searchText = ""
        selectedSnippet = SnippetRef(account: account.id, id: snippet.id)
    }

    // MARK: Copy and move between accounts

    /// Asks for confirmation; `performTransfer` runs once the user agrees.
    func requestTransfer(_ item: AccountSnippet, to target: String, move: Bool) {
        guard item.account != target, account(target) != nil else { return }
        pendingTransfer = SnippetTransfer(source: item.id, target: target, move: move && canMove(item))
    }

    /// Only snippets you own can be moved; someone else's can only be copied.
    func canMove(_ item: AccountSnippet) -> Bool {
        guard let store = self.store(item.account) else { return false }
        return store.isOwn(item.snippet) && !item.snippet.isRecycled
    }

    func performTransfer(_ transfer: SnippetTransfer) {
        pendingTransfer = nil
        guard let source = store(transfer.source.account),
              let snippet = source.library.snippet(id: transfer.source.id),
              let target = store(transfer.target) else { return }
        let created = target.create(from: snippet.transferCopy())
        if transfer.move, source.isOwn(snippet) {
            source.moveToRecycleBin(snippet)
        }
        if !scope.includes(transfer.target) { scope = .all }
        selection = .all
        searchText = ""
        selectedSnippet = SnippetRef(account: transfer.target, id: created.id)
    }
}
