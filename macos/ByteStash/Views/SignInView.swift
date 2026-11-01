import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var app: AppState

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var authConfig: AuthConfig?
    @State private var oidcConfig: OIDCConfig?
    @State private var checking = false
    @State private var working = false
    @State private var error: String?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces.square.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("ByteStash").font(.largeTitle.weight(.semibold))
                    Text("Sign in to your ByteStash server").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Server").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("https://snippets.example.com", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { checkServer(immediately: true) }
                    if checking { ProgressView().controlSize(.small) }
                }
            }

            if let authConfig {
                if authConfig.disableAccounts == true {
                    Text("This server runs without accounts.").foregroundStyle(.secondary)
                    Button("Continue") { run { try await app.signInAnonymously(server: server) } }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                } else {
                    if authConfig.disableInternalAccounts != true {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Username", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.username)
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.password)
                                .onSubmit(signIn)
                            Button("Sign In", action: signIn)
                                .keyboardShortcut(.defaultAction)
                                .controlSize(.large)
                                .disabled(username.isEmpty || password.isEmpty || working)
                        }
                    }
                    if oidcConfig?.enabled == true {
                        if authConfig.disableInternalAccounts != true {
                            HStack {
                                VStack { Divider() }
                                Text("or").font(.caption).foregroundStyle(.secondary)
                                VStack { Divider() }
                            }
                        }
                        Button {
                            run { try await app.signInWithSSO(server: server) }
                        } label: {
                            Label("Sign in with \(oidcConfig?.displayName ?? "SSO")", systemImage: "person.badge.key")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(working)
                    }
                }
            }

            if working {
                ProgressView().controlSize(.small)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .onAppear {
            if server.isEmpty { server = app.lastServer }
            if !server.isEmpty { checkServer(immediately: true) }
        }
        .onChange(of: server) { _, _ in checkServer(immediately: false) }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty else { return }
        run { try await app.signIn(server: server, username: username, password: password) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await action()
            } catch APIError.server(401, _) {
                error = "Wrong username or password."
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }

    /// Looks up which sign-in methods the server offers.
    private func checkServer(immediately: Bool) {
        checkTask?.cancel()
        authConfig = nil
        oidcConfig = nil
        error = nil
        guard let url = APIClient.normalize(serverURL: server) else { return }
        checkTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 600_000_000) }
            guard !Task.isCancelled else { return }
            checking = true
            defer { checking = false }
            let api = APIClient(baseURL: url)
            do {
                let config = try await api.authConfig()
                guard !Task.isCancelled else { return }
                authConfig = config
                oidcConfig = try? await api.oidcConfig()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Couldn't reach a ByteStash server at \(url.absoluteString)."
            }
        }
    }
}
