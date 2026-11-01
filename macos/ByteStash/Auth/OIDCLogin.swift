import AppKit
import AuthenticationServices

/// Runs the server's OIDC login (Google, Authentik, Keycloak, ...) in a system web sheet.
/// The server redirects to bytestash://auth/callback?token=... when it was started with
/// ?client=desktop, and ASWebAuthenticationSession hands that URL straight back to us.
@MainActor
final class OIDCLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let callbackScheme = "bytestash"

    private var session: ASWebAuthenticationSession?

    func start(url: URL) async throws -> String {
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? APIError.server(status: 0, message: "Sign-in was cancelled."))
                }
            }
            session.presentationContextProvider = self
            // Share cookies with Safari so an existing Google/IdP session is reused.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: APIError.server(status: 0, message: "Couldn't open the sign-in window."))
            }
        }
        session = nil
        return try Self.token(from: callbackURL)
    }

    nonisolated static func token(from url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty {
            return token
        }
        let error = items.first(where: { $0.name == "error" })?.value ?? "auth_failed"
        let message = items.first(where: { $0.name == "message" })?.value
        throw APIError.server(status: 0, message: message ?? Self.describe(error))
    }

    nonisolated static func describe(_ code: String) -> String {
        switch code {
        case "registration_disabled": return "This server isn't accepting new accounts."
        case "account_deactivated": return "Your account has been deactivated."
        case "config_error": return "Single sign-on isn't configured correctly on the server."
        case "provider_error": return "The identity provider refused the sign-in."
        default: return "Sign-in failed. Try again."
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
