import Foundation

public struct StravaTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var athleteId: Int64
    public var athleteName: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, athleteId: Int64, athleteName: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.athleteId = athleteId
        self.athleteName = athleteName
    }

    /// Vrai si le token est expiré (marge de 60 s).
    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

public enum StravaError: Error, LocalizedError {
    case invalidResponse
    case http(Int, String)
    case decoding
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Réponse Strava invalide."
        case .http(let code, let body): return "Erreur Strava (HTTP \(code)) : \(body)"
        case .decoding: return "Impossible de décoder la réponse Strava."
        case .notConnected: return "Non connecté à Strava."
        }
    }
}
