import Foundation
import AppKit
import GPXStrava

@MainActor
@Observable
final class StravaAuthService {
    private(set) var tokens: StravaTokens?
    var isConnecting = false
    var error: String?

    private let oauth: StravaOAuth

    init() {
        let id = (Bundle.main.object(forInfoDictionaryKey: "StravaClientID") as? String) ?? ""
        let secret = (Bundle.main.object(forInfoDictionaryKey: "StravaClientSecret") as? String) ?? ""
        self.oauth = StravaOAuth(clientId: id, clientSecret: secret)
        self.tokens = StravaTokenStore.load()
    }

    var isConnected: Bool { tokens != nil }
    var athleteName: String? { tokens?.athleteName }
    var isConfigured: Bool { !oauth.clientId.isEmpty && oauth.clientId != "TODO" }

    func connect() async {
        guard isConfigured else {
            error = "Identifiants Strava absents (Secrets.xcconfig)."
            return
        }
        isConnecting = true
        error = nil
        defer { isConnecting = false }

        let server = LoopbackAuthServer()
        let state = UUID().uuidString
        do {
            let query = try await server.startAndWaitForCallback(
                buildAuthURL: { port in
                    self.oauth.authorizationURL(redirectURI: "http://localhost:\(port)", state: state)
                },
                openURL: { url in
                    NSWorkspace.shared.open(url)
                }
            )
            if let returnedState = query["state"], returnedState != state {
                error = "Réponse Strava incohérente (state)."
                return
            }
            guard let code = query["code"] else {
                error = query["error"].map { "Autorisation Strava refusée (\($0))." } ?? "Autorisation Strava refusée."
                return
            }
            let newTokens = try await oauth.exchangeCode(code)
            try StravaTokenStore.save(newTokens)
            tokens = newTokens
        } catch {
            self.error = error.localizedDescription
            server.stop()
        }
    }

    func disconnect() {
        StravaTokenStore.clear()
        tokens = nil
    }
}
