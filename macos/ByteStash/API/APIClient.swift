import Foundation

enum APIError: LocalizedError, Equatable {
    case invalidServerURL
    case unauthorized
    case notFound
    case offline
    case server(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "The server address is not a valid URL."
        case .unauthorized: return "Your session has expired. Sign in again."
        case .notFound: return "Not found, or you don't have permission."
        case .offline: return "The server can't be reached."
        case let .server(status, message): return message.isEmpty ? "Server error (\(status))." : message
        case let .decoding(detail): return "Unexpected response from the server: \(detail)"
        }
    }

    /// Errors that mean "try again later" rather than "this change will never work".
    var isTransient: Bool {
        switch self {
        case .offline: return true
        case let .server(status, _): return status >= 500
        default: return false
        }
    }
}

/// Thin wrapper over the ByteStash REST API (`/api/...`). Stateless apart from the token.
struct APIClient: Sendable {
    let baseURL: URL
    var token: String?
    var session: URLSession = .shared

    /// Accepts "snippets.example.com", "http://host:5000" or a URL with a base path.
    static func normalize(serverURL raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    // MARK: Auth

    func authConfig() async throws -> AuthConfig {
        try await get("api/auth/config", authenticated: false)
    }

    func oidcConfig() async throws -> OIDCConfig {
        try await get("api/auth/oidc/config", authenticated: false)
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        try await send("POST", "api/auth/login", body: ["username": username, "password": password], authenticated: false)
    }

    func anonymousLogin() async throws -> LoginResponse {
        try await send("POST", "api/auth/anonymous", body: [String: String](), authenticated: false)
    }

    func verify() async throws -> User {
        let response: VerifyResponse = try await get("api/auth/verify")
        guard response.valid, let user = response.user else { throw APIError.unauthorized }
        return user
    }

    /// Page the browser should open to start an OIDC login that ends at bytestash://auth/callback.
    var oidcLoginURL: URL { url("api/auth/oidc/auth", query: ["client": "desktop"]) }

    // MARK: Snippets

    /// Fetches every page of a list endpoint (the server caps a page at 100).
    func allSnippets(_ path: String, query: [String: String] = [:]) async throws -> [Snippet] {
        var result: [Snippet] = []
        var offset = 0
        while true {
            var q = query
            q["limit"] = "100"
            q["offset"] = String(offset)
            let page: SnippetPage = try await get(path, query: q)
            result.append(contentsOf: page.data)
            offset += page.data.count
            guard let pagination = page.pagination, pagination.hasMore, !page.data.isEmpty else { break }
        }
        return result
    }

    func ownSnippets() async throws -> [Snippet] { try await allSnippets("api/snippets") }
    func recycledSnippets() async throws -> [Snippet] { try await allSnippets("api/snippets", query: ["recycled": "true"]) }
    func sharedSnippets() async throws -> [Snippet] { try await allSnippets("api/groups/snippets") }
    func publicSnippets() async throws -> [Snippet] { try await allSnippets("api/public/snippets") }

    func snippet(id: Int) async throws -> Snippet { try await get("api/snippets/\(id)") }

    func create(_ payload: SnippetPayload) async throws -> Snippet {
        try await send("POST", "api/snippets", body: payload)
    }

    func update(id: Int, _ payload: SnippetPayload) async throws -> Snippet {
        try await send("PUT", "api/snippets/\(id)", body: payload)
    }

    func recycle(id: Int) async throws {
        let _: EmptyResponse = try await send("PATCH", "api/snippets/\(id)/recycle", body: [String: String]())
    }

    func restore(id: Int) async throws {
        let _: EmptyResponse = try await send("PATCH", "api/snippets/\(id)/restore", body: [String: String]())
    }

    func delete(id: Int) async throws {
        let _: EmptyResponse = try await send("DELETE", "api/snippets/\(id)", body: Optional<String>.none)
    }

    func setPinned(id: Int, _ value: Bool) async throws {
        let _: EmptyResponse = try await send("PATCH", "api/snippets/\(id)/pin", body: ["is_pinned": value])
    }

    func setFavorite(id: Int, _ value: Bool) async throws {
        let _: EmptyResponse = try await send("PATCH", "api/snippets/\(id)/favorite", body: ["is_favorite": value])
    }

    /// Groups the user can share with (all groups for admins).
    func groups() async throws -> [ShareGroup] { try await get("api/groups") }

    /// People to share with, matched by username.
    func searchUsers(_ query: String) async throws -> [ShareUser] {
        try await get("api/groups/share-users", query: ["q": query])
    }

    /// Creates a share link and returns its web URL.
    func createShareLink(snippetID: Int, requiresAuth: Bool, expiresInSeconds: Int?) async throws -> URL {
        struct Body: Encodable { var snippetId: Int; var requiresAuth: Bool; var expiresIn: Int? }
        let link: ShareLink = try await send(
            "POST", "api/share",
            body: Body(snippetId: snippetID, requiresAuth: requiresAuth, expiresIn: expiresInSeconds)
        )
        return baseURL.appendingPathComponent("s/\(link.id)")
    }

    func webURL(for snippetID: Int) -> URL { baseURL.appendingPathComponent("snippets/\(snippetID)") }

    // MARK: Plumbing

    private struct EmptyResponse: Decodable {}

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], authenticated: Bool = true) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "GET"
        return try await perform(request, authenticated: authenticated)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, authenticated: Bool = true) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try BSDate.encoder.encode(body)
        }
        return try await perform(request, authenticated: authenticated)
    }

    private func perform<T: Decodable>(_ original: URLRequest, authenticated: Bool) async throws -> T {
        var request = original
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "bytestashauth")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                throw APIError.offline
            default:
                throw APIError.server(status: 0, message: error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""

        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw authenticated ? APIError.unauthorized : APIError.server(status: 401, message: message)
        case 403 where message == "Invalid token":
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            throw APIError.server(status: http.statusCode, message: message)
        }

        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try BSDate.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
