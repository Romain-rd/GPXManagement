import Foundation

public struct StravaOAuth: Sendable {
    public let clientId: String
    public let clientSecret: String

    private static let authorizeEndpoint = "https://www.strava.com/oauth/authorize"
    private static let tokenEndpoint = "https://www.strava.com/oauth/token"

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    public func authorizationURL(redirectURI: String, scope: String = "activity:read_all", state: String) -> URL {
        var components = URLComponents(string: Self.authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    public func exchangeCode(_ code: String) async throws -> StravaTokens {
        let params = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code"
        ]
        let json = try await postForm(params)
        return try Self.parseTokens(json, previous: nil)
    }

    public func refresh(_ tokens: StravaTokens) async throws -> StravaTokens {
        let params = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken
        ]
        let json = try await postForm(params)
        return try Self.parseTokens(json, previous: tokens)
    }

    // MARK: -

    private func postForm(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StravaError.invalidResponse }
        guard http.statusCode == 200 else {
            throw StravaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StravaError.decoding
        }
        return json
    }

    private static func parseTokens(_ json: [String: Any], previous: StravaTokens?) throws -> StravaTokens {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresAt = json["expires_at"] as? Double else {
            throw StravaError.decoding
        }
        var athleteId = previous?.athleteId ?? 0
        var athleteName = previous?.athleteName
        if let athlete = json["athlete"] as? [String: Any] {
            if let id = athlete["id"] as? Int64 { athleteId = id }
            else if let id = athlete["id"] as? Int { athleteId = Int64(id) }
            let first = athlete["firstname"] as? String ?? ""
            let last = athlete["lastname"] as? String ?? ""
            let name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { athleteName = name }
        }
        return StravaTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: expiresAt),
            athleteId: athleteId,
            athleteName: athleteName
        )
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()
}
