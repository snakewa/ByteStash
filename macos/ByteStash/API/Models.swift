import Foundation

/// SQLite booleans arrive as 0/1 from some endpoints and as true/false from others.
@propertyWrapper
struct FlexibleBool: Codable, Hashable, Sendable {
    var wrappedValue: Bool

    init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = false
        } else if let bool = try? container.decode(Bool.self) {
            wrappedValue = bool
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = int != 0
        } else if let string = try? container.decode(String.self) {
            wrappedValue = string == "1" || string.lowercased() == "true"
        } else {
            wrappedValue = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: FlexibleBool.Type, forKey key: Key) throws -> FlexibleBool {
        try decodeIfPresent(type, forKey: key) ?? FlexibleBool(wrappedValue: false)
    }
}

struct Fragment: Codable, Hashable, Identifiable, Sendable {
    /// Server id, or a local UUID-derived negative number for fragments not saved yet.
    var id: Int
    var fileName: String
    var code: String
    var language: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case code, language, position
    }

    init(id: Int = Fragment.newLocalID(), fileName: String, code: String, language: String, position: Int) {
        self.id = id
        self.fileName = fileName
        self.code = code
        self.language = language
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? Fragment.newLocalID()
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "plaintext"
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
    }

    static func newLocalID() -> Int { -Int.random(in: 1...Int(Int32.max)) }
}

struct ShareTarget: Codable, Hashable, Sendable {
    var type: String
    var id: Int
    var name: String?
    var permission: String
}

struct Snippet: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var title: String
    var description: String
    var updatedAt: Date
    var expiryDate: Date?
    var userID: Int?
    var username: String?
    @FlexibleBool var isPublic: Bool
    @FlexibleBool var isPinned: Bool
    @FlexibleBool var isFavorite: Bool
    var editPermission: String
    var categories: [String]
    var fragments: [Fragment]
    var shares: [ShareTarget]
    var visibility: String

    enum CodingKeys: String, CodingKey {
        case id, title, description
        case updatedAt = "updated_at"
        case expiryDate = "expiry_date"
        case userID = "user_id"
        case username
        case isPublic = "is_public"
        case isPinned = "is_pinned"
        case isFavorite = "is_favorite"
        case editPermission = "edit_permission"
        case categories, fragments, shares, visibility
    }

    init(
        id: Int,
        title: String,
        description: String = "",
        updatedAt: Date = Date(),
        expiryDate: Date? = nil,
        userID: Int? = nil,
        username: String? = nil,
        isPublic: Bool = false,
        isPinned: Bool = false,
        isFavorite: Bool = false,
        editPermission: String = "owner",
        categories: [String] = [],
        fragments: [Fragment] = [],
        shares: [ShareTarget] = [],
        visibility: String = "private"
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.updatedAt = updatedAt
        self.expiryDate = expiryDate
        self.userID = userID
        self.username = username
        self._isPublic = FlexibleBool(wrappedValue: isPublic)
        self._isPinned = FlexibleBool(wrappedValue: isPinned)
        self._isFavorite = FlexibleBool(wrappedValue: isFavorite)
        self.editPermission = editPermission
        self.categories = categories
        self.fragments = fragments
        self.shares = shares
        self.visibility = visibility
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date.distantPast
        expiryDate = try? c.decodeIfPresent(Date.self, forKey: .expiryDate)
        userID = try c.decodeIfPresent(Int.self, forKey: .userID)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        _isPublic = try c.decode(FlexibleBool.self, forKey: .isPublic)
        _isPinned = try c.decode(FlexibleBool.self, forKey: .isPinned)
        _isFavorite = try c.decode(FlexibleBool.self, forKey: .isFavorite)
        editPermission = try c.decodeIfPresent(String.self, forKey: .editPermission) ?? "owner"
        if let list = try? c.decodeIfPresent([String].self, forKey: .categories) {
            categories = list
        } else if let joined = try? c.decodeIfPresent(String.self, forKey: .categories) {
            categories = joined.split(separator: ",").map(String.init)
        } else {
            categories = []
        }
        fragments = (try c.decodeIfPresent([Fragment].self, forKey: .fragments) ?? [])
            .sorted { $0.position < $1.position }
        shares = (try? c.decodeIfPresent([ShareTarget].self, forKey: .shares)) ?? []
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
            ?? (_isPublic.wrappedValue ? "public" : (shares.isEmpty ? "private" : "protected"))
    }

    var isRecycled: Bool { expiryDate != nil }
    var isLocked: Bool { editPermission == "readonly" }

    /// Languages used by the fragments, in order, without duplicates.
    var languages: [String] {
        var seen = Set<String>()
        return fragments.map(\.language).filter { seen.insert($0).inserted }
    }

    var primaryLanguage: String { fragments.first?.language ?? "plaintext" }

    /// First non-empty line of code, for list previews.
    var preview: String {
        for fragment in fragments {
            if let line = fragment.code.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                return line
            }
        }
        return ""
    }

    static func newDraft(id: Int, language: String = "plaintext") -> Snippet {
        Snippet(
            id: id,
            title: "Untitled snippet",
            fragments: [Fragment(fileName: "main", code: "", language: language, position: 0)]
        )
    }
}

