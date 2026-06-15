import Foundation

/// Récupère l'altitude de points GPS qui n'en ont pas, via le service altimétrie IGN Géoplateforme
/// (RGE ALTI, France, gratuit sans clé) puis, pour les points hors couverture, un repli mondial
/// (OpenTopoData). Renvoie une copie des points enrichis là où une source a fourni une donnée.
public actor ElevationEnricher {
    public static let shared = ElevationEnricher()
    public init() {}

    private static let ignBatch = 100
    private static let otdBatch = 100
    // Les services renvoient une sentinelle négative (≈ -99999) hors couverture.
    private static let invalidThreshold = -1000.0

    public func enrich(points: [TrackPoint]) async -> (points: [TrackPoint], resolved: Int) {
        let coords = points.map { ($0.latitude, $0.longitude) }
        var z = [Double?](repeating: nil, count: coords.count)

        // 1) IGN RGE ALTI — précis, couverture France métropolitaine + DOM.
        for batch in Self.chunk(Array(coords.indices), Self.ignBatch) {
            if let zs = await fetchIGN(batch.map { coords[$0] }) {
                for (k, idx) in batch.enumerated() where k < zs.count && zs[k] > Self.invalidThreshold {
                    z[idx] = zs[k]
                }
            }
        }

        // 2) Repli mondial pour les points encore sans altitude.
        let missing = z.indices.filter { z[$0] == nil }
        for (i, batch) in Self.chunk(missing, Self.otdBatch).enumerated() {
            if i > 0 { try? await Task.sleep(nanoseconds: 1_100_000_000) } // OpenTopoData : 1 requête/s.
            if let zs = await fetchOpenTopo(batch.map { coords[$0] }) {
                for (k, idx) in batch.enumerated() {
                    guard k < zs.count, let v = zs[k], v > Self.invalidThreshold else { continue }
                    z[idx] = v
                }
            }
        }

        var resolved = 0
        let enriched = points.enumerated().map { i, p -> TrackPoint in
            guard let alt = z[i] else { return p }
            resolved += 1
            return TrackPoint(latitude: p.latitude, longitude: p.longitude, altitude: alt,
                              timestamp: p.timestamp, heartRate: p.heartRate, cadence: p.cadence, power: p.power)
        }
        return (enriched, resolved)
    }

    // MARK: - IGN

    private struct IGNResponse: Decodable { let elevations: [IGNElevation] }
    private struct IGNElevation: Decodable { let z: Double }

    private func fetchIGN(_ coords: [(Double, Double)]) async -> [Double]? {
        guard !coords.isEmpty else { return [] }
        let lons = coords.map { String(format: "%.6f", $0.1) }.joined(separator: "|")
        let lats = coords.map { String(format: "%.6f", $0.0) }.joined(separator: "|")
        var comps = URLComponents(string: "https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json")!
        comps.queryItems = [
            URLQueryItem(name: "lon", value: lons),
            URLQueryItem(name: "lat", value: lats),
            URLQueryItem(name: "resource", value: "ign_rge_alti_wld"),
            URLQueryItem(name: "delimiter", value: "|"),
            URLQueryItem(name: "measures", value: "false"),
            URLQueryItem(name: "indent", value: "false")
        ]
        guard let url = comps.url, let data = await get(url),
              let resp = try? JSONDecoder().decode(IGNResponse.self, from: data) else { return nil }
        return resp.elevations.map { $0.z }
    }

    // MARK: - Repli mondial (OpenTopoData)

    private struct OTDResponse: Decodable { let results: [OTDResult]? }
    private struct OTDResult: Decodable { let elevation: Double? }

    private func fetchOpenTopo(_ coords: [(Double, Double)]) async -> [Double?]? {
        guard !coords.isEmpty else { return [] }
        let locations = coords.map { String(format: "%.6f,%.6f", $0.0, $0.1) }.joined(separator: "|")
        var comps = URLComponents(string: "https://api.opentopodata.org/v1/aster30m")!
        comps.queryItems = [URLQueryItem(name: "locations", value: locations)]
        guard let url = comps.url, let data = await get(url),
              let resp = try? JSONDecoder().decode(OTDResponse.self, from: data),
              let results = resp.results else { return nil }
        return results.map { $0.elevation }
    }

    // MARK: - Réseau

    private func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func chunk(_ array: [Int], _ size: Int) -> [[Int]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map { Array(array[$0..<min($0 + size, array.count)]) }
    }
}
