import SwiftUI

/// Who can see and edit a snippet: private, shared with groups and people (each with view
/// or edit access), or public; plus the owner's edit lock. Mirrors the web app's dialog.
struct SharingSheet: View {
    @EnvironmentObject private var store: SnippetStore
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet

    @State private var visibility: String
    @State private var shares: [ShareTarget]
    @State private var locked: Bool
    @State private var userQuery = ""
    @State private var userResults: [ShareUser] = []
    @State private var searchTask: Task<Void, Never>?

    init(snippet: Snippet) {
        self.snippet = snippet
        _visibility = State(initialValue: snippet.visibility)
        _shares = State(initialValue: snippet.shares)
        _locked = State(initialValue: snippet.isLocked)
    }

    private var availableGroups: [ShareGroup] {
        store.library.groups.filter { group in !shares.contains { $0.type == "group" && $0.id == group.id } }
    }

    private var canSave: Bool { visibility != "protected" || !shares.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share “\(snippet.title)”").font(.headline).lineLimit(1)

            Picker("Visibility", selection: $visibility) {
                Label("Private", systemImage: "lock").tag("private")
                Label("Shared", systemImage: "person.2").tag("protected")
                Label("Public", systemImage: "globe").tag("public")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(explanation).font(.callout).foregroundStyle(.secondary)

            if visibility == "protected" {
                targets
                addRow
            }

            Toggle("Lock editing (nobody can edit, including you, until unlocked)", isOn: $locked)

            HStack {
                if visibility == "protected" && shares.isEmpty {
                    Text("Add at least one group or person.").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.saveSharing(snippet, visibility: visibility, shares: shares, locked: locked)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: userQuery) { _, query in search(query) }
    }

    private var explanation: String {
        switch visibility {
        case "public": return "Anyone can find and view it on the Public page. Only you can edit it."
        case "protected": return "Only the groups and people below can see it. Give them edit access to let them change the content."
        default: return "Only you can see it."
        }
    }

    private var targets: some View {
        VStack(spacing: 0) {
            if shares.isEmpty {
                Text("Not shared with anyone yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                HStack {
                    Image(systemName: share.type == "group" ? "person.3" : "person")
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    Text(share.name ?? "#\(share.id)")
                    if share.type == "group" {
                        Text("group").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { shares[index].permission },
                        set: { shares[index].permission = $0 }
                    )) {
                        Text("Can view").tag("view")
                        Text("Can edit").tag("edit")
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        shares.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop sharing")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                if index < shares.count - 1 { Divider() }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var addRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Menu {
                if availableGroups.isEmpty {
                    Text(store.library.groups.isEmpty ? "You're not in any groups" : "Shared with all your groups")
                }
                ForEach(availableGroups) { group in
                    Button(group.name) {
                        shares.append(ShareTarget(type: "group", id: group.id, name: group.name, permission: "view"))
                    }
                }
            } label: {
                Label("Add Group", systemImage: "person.3")
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 4) {
                TextField("Add person by username", text: $userQuery)
                    .textFieldStyle(.roundedBorder)
                if !userResults.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(userResults) { user in
                            Button {
                                addUser(user)
                            } label: {
                                HStack {
                                    Image(systemName: "person")
                                    Text(user.username)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
        }
    }

    private func addUser(_ user: ShareUser) {
        if !shares.contains(where: { $0.type == "user" && $0.id == user.id }) {
            shares.append(ShareTarget(type: "user", id: user.id, name: user.username, permission: "view"))
        }
        userQuery = ""
        userResults = []
    }

    private func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            userResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await store.searchUsers(trimmed)
            guard !Task.isCancelled else { return }
            userResults = found.filter { user in !shares.contains { $0.type == "user" && $0.id == user.id } }
        }
    }
}

/// Compact "Shared with" line for the snippet header.
struct ShareSummary: View {
    let shares: [ShareTarget]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2").foregroundStyle(.secondary)
            ForEach(shares, id: \.self) { share in
                HStack(spacing: 3) {
                    Image(systemName: share.type == "group" ? "person.3" : "person").imageScale(.small)
                    Text(share.name ?? "#\(share.id)")
                    if share.permission == "edit" {
                        Image(systemName: "pencil").imageScale(.small)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .help(share.permission == "edit" ? "Can edit" : "Can view")
            }
        }
    }
}