/// Body for POST/PUT /api/snippets. Sharing is left untouched unless `visibility` is set.
struct SnippetPayload: Codable, Hashable, Sendable {
    struct FragmentPayload: Codable, Hashable, Sendable {
        var file_name: String
        var code: String
        var language: String
        var position: Int
    }

    var title: String
    var description: String
    var categories: [String]
    var fragments: [FragmentPayload]
    var visibility: String?
    var is_public: Bool?

    init(_ snippet: Snippet, includeVisibility: Bool) {
        title = snippet.title
        description = snippet.description
        categories = snippet.categories
        fragments = snippet.fragments.enumerated().map { index, fragment in
            FragmentPayload(
                file_name: fragment.fileName.isEmpty ? "file\(index + 1)" : fragment.fileName,
                code: fragment.code,
                language: fragment.language,
                position: index
            )
        }
        if includeVisibility, snippet.visibility != "protected" {
            visibility = snippet.visibility
            is_public = snippet.visibility == "public"
        }
    }
}

struct Pagination: Codable, Sendable {
    var total: Int
    var offset: Int
    var limit: Int
    var hasMore: Bool
}

struct SnippetPage: Codable, Sendable {
    var data: [Snippet]
    var pagination: Pagination?
}

struct User: Codable, Hashable, Sendable {
    var id: Int
    var username: String
    @FlexibleBool var isAdmin: Bool

    enum CodingKeys: String, CodingKey {
        case id, username
        case isAdmin = "is_admin"
    }

    init(id: Int, username: String, isAdmin: Bool = false) {
        self.id = id
        self.username = username
        self._isAdmin = FlexibleBool(wrappedValue: isAdmin)
    }
}

struct AuthConfig: Codable, Sendable {
    var allowNewAccounts: Bool?
    var hasUsers: Bool?
    var disableAccounts: Bool?
    var disableInternalAccounts: Bool?
}

struct OIDCConfig: Codable, Sendable {
    var enabled: Bool?
    var displayName: String?
}

struct LoginResponse: Codable, Sendable {
    var token: String
    var user: User?
}

struct VerifyResponse: Codable, Sendable {
    var valid: Bool
    var user: User?
}

struct ShareLink: Codable, Sendable {
    var id: String
}

enum BSDate {
    /// Server timestamps look like "2026-10-30 08:20:57Z" (SQLite datetime + Z) or ISO 8601.
    static func parse(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        let sqlite = DateFormatter()
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        sqlite.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd HH:mm:ss"] {
            sqlite.dateFormat = format
            if let date = sqlite.date(from: string) { return date }
        }
        return nil
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(string)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
