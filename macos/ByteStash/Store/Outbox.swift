import Foundation

/// A change made locally that the server hasn't confirmed yet. Kept on disk so edits made
/// offline survive a restart and are sent when the server is reachable again.
enum PendingChange: Codable, Hashable {
    /// `tempID` is the negative id the snippet has locally until the server assigns one.
    case create(tempID: Int, payload: SnippetPayload)
    case update(id: Int, payload: SnippetPayload)
    case recycle(id: Int)
    case restore(id: Int)
    case delete(id: Int)
    case pin(id: Int, value: Bool)
    case favorite(id: Int, value: Bool)

    var snippetID: Int {
        switch self {
        case let .create(id, _), let .update(id, _), let .recycle(id), let .restore(id),
             let .delete(id), let .pin(id, _), let .favorite(id, _):
            return id
        }
    }

    func replacingID(_ old: Int, with new: Int) -> PendingChange {
        guard snippetID == old else { return self }
        switch self {
        case let .create(_, payload): return .create(tempID: new, payload: payload)
        case let .update(_, payload): return .update(id: new, payload: payload)
        case .recycle: return .recycle(id: new)
        case .restore: return .restore(id: new)
        case .delete: return .delete(id: new)
        case let .pin(_, value): return .pin(id: new, value: value)
        case let .favorite(_, value): return .favorite(id: new, value: value)
        }
    }
}

struct Outbox: Codable, Equatable {
    private(set) var changes: [PendingChange] = []

    var isEmpty: Bool { changes.isEmpty }
    var count: Int { changes.count }
    var first: PendingChange? { changes.first }

    /// Adds a change, folding it into earlier ones for the same snippet where possible so a
    /// burst of autosaves becomes one request.
    mutating func enqueue(_ change: PendingChange) {
        switch change {
        case let .update(id, payload):
            if let index = changes.lastIndex(where: { $0.snippetID == id }) {
                switch changes[index] {
                case let .create(_, older):
                    changes[index] = .create(tempID: id, payload: payload.keepingSharing(of: older))
                    return
                case let .update(_, older):
                    changes[index] = .update(id: id, payload: payload.keepingSharing(of: older))
                    return
                default:
                    break
                }
            }
        case let .delete(id) where id < 0:
            // Never reached the server: forget it entirely.
            changes.removeAll { $0.snippetID == id }
            return
        case let .pin(id, _), let .favorite(id, _):
            changes.removeAll {
                guard $0.snippetID == id else { return false }
                switch ($0, change) {
                case (.pin, .pin), (.favorite, .favorite): return true
                default: return false
                }
            }
        default:
            break
        }
        changes.append(change)
    }

    mutating func removeFirst() {
        if !changes.isEmpty { changes.removeFirst() }
    }

    mutating func replaceID(_ old: Int, with new: Int) {
        changes = changes.map { $0.replacingID(old, with: new) }
    }

    func hasPending(for id: Int) -> Bool {
        changes.contains { $0.snippetID == id }
    }
}
