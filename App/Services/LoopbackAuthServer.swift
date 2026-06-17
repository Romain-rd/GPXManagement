import Foundation
import Network

/// Petit serveur HTTP loopback éphémère pour capter la redirection OAuth (http://localhost:PORT).
final class LoopbackAuthServer {
    private var listener: NWListener?

    /// Démarre l'écoute sur un port éphémère, ouvre l'URL d'autorisation (construite avec le port),
    /// puis attend la redirection et renvoie ses paramètres de requête.
    @MainActor
    func startAndWaitForCallback(
        buildAuthURL: @escaping (UInt16) -> URL,
        openURL: @escaping (URL) -> Void
    ) async throws -> [String: String] {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
            let box = ResumeBox(continuation: continuation)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        openURL(buildAuthURL(port))
                    }
                case .failed(let error):
                    box.finish(.failure(error))
                    listener.cancel()
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let query = Self.parseQuery(request)
                    let body = "<html><head><meta charset='utf-8'></head><body style=\"font-family:-apple-system;text-align:center;padding-top:64px\"><h2>Connexion Strava réussie ✅</h2><p>Vous pouvez fermer cet onglet et revenir à GPXManagement.</p></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    box.finish(.success(query))
                    listener.cancel()
                }
            }

            listener.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func parseQuery(_ httpRequest: String) -> [String: String] {
        guard let firstLine = httpRequest.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first,
              let queryStart = pathPart.firstIndex(of: "?") else {
            return [:]
        }
        let query = pathPart[pathPart.index(after: queryStart)...]
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            result[String(key)] = value.removingPercentEncoding ?? value
        }
        return result
    }
}

/// Garantit une reprise unique de la continuation depuis des callbacks concurrents.
private final class ResumeBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<[String: String], Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
