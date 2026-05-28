import Foundation

public struct StravaAPI: Sendable {
    private static let base = "https://www.strava.com/api/v3"

    public init() {}

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Une page de la liste des activités de l'athlète, triées par date croissante.
    public func activities(accessToken: String, after: Date?, page: Int, perPage: Int = 50) async throws -> [StravaActivitySummary] {
        var components = URLComponents(string: "\(Self.base)/athlete/activities")!
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        if let after {
            items.append(URLQueryItem(name: "after", value: String(Int(after.timeIntervalSince1970))))
        }
        components.queryItems = items

        let json = try await get(components.url!, accessToken: accessToken)
        guard let array = json as? [[String: Any]] else { throw StravaError.decoding }
        return array.compactMap { dict in
            guard let id = (dict["id"] as? Int64) ?? (dict["id"] as? Int).map(Int64.init),
                  let startStr = dict["start_date"] as? String,
                  let start = Self.iso8601.date(from: startStr) else { return nil }
            let name = dict["name"] as? String ?? "Activité Strava"
            let sport = dict["sport_type"] as? String ?? dict["type"] as? String ?? ""
            let distance = dict["distance"] as? Double ?? 0
            let startLatLng = dict["start_latlng"] as? [Double] ?? []
            return StravaActivitySummary(
                id: id, name: name, sportType: sport, startDate: start,
                distanceMeters: distance, hasGPS: !startLatLng.isEmpty
            )
        }
    }

    /// Streams d'une activité reconstruits en points (latlng requis ; le reste si présent).
    public func streams(accessToken: String, activityId: Int64) async throws -> [StravaStreamPoint] {
        var components = URLComponents(string: "\(Self.base)/activities/\(activityId)/streams")!
        components.queryItems = [
            URLQueryItem(name: "keys", value: "latlng,altitude,time,heartrate,cadence,watts"),
            URLQueryItem(name: "key_by_type", value: "true")
        ]
        let json = try await get(components.url!, accessToken: accessToken)
        guard let dict = json as? [String: Any],
              let latlng = (dict["latlng"] as? [String: Any])?["data"] as? [[Double]] else {
            return []
        }
        let altitude = (dict["altitude"] as? [String: Any])?["data"] as? [Double]
        let time = (dict["time"] as? [String: Any])?["data"] as? [Double]
        let hr = (dict["heartrate"] as? [String: Any])?["data"] as? [Double]
        let cadence = (dict["cadence"] as? [String: Any])?["data"] as? [Double]
        let watts = (dict["watts"] as? [String: Any])?["data"] as? [Double]

        var points: [StravaStreamPoint] = []
        points.reserveCapacity(latlng.count)
        for (i, pair) in latlng.enumerated() where pair.count == 2 {
            points.append(StravaStreamPoint(
                latitude: pair[0],
                longitude: pair[1],
                altitude: altitude?[safe: i],
                timeOffset: time?[safe: i],
                heartRate: hr?[safe: i],
                cadence: cadence?[safe: i],
                power: watts?[safe: i]
            ))
        }
        return points
    }

    // MARK: -

    private func get(_ url: URL, accessToken: String) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StravaError.invalidResponse }
        if http.statusCode == 429 { throw StravaError.rateLimited }
        guard http.statusCode == 200 else {
            throw StravaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}
