import XCTest
@testable import ByteStash

final class ModelTests: XCTestCase {
    func testDecodesServerSnippet() throws {
        let json = """
        {"data":[{"id":7,"title":"Deploy","description":null,"updated_at":"2026-10-30 08:20:57Z",
          "expiry_date":null,"user_id":1,"is_public":0,"is_pinned":1,"is_favorite":0,
          "edit_permission":"owner","username":"tim","categories":["ops","bash"],"share_count":0,
          "fragments":[{"id":3,"file_name":"b.sh","code":"echo b","language":"bash","position":1},
                       {"id":2,"file_name":"a.sh","code":"\\n  echo a","language":"bash","position":0}],
          "shares":[{"type":"group","id":4,"name":"devs","permission":"edit"}],"visibility":"protected"}],
         "pagination":{"total":1,"offset":0,"limit":100,"hasMore":false}}
        """
        let page = try BSDate.decoder.decode(SnippetPage.self, from: Data(json.utf8))
        let snippet = try XCTUnwrap(page.data.first)
        XCTAssertEqual(snippet.id, 7)
        XCTAssertEqual(snippet.description, "")
        XCTAssertTrue(snippet.isPinned)
        XCTAssertFalse(snippet.isPublic)
        XCTAssertEqual(snippet.fragments.map(\.fileName), ["a.sh", "b.sh"])
        XCTAssertEqual(snippet.preview, "echo a")
        XCTAssertEqual(snippet.visibility, "protected")
        XCTAssertEqual(snippet.shares.first?.permission, "edit")
        XCTAssertFalse(snippet.isRecycled)
        XCTAssertEqual(snippet.updatedAt, BSDate.parse("2026-10-30T08:20:57Z"))
    }

    func testCacheRoundTrip() throws {
        var library = Library()
        library.own = [Snippet(id: 1, title: "A", isPinned: true, categories: ["x"],
                               fragments: [Fragment(id: 9, fileName: "a", code: "1", language: "swift", position: 0)])]
        library.lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try BSDate.encoder.encode(library)
        let decoded = try BSDate.decoder.decode(Library.self, from: data)
        XCTAssertEqual(decoded.own.first?.title, "A")
        XCTAssertEqual(decoded.own.first?.isPinned, true)
        XCTAssertEqual(decoded.own.first?.fragments.first?.id, 9)
        XCTAssertEqual(decoded.lastSync, library.lastSync)
    }

    func testPayloadKeepsSharingUnlessAsked() throws {
        let snippet = Snippet(id: 1, title: "T", visibility: "public")
        XCTAssertNil(SnippetPayload(snippet, includeVisibility: false).visibility)
        XCTAssertEqual(SnippetPayload(snippet, includeVisibility: true).visibility, "public")
        let shared = Snippet(id: 2, title: "S", visibility: "protected")
        XCTAssertNil(SnippetPayload(shared, includeVisibility: true).visibility)
    }

    func testNormalizeServerURL() {
        XCTAssertEqual(APIClient.normalize(serverURL: "snippets.example.com/")?.absoluteString, "https://snippets.example.com")
        XCTAssertEqual(APIClient.normalize(serverURL: " http://10.0.0.2:5000/bytestash ")?.absoluteString, "http://10.0.0.2:5000/bytestash")
        XCTAssertNil(APIClient.normalize(serverURL: "ftp://x"))
        XCTAssertNil(APIClient.normalize(serverURL: ""))
    }

    func testOIDCCallbackParsing() throws {
        XCTAssertEqual(try OIDCLogin.token(from: URL(string: "bytestash://auth/callback?token=abc.def")!), "abc.def")
        XCTAssertThrowsError(try OIDCLogin.token(from: URL(string: "bytestash://auth/callback?error=registration_disabled")!)) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "This server isn't accepting new accounts.")
        }
    }
}

final class SearchTests: XCTestCase {
    private let library: Library = {
        var lib = Library()
        lib.own = [
            Snippet(id: 1, title: "Docker cleanup", updatedAt: Date(timeIntervalSince1970: 100), categories: ["docker", "ops"],
                    fragments: [Fragment(fileName: "clean.sh", code: "docker system prune -af", language: "bash", position: 0)]),
            Snippet(id: 2, title: "Python venv", updatedAt: Date(timeIntervalSince1970: 300), isFavorite: true, categories: ["python"],
                    fragments: [Fragment(fileName: "venv.sh", code: "python -m venv .venv", language: "bash", position: 0)]),
            Snippet(id: 3, title: "Fetch JSON", updatedAt: Date(timeIntervalSince1970: 200), isPinned: true,
                    fragments: [Fragment(fileName: "fetch.ts", code: "await fetch(url)", language: "typescript", position: 0)]),
        ]
        lib.shared = [Snippet(id: 10, title: "Team docker notes", categories: ["docker"])]
        return lib
    }()

