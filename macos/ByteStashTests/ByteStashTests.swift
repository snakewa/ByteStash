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
        let shared = Snippet(id: 2, title: "S", editPermission: "readonly",
                             shares: [ShareTarget(type: "group", id: 4, name: "devs", permission: "edit")],
                             visibility: "protected")
        let payload = SnippetPayload(shared, includeVisibility: true)
        XCTAssertEqual(payload.visibility, "protected")
        XCTAssertEqual(payload.share_with, [.init(type: "group", id: 4, permission: "edit")])
        XCTAssertEqual(payload.edit_permission, "readonly")
        XCTAssertNil(SnippetPayload(shared, includeVisibility: false).share_with)
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
        lib.shared = [
            Snippet(id: 10, title: "Team docker notes", categories: ["docker"],
                    shares: [ShareTarget(type: "group", id: 4, name: "devs", permission: "view")], visibility: "protected"),
            Snippet(id: 11, title: "From amy", shares: [ShareTarget(type: "user", id: 2, name: "me", permission: "edit")],
                    visibility: "protected"),
        ]
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
        XCTAssertEqual(library.snippets(for: .group(4, "devs"), query: SearchQuery(""), sort: .updated).map(\.id), [10])
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

    func testContentEditKeepsPendingSharingChange() {
        var outbox = Outbox()
        let shared = Snippet(id: 5, title: "a", shares: [ShareTarget(type: "user", id: 2, name: "amy", permission: "view")],
                             visibility: "protected")
        outbox.enqueue(.update(id: 5, payload: SnippetPayload(shared, includeVisibility: true)))
        var edited = shared
        edited.title = "b"
        outbox.enqueue(.update(id: 5, payload: SnippetPayload(edited, includeVisibility: false)))
        guard case let .update(_, payload) = outbox.changes.first else { return XCTFail("no update") }
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(payload.title, "b")
        XCTAssertEqual(payload.visibility, "protected")
        XCTAssertEqual(payload.share_with?.first?.id, 2)
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

final class AccountTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ByteStashTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testImportsSingleAccountFromOlderVersion() {
        let defaults = self.defaults()
        defaults.set("https://snippets.example.com", forKey: "serverURL")
        defaults.set("tim", forKey: "username")
        defaults.set(3, forKey: "userID")
        let list = AccountList.load(from: defaults)
        XCTAssertEqual(list.count, 1)
        // Same key as before, so the keychain token and offline cache are reused.
        XCTAssertEqual(list.first?.id, "snippets.example.com")
        XCTAssertEqual(list.first?.name, "Personal")
        XCTAssertEqual(list.first?.username, "tim")
        XCTAssertEqual(list.first?.userID, 3)
    }

    func testSavedListWinsOverLegacyKeys() {
        let defaults = self.defaults()
        defaults.set("https://old.example.com", forKey: "serverURL")
        let work = AccountInfo(id: "work.example.com", server: "https://work.example.com", username: "tim", userID: 9,
                               name: "Work", color: .orange, keepsOfflineCache: false)
        AccountList.save([work], to: defaults)
        XCTAssertEqual(AccountList.load(from: defaults), [work])
        XCTAssertTrue(AccountList.load(from: self.defaults()).isEmpty)
    }

    func testDecodesAccountWithMissingFields() throws {
        let json = #"[{"id":"a","server":"https://a.example.com"}]"#
        let list = try JSONDecoder().decode([AccountInfo].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.color, .blue)
        XCTAssertEqual(list.first?.keepsOfflineCache, true)
        XCTAssertEqual(list.first?.displayName, "a.example.com")
    }

    func testAccountKeyIncludesPortAndPath() {
        XCTAssertEqual(AccountInfo.key(for: URL(string: "http://10.0.0.2:5000/bytestash")!), "10.0.0.2-5000_bytestash")
    }

    func testSuggestedNamesAndColors() {
        XCTAssertEqual(AccountInfo.suggestedName(existing: []), "Personal")
        let personal = AccountInfo(id: "p", server: "https://p", username: "", userID: 1, name: "Personal", color: .blue)
        XCTAssertEqual(AccountInfo.suggestedName(existing: [personal]), "Work")
        XCTAssertEqual(AccountInfo.suggestedColor(existing: [personal]), .orange)
    }

    func testTransferCopyIsAFreshPrivateSnippet() {
        let original = Snippet(id: 7, title: "Deploy", description: "d", userID: 1, username: "tim", isPublic: true,
                               isPinned: true, isFavorite: true, editPermission: "readonly", categories: ["ops"],
                               fragments: [Fragment(id: 3, fileName: "a.sh", code: "echo", language: "bash", position: 0)],
                               shares: [ShareTarget(type: "group", id: 4, name: "devs", permission: "edit")],
                               visibility: "public")
        let copy = original.transferCopy()
        XCTAssertLessThan(copy.id, 0)
        XCTAssertEqual(copy.title, "Deploy")
        XCTAssertEqual(copy.description, "d")
        XCTAssertEqual(copy.categories, ["ops"])
        XCTAssertEqual(copy.fragments.map(\.code), ["echo"])
        XCTAssertLessThan(copy.fragments[0].id, 0)
        XCTAssertEqual(copy.visibility, "private")
        XCTAssertFalse(copy.isPublic)
        XCTAssertTrue(copy.shares.isEmpty)
        XCTAssertEqual(copy.editPermission, "owner")
        XCTAssertFalse(copy.isPinned)
        XCTAssertFalse(copy.isFavorite)
        XCTAssertNil(copy.userID)
        let payload = SnippetPayload(copy, includeVisibility: true)
        XCTAssertEqual(payload.visibility, "private")
    }

    func testMergedSortAcrossAccounts() {
        let items = [
            AccountSnippet(account: "work", snippet: Snippet(id: 1, title: "B", updatedAt: Date(timeIntervalSince1970: 100))),
            AccountSnippet(account: "personal", snippet: Snippet(id: 1, title: "A", updatedAt: Date(timeIntervalSince1970: 300))),
            AccountSnippet(account: "personal", snippet: Snippet(id: 2, title: "C", updatedAt: Date(timeIntervalSince1970: 200), isPinned: true)),
        ]
        let sorted = Library.sorted(items, by: .updated, query: SearchQuery(""), snippet: \.snippet)
        XCTAssertEqual(sorted.map(\.id), [
            SnippetRef(account: "personal", id: 2),
            SnippetRef(account: "personal", id: 1),
            SnippetRef(account: "work", id: 1),
        ])
        // Same server id on two accounts is still two different snippets.
        XCTAssertNotEqual(items[0].id, items[1].id)
    }

    func testScope() {
        XCTAssertTrue(AccountScope.all.includes("work"))
        XCTAssertTrue(AccountScope.account("work").includes("work"))
        XCTAssertFalse(AccountScope.account("work").includes("personal"))
    }

    func testGroupItemsDifferPerAccount() {
        XCTAssertNotEqual(SidebarItem.group(4, "devs", account: "a"), SidebarItem.group(4, "devs", account: "b"))
    }

    func testDragPayloadRoundTrip() throws {
        let drag = SnippetDrag(refs: [SnippetRef(account: "work", id: 3), SnippetRef(account: "personal", id: 3)], text: "echo")
        let decoded = try JSONDecoder().decode(SnippetDrag.self, from: JSONEncoder().encode(drag))
        XCTAssertEqual(decoded.refs, drag.refs)
        XCTAssertEqual(decoded.text, "echo")
    }

    func testDropTargets() {
        XCTAssertTrue(SidebarDropTarget.accepts(.category("ops")))
        XCTAssertTrue(SidebarDropTarget.accepts(.pinned))
        XCTAssertTrue(SidebarDropTarget.accepts(.favorites))
        XCTAssertTrue(SidebarDropTarget.accepts(.recycled))
        XCTAssertFalse(SidebarDropTarget.accepts(.all))
        XCTAssertFalse(SidebarDropTarget.accepts(.publicFeed))
        XCTAssertFalse(SidebarDropTarget.accepts(.shared))
    }
}
