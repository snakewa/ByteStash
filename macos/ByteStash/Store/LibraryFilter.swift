import Foundation

enum SidebarItem: Hashable, Codable {
    case all
    case pinned
    case favorites
    case shared
    case publicFeed
    case recycled
    case untagged
    case category(String)
    case language(String)

    var title: String {
        switch self {
        case .all: return "All Snippets"
        case .pinned: return "Pinned"
        case .favorites: return "Favorites"
        case .shared: return "Shared with Me"
        case .publicFeed: return "Public"
        case .recycled: return "Recycle Bin"
        case .untagged: return "Untagged"
        case let .category(name): return name
        case let .language(name): return Languages.displayName(for: name)
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .pinned: return "pin"
        case .favorites: return "star"
        case .shared: return "person.2"
        case .publicFeed: return "globe"
        case .recycled: return "trash"
        case .untagged: return "tag.slash"
        case .category: return "tag"
        case .language: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum SortOrder: String, CaseIterable, Codable, Identifiable {
    case updated, oldest, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return "Date Modified"
        case .oldest: return "Oldest First"
        case .title: return "Title"
        }
    }
}

/// Parsed search box text. Plain words must all match somewhere in the snippet; `#tag`
/// narrows to a category and `lang:swift` (or `l:swift`) to a language.
struct SearchQuery: Equatable {
    var words: [String] = []
    var tags: [String] = []
    var languages: [String] = []

    init(_ text: String) {
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = raw.lowercased()
            if token.hasPrefix("#"), token.count > 1 {
                tags.append(String(token.dropFirst()))
            } else if let colon = token.firstIndex(of: ":"),
                      ["lang", "l"].contains(String(token[..<colon])),
                      token.index(after: colon) < token.endIndex {
                languages.append(Languages.canonical(String(token[token.index(after: colon)...])))
            } else {
                words.append(token)
            }
        }
    }

    var isEmpty: Bool { words.isEmpty && tags.isEmpty && languages.isEmpty }

    func matches(_ snippet: Snippet) -> Bool {
        let categories = snippet.categories.map { $0.lowercased() }
        for tag in tags where !categories.contains(where: { $0.hasPrefix(tag) }) {
            return false
        }
        for language in languages where !snippet.fragments.contains(where: { $0.language.lowercased() == language }) {
            return false
        }
        guard !words.isEmpty else { return true }
        let haystacks: [String] = [snippet.title, snippet.description, snippet.username ?? ""]
            + snippet.categories
            + snippet.fragments.flatMap { [$0.fileName, $0.code] }
        return words.allSatisfy { word in
            haystacks.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Higher is better: title hits beat tag hits beat code hits.
    func score(_ snippet: Snippet) -> Int {
        var score = 0
        let title = snippet.title.lowercased()
        for word in words {
            if title.hasPrefix(word) { score += 100 } else if title.contains(word) { score += 50 }
            if snippet.categories.contains(where: { $0.lowercased().contains(word) }) { score += 20 }
            if snippet.description.lowercased().contains(word) { score += 10 }
        }
        if snippet.isPinned { score += 5 }
        if snippet.isFavorite { score += 3 }
        return score
    }
}

/// The snippets a user can see, grouped the way the server lists them.
struct Library: Codable, Equatable {
    var own: [Snippet] = []
    var recycled: [Snippet] = []
    var shared: [Snippet] = []
    var publicFeed: [Snippet] = []
    var lastSync: Date?

    /// Everything searchable from the quick panel: own first, then others' snippets.
    var everything: [Snippet] {
        var seen = Set(own.map(\.id))
        var result = own
        for snippet in shared + publicFeed where seen.insert(snippet.id).inserted {
            result.append(snippet)
        }
        return result
    }

    func snippet(id: Int) -> Snippet? {
        own.first { $0.id == id }
            ?? shared.first { $0.id == id }
            ?? recycled.first { $0.id == id }
            ?? publicFeed.first { $0.id == id }
    }

    func source(for item: SidebarItem) -> [Snippet] {
        switch item {
        case .shared: return shared
        case .publicFeed: return publicFeed
        case .recycled: return recycled
        default: return own
        }
    }

    func snippets(for item: SidebarItem, query: SearchQuery, sort: SortOrder) -> [Snippet] {
        let base = source(for: item).filter { snippet in
            switch item {
            case .pinned: return snippet.isPinned
            case .favorites: return snippet.isFavorite
            case .untagged: return snippet.categories.isEmpty
            case let .category(name): return snippet.categories.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case let .language(name): return snippet.fragments.contains { $0.language == name }
            default: return true
            }
        }
        let matched = query.isEmpty ? base : base.filter(query.matches)
        return Library.sorted(matched, by: sort, query: query)
    }

    static func sorted(_ snippets: [Snippet], by sort: SortOrder, query: SearchQuery) -> [Snippet] {
        snippets.sorted { a, b in
            if !query.words.isEmpty {
                let sa = query.score(a), sb = query.score(b)
                if sa != sb { return sa > sb }
            }
            if a.isPinned != b.isPinned { return a.isPinned }
            switch sort {
            case .updated: return a.updatedAt > b.updatedAt
            case .oldest: return a.updatedAt < b.updatedAt
            case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Category name → number of own (non-recycled) snippets using it.
    var categoryCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for snippet in own {
            for category in snippet.categories { counts[category, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var languageCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for snippet in own {
            for language in snippet.languages { counts[language, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    var untaggedCount: Int { own.filter { $0.categories.isEmpty }.count }
}
