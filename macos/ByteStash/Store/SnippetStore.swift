import Foundation
import Combine

/// The signed-in user's snippets: cached on disk, changed optimistically, and synced with
/// the server through an outbox.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var outbox = Outbox()
    @Published private(set) var isSyncing = false
    @Published private(set) var isOffline = false
    @Published var lastError: String?

    /// Called when the server says the token is no longer valid.
    var onUnauthorized: (() -> Void)?

    private var api: APIClient
    private let cacheDirectory: URL
    private var flushTask: Task<Void, Never>?
    private var pollTimer: Timer?

    init(api: APIClient, accountKey: String) {
        self.api = api
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDirectory = base.appendingPathComponent("ByteStash/\(accountKey)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    var currentUserID: Int?

    func updateAPI(_ api: APIClient) { self.api = api }

    // MARK: Disk cache

    private var libraryFile: URL { cacheDirectory.appendingPathComponent("library.json") }
    private var outboxFile: URL { cacheDirectory.appendingPathComponent("outbox.json") }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: libraryFile),
           let cached = try? BSDate.decoder.decode(Library.self, from: data) {
            library = cached
        }
        if let data = try? Data(contentsOf: outboxFile),
           let cached = try? BSDate.decoder.decode(Outbox.self, from: data) {
            outbox = cached
        }
    }

    private func saveLibrary() {
        let snapshot = library
        let file = libraryFile
        Task.detached(priority: .utility) {
            if let data = try? BSDate.encoder.encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private func saveOutbox() {
        if let data = try? BSDate.encoder.encode(outbox) {
            try? data.write(to: outboxFile, options: .atomic)
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        library = Library()
        outbox = Outbox()
    }

    // MARK: Sync

    /// Sends pending changes, then reloads everything from the server.
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await flush()
        guard outbox.isEmpty else { return } // still offline or blocked; keep local state

        let api = self.api
        do {
            async let own = api.ownSnippets()
            async let recycled = api.recycledSnippets()
            async let shared = api.sharedSnippets()
            async let publicFeed = api.publicSnippets()
            let (o, r) = try await (own, recycled)
            // Shared and public lists are optional extras; older servers lack /api/groups.
            let s = (try? await shared) ?? library.shared
            let p = (try? await publicFeed) ?? library.publicFeed
            // A change made while the request was in flight wins over the fetched copy.
            guard outbox.isEmpty else { return }
            library = Library(own: o, recycled: r, shared: s, publicFeed: p, lastSync: Date())
            isOffline = false
            saveLibrary()
        } catch {
            handle(error)
        }
    }

    func startAutoSync(every interval: TimeInterval = 120) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }

    func stopAutoSync() {
        pollTimer?.invalidate()
        pollTimer = nil
        flushTask?.cancel()
    }

    private func scheduleFlush(after delay: TimeInterval = 0.8) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends queued changes in order. Stops at the first one that can't be sent yet.
    func flush() async {
        while let change = outbox.first {
            do {
                try await send(change)
                outbox.removeFirst()
                isOffline = false
            } catch let error as APIError where error.isTransient {
                isOffline = error == .offline
                break
            } catch APIError.unauthorized {
                handle(APIError.unauthorized)
                break
            } catch {
                // The server rejected it (deleted elsewhere, no permission, ...). Drop it and
                // tell the user; the next sync restores the server's version.
                outbox.removeFirst()
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            saveOutbox()
        }
        saveOutbox()
        saveLibrary()
    }

    private func send(_ change: PendingChange) async throws {
        switch change {
        case let .create(tempID, payload):
            let created = try await api.create(payload)
            outbox.replaceID(tempID, with: created.id)
            replaceLocal(id: tempID) { local in
                var merged = created
                merged.isPinned = local.isPinned
                merged.isFavorite = local.isFavorite
                return merged
            }
            NotificationCenter.default.post(name: .snippetIDChanged, object: nil, userInfo: ["old": tempID, "new": created.id])
        case let .update(id, payload):
            let updated = try await api.update(id: id, payload)
            // Keep the local copy if the user kept typing after this request went out.
            if !outbox.changes.dropFirst().contains(where: { $0.snippetID == id }) {
                replaceLocal(id: id) { local in
                    var merged = updated
                    merged.isPinned = local.isPinned
                    merged.isFavorite = local.isFavorite
                    return merged
                }
            }
        case let .recycle(id): try await api.recycle(id: id)
        case let .restore(id): try await api.restore(id: id)
        case let .delete(id): try await api.delete(id: id)
        case let .pin(id, value): try await api.setPinned(id: id, value)
        case let .favorite(id, value): try await api.setFavorite(id: id, value)
        }
    }

    private func handle(_ error: Error) {
        switch error {
        case APIError.offline:
            isOffline = true
        case APIError.unauthorized:
            onUnauthorized?()
        default:
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Local edits

    private func replaceLocal(id: Int, _ transform: (Snippet) -> Snippet) {
        func apply(_ list: inout [Snippet]) {
            if let index = list.firstIndex(where: { $0.id == id }) { list[index] = transform(list[index]) }
        }
        apply(&library.own)
        apply(&library.recycled)
        apply(&library.shared)
        apply(&library.publicFeed)
    }

    private func commit(_ change: PendingChange, flushDelay: TimeInterval = 0) {
        outbox.enqueue(change)
        saveOutbox()
        saveLibrary()
        scheduleFlush(after: flushDelay)
    }

    func canEdit(_ snippet: Snippet) -> Bool {
        if snippet.isRecycled || snippet.isLocked { return false }
        if snippet.id < 0 || library.own.contains(where: { $0.id == snippet.id }) { return true }
        guard let me = currentUserID else { return false }
        if snippet.userID == me { return true }
        return !snippet.isPublic && snippet.shares.contains { $0.permission == "edit" && ($0.type == "group" || $0.id == me) }
    }

    func isOwn(_ snippet: Snippet) -> Bool {
        snippet.id < 0 || library.own.contains { $0.id == snippet.id } || library.recycled.contains { $0.id == snippet.id }
    }

    @discardableResult
    func create(from template: Snippet? = nil, language: String = "plaintext", categories: [String] = []) -> Snippet {
        var snippet = template ?? Snippet.newDraft(id: Fragment.newLocalID(), language: language)
        snippet.id = Fragment.newLocalID()
        snippet.updatedAt = Date()
        snippet.userID = currentUserID
        if template == nil { snippet.categories = categories }
        library.own.insert(snippet, at: 0)
        commit(.create(tempID: snippet.id, payload: SnippetPayload(snippet, includeVisibility: true)))
        return snippet
    }

    /// Saves edits to title, description, categories, fragments or visibility.
    func save(_ snippet: Snippet, visibilityChanged: Bool = false) {
        var edited = snippet
        edited.updatedAt = Date()
        replaceLocal(id: snippet.id) { _ in edited }
        let payload = SnippetPayload(edited, includeVisibility: visibilityChanged || snippet.id < 0)
        commit(.update(id: snippet.id, payload: payload), flushDelay: 1.0)
    }

    func setPinned(_ snippet: Snippet, _ value: Bool) {
        replaceLocal(id: snippet.id) { var s = $0; s.isPinned = value; return s }
        commit(.pin(id: snippet.id, value: value))
    }

    func setFavorite(_ snippet: Snippet, _ value: Bool) {
        replaceLocal(id: snippet.id) { var s = $0; s.isFavorite = value; return s }
        commit(.favorite(id: snippet.id, value: value))
    }

    func moveToRecycleBin(_ snippet: Snippet) {
        guard let index = library.own.firstIndex(where: { $0.id == snippet.id }) else { return }
        var recycled = library.own.remove(at: index)
        if snippet.id < 0 {
            commit(.delete(id: snippet.id))
            return
        }
        recycled.expiryDate = Date().addingTimeInterval(30 * 24 * 3600)
        library.recycled.insert(recycled, at: 0)
        library.shared.removeAll { $0.id == snippet.id }
        library.publicFeed.removeAll { $0.id == snippet.id }
        commit(.recycle(id: snippet.id))
    }

    func restore(_ snippet: Snippet) {
        guard let index = library.recycled.firstIndex(where: { $0.id == snippet.id }) else { return }
        var restored = library.recycled.remove(at: index)
        restored.expiryDate = nil
        library.own.insert(restored, at: 0)
        commit(.restore(id: snippet.id))
    }

    func deleteForever(_ snippet: Snippet) {
        library.recycled.removeAll { $0.id == snippet.id }
        library.own.removeAll { $0.id == snippet.id }
        commit(.delete(id: snippet.id))
    }

    func emptyRecycleBin() {
        for snippet in library.recycled { deleteForever(snippet) }
    }

    func duplicate(_ snippet: Snippet) -> Snippet {
        var copy = snippet
        copy.title = snippet.title + " copy"
        copy.isPinned = false
        copy.isFavorite = false
        copy.visibility = "private"
        copy.isPublic = false
        copy.shares = []
        copy.editPermission = "owner"
        copy.expiryDate = nil
        copy.fragments = snippet.fragments.map { var f = $0; f.id = Fragment.newLocalID(); return f }
        return create(from: copy)
    }

    func createShareLink(for snippet: Snippet, requiresAuth: Bool, expiresInSeconds: Int?) async throws -> URL {
        try await api.createShareLink(snippetID: snippet.id, requiresAuth: requiresAuth, expiresInSeconds: expiresInSeconds)
    }

    func webURL(for snippet: Snippet) -> URL { api.webURL(for: snippet.id) }
}

extension Notification.Name {
    /// Posted when a snippet created offline gets its real server id. userInfo: old, new.
    static let snippetIDChanged = Notification.Name("ByteStashSnippetIDChanged")
}