    func testQueryParsing() {
        let query = SearchQuery("prune #Ops lang:sh")
        XCTAssertEqual(query.words, ["prune"])
        XCTAssertEqual(query.tags, ["ops"])
        XCTAssertEqual(query.languages, ["bash"])
    }

    func testMatchesCodeTagsAndLanguage() {
        XCTAssertEqual(library.snippets(for: .all, query: SearchQuery("prune"), sort: .updated).map(\.id), [1])
        XCTAssertEqual(library.snippets(for: .all, query: SearchQuery("#python"), sort: .updated).map(\.id), [2])
        XCTAssertEqual(library.snippets(for: .all, query: SearchQuery("lang:ts"), sort: .updated).map(\.id), [3])
        XCTAssertEqual(library.snippets(for: .all, query: SearchQuery("venv python"), sort: .updated).map(\.id), [2])
    }

    func testSidebarFiltersAndPinnedFirst() {
        XCTAssertEqual(library.snippets(for: .all, query: SearchQuery(""), sort: .updated).map(\.id), [3, 2, 1])
        XCTAssertEqual(library.snippets(for: .favorites, query: SearchQuery(""), sort: .updated).map(\.id), [2])
        XCTAssertEqual(library.snippets(for: .category("docker"), query: SearchQuery(""), sort: .updated).map(\.id), [1])
        XCTAssertEqual(library.snippets(for: .language("bash"), query: SearchQuery(""), sort: .title).map(\.id), [1, 2])
        XCTAssertEqual(library.snippets(for: .untagged, query: SearchQuery(""), sort: .updated).map(\.id), [3])
        XCTAssertEqual(library.snippets(for: .shared, query: SearchQuery("docker"), sort: .updated).map(\.id), [10])
    }

    func testTitleMatchesRankFirst() {
        let ids = Library.sorted(library.everything.filter(SearchQuery("docker").matches), by: .updated, query: SearchQuery("docker")).map(\.id)
        XCTAssertEqual(ids.first, 1)
        XCTAssertEqual(Set(ids), [1, 10])
    }

    func testCounts() {
        XCTAssertEqual(library.categoryCounts.map(\.name), ["docker", "ops", "python"])
        XCTAssertEqual(library.languageCounts.first?.name, "bash")
        XCTAssertEqual(library.untaggedCount, 1)
    }
}

final class OutboxTests: XCTestCase {
    private func payload(_ title: String) -> SnippetPayload {
        SnippetPayload(Snippet(id: 1, title: title), includeVisibility: false)
    }

    func testUpdatesCoalesce() {
        var outbox = Outbox()
        outbox.enqueue(.update(id: 5, payload: payload("a")))
        outbox.enqueue(.update(id: 5, payload: payload("b")))
        XCTAssertEqual(outbox.changes, [.update(id: 5, payload: payload("b"))])
    }

    func testUpdateFoldsIntoPendingCreate() {
        var outbox = Outbox()
        outbox.enqueue(.create(tempID: -3, payload: payload("a")))
        outbox.enqueue(.update(id: -3, payload: payload("b")))
        XCTAssertEqual(outbox.changes, [.create(tempID: -3, payload: payload("b"))])
    }

    func testDeletingUnsentSnippetDropsEverything() {
        var outbox = Outbox()
        outbox.enqueue(.create(tempID: -3, payload: payload("a")))
        outbox.enqueue(.pin(id: -3, value: true))
        outbox.enqueue(.delete(id: -3))
        XCTAssertTrue(outbox.isEmpty)
    }

    func testPinTogglesKeepOnlyLast() {
        var outbox = Outbox()
        outbox.enqueue(.pin(id: 4, value: true))
        outbox.enqueue(.favorite(id: 4, value: true))
        outbox.enqueue(.pin(id: 4, value: false))
        XCTAssertEqual(outbox.changes, [.favorite(id: 4, value: true), .pin(id: 4, value: false)])
    }

    func testReplaceTempID() {
        var outbox = Outbox()
        outbox.enqueue(.create(tempID: -3, payload: payload("a")))
        outbox.enqueue(.pin(id: -3, value: true))
        outbox.removeFirst()
        outbox.replaceID(-3, with: 42)
        XCTAssertEqual(outbox.changes, [.pin(id: 42, value: true)])
    }
}

final class LanguageTests: XCTestCase {
    func testGuessAndHighlightNames() {
        XCTAssertEqual(Languages.guess(fileName: "deploy.sh"), "bash")
        XCTAssertEqual(Languages.guess(fileName: "Dockerfile"), "dockerfile")
        XCTAssertNil(Languages.guess(fileName: "README"))
        XCTAssertEqual(Languages.highlightName(for: "html"), "xml")
        XCTAssertNil(Languages.highlightName(for: "plaintext"))
        XCTAssertEqual(Languages.canonical("JS"), "javascript")
    }
}
