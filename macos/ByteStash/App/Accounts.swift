import Combine
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A color that marks which account a snippet belongs to.
enum AccountColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, green, orange, purple, pink, teal, gray

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}

/// What the app remembers about one signed-in server account. The token lives in the
/// keychain under `id`, and the offline cache in Application Support under the same name.
struct AccountInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var server: String
    var username: String
    var userID: Int
    /// The user's own label, such as "Personal" or "Work".
    var name: String
    var color: AccountColor
    /// When off, this account's snippets are only kept in memory, never written to disk.
    var keepsOfflineCache: Bool

    init(id: String, server: String, username: String, userID: Int, name: String,
         color: AccountColor, keepsOfflineCache: Bool = true) {
        self.id = id
        self.server = server
        self.username = username
        self.userID = userID
        self.name = name
        self.color = color
        self.keepsOfflineCache = keepsOfflineCache
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        server = try c.decode(String.self, forKey: .server)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        userID = try c.decodeIfPresent(Int.self, forKey: .userID) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? c.decodeIfPresent(AccountColor.self, forKey: .color)) ?? .blue
        keepsOfflineCache = try c.decodeIfPresent(Bool.self, forKey: .keepsOfflineCache) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, server, username, userID, name, color, keepsOfflineCache
    }

    var serverURL: URL? { APIClient.normalize(serverURL: server) }

    /// "Work", or the server's host when the user hasn't named the account.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return serverURL?.host ?? server
    }

    /// Keychain and cache key for a server URL.
    static func key(for url: URL) -> String {
        let raw = (url.host ?? "server") + (url.port.map { "-\($0)" } ?? "") + url.path
        return raw.replacingOccurrences(of: "/", with: "_")
    }

    /// A name and color for a new account that don't clash with the existing ones.
    static func suggestedName(existing: [AccountInfo]) -> String {
        existing.isEmpty ? "Personal" : (existing.contains { $0.name == "Work" } ? "" : "Work")
    }

    static func suggestedColor(existing: [AccountInfo]) -> AccountColor {
        let used = Set(existing.map(\.color))
        let order: [AccountColor] = [.blue, .orange, .green, .purple, .pink, .teal, .gray]
        return order.first { !used.contains($0) } ?? .gray
    }
}

/// Saved account list, with a one-time import of the single account older versions kept
/// under separate UserDefaults keys.
enum AccountList {
    static let defaultsKey = "accounts"

    static func load(from defaults: UserDefaults = .standard) -> [AccountInfo] {
        if let data = defaults.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([AccountInfo].self, from: data) {
            return list
        }
        return legacy(from: defaults).map { [$0] } ?? []
    }

    static func save(_ list: [AccountInfo], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// The account a pre-multi-account version was signed in to, if any.
    static func legacy(from defaults: UserDefaults) -> AccountInfo? {
        guard let raw = defaults.string(forKey: "serverURL"), let url = APIClient.normalize(serverURL: raw) else { return nil }
        return AccountInfo(id: AccountInfo.key(for: url), server: url.absoluteString,
                           username: defaults.string(forKey: "username") ?? "",
                           userID: defaults.integer(forKey: "userID"),
                           name: "Personal", color: .blue)
    }
}

/// One signed-in account: its settings plus its own store, outbox and cache.
@MainActor
final class Account: ObservableObject, Identifiable {
    @Published var info: AccountInfo
    /// The server rejected the saved token. The cache stays visible until the user signs in again.
    @Published var needsSignIn = false
    let store: SnippetStore

    let id: String

    init(info: AccountInfo, store: SnippetStore) {
        self.id = info.id
        self.info = info
        self.store = store
    }
}

/// Snippet ids are only unique per server, so the app names a snippet by account and id.
struct SnippetRef: Hashable, Codable, Sendable {
    var account: String
    var id: Int
}

/// A snippet together with the account it came from, for lists that mix accounts.
struct AccountSnippet: Identifiable, Hashable {
    let account: String
    let snippet: Snippet

    var id: SnippetRef { SnippetRef(account: account, id: snippet.id) }
}

/// Which accounts the main window shows: all of them merged, or just one.
enum AccountScope: Hashable, Codable {
    case all
    case account(String)

    func includes(_ accountID: String) -> Bool {
        switch self {
        case .all: return true
        case let .account(id): return id == accountID
        }
    }
}

/// A copy or move of a snippet to another account, waiting for the user to confirm it.
/// A copy or move of one or more snippets to another account, waiting for the user to
/// confirm it. With `move`, snippets you own are moved and the rest are copied.
struct SnippetTransfer: Identifiable, Equatable {
    let sources: [SnippetRef]
    let target: String
    let move: Bool
    let id = UUID()
}

extension Snippet {
    /// The copy that a transfer creates on the other server: same content and tags, but a
    /// fresh private snippet. Sharing, pins and favorites belong to the old server's users
    /// and groups, so they don't carry over.
    func transferCopy() -> Snippet {
        var copy = self
        copy.id = Fragment.newLocalID()
        copy.userID = nil
        copy.username = nil
        copy.isPinned = false
        copy.isFavorite = false
        copy.isPublic = false
        copy.visibility = "private"
        copy.shares = []
        copy.editPermission = "owner"
        copy.expiryDate = nil
        copy.fragments = fragments.map { var f = $0; f.id = Fragment.newLocalID(); return f }
        return copy
    }
}

/// A small colored dot plus the account name, shown when more than one account is signed in.
struct AccountBadge: View {
    let info: AccountInfo
    var showName = true

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(info.color.color).frame(width: 7, height: 7)
            if showName {
                Text(info.displayName).lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help("\(info.displayName) · \(info.username) on \(info.serverURL?.host ?? info.server)")
    }
}

extension UTType {
    /// Snippets dragged inside the app (declared in Info.plist).
    static let byteStashSnippets = UTType(exportedAs: "app.bytestash.mac.snippets")
}

/// What a dragged snippet (or selection) carries: references for drops inside the app, and
/// the code as plain text for drops into other apps.
struct SnippetDrag: Codable, Transferable {
    var refs: [SnippetRef]
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .byteStashSnippets)
        ProxyRepresentation(exporting: \.text)
    }
}
