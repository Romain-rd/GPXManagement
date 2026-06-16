import Foundation

/// Récupère l'altitude de points GPS qui n'en ont pas, via le service altimétrie IGN Géoplateforme
/// (RGE ALTI, France, gratuit sans clé) puis, pour les points hors couverture, un repli mondial
/// (OpenTopoData). Renvoie une copie des points enrichis là où une source a fourni une donnée.
public actor ElevationEnricher {
    public static let shared = ElevationEnricher()
    public init() {}

    private static let ignBatch = 100
    private static let otdBatch = 100
    private static let ignConcurrency = 8
    // Au-delà, on échantillonne les points interrogés puis on interpole : un profil de planification
    // n'a pas besoin du mètre près, et ça borne le nombre de requêtes (surtout le repli OTD à 1 req/s).
    private static let maxQuery = 1200
    // Les services renvoient une sentinelle négative (≈ -99999) hors couverture.
    private static let invalidThreshold = -1000.0

    public func enrich(points: [TrackPoint]) async -> (points: [TrackPoint], resolved: Int) {
        let n = points.count
        guard n > 0 else { return (points, 0) }

        // Indices interrogés : tout si court, sinon un échantillon régulier (extrémités incluses).
        let sampleIdx: [Int]
        if n > Self.maxQuery {
            let step = Double(n - 1) / Double(Self.maxQuery - 1)
            var idx = (0..<Self.maxQuery).map { Int((Double($0) * step).rounded()) }
            idx[idx.count - 1] = n - 1
            sampleIdx = idx
        } else {
            sampleIdx = Array(0..<n)
        }
        let coords = sampleIdx.map { (points[$0].latitude, points[$0].longitude) }
        var z = [Double?](repeating: nil, count: coords.count)

        // 1) IGN RGE ALTI — précis, couverture France métropolitaine + DOM. Batches en parallèle.
        let ignBatches = Self.chunk(Array(coords.indices), Self.ignBatch)
        await withTaskGroup(of: (Int, [Double]?).self) { group in
            var launched = 0
            while launched < min(Self.ignConcurrency, ignBatches.count) {
                let b = launched
                let pts = ignBatches[b].map { coords[$0] }
                group.addTask { (b, await Self.fetchIGN(pts)) }
                launched += 1
            }
            while let (b, zs) = await group.next() {
                if let zs {
                    for (k, idx) in ignBatches[b].enumerated() where k < zs.count && zs[k] > Self.invalidThreshold {
                        z[idx] = zs[k]
                    }
                }
                if launched < ignBatches.count {
                    let nb = launched
                    let pts = ignBatches[nb].map { coords[$0] }
                    group.addTask { (nb, await Self.fetchIGN(pts)) }
                    launched += 1
                }
            }
        }

        // 2) Repli mondial pour les points encore sans altitude (séquentiel : OpenTopoData ~1 req/s).
        let missing = z.indices.filter { z[$0] == nil }
        for (i, batch) in Self.chunk(missing, Self.otdBatch).enumerated() {
            if i > 0 { try? await Task.sleep(nanoseconds: 1_100_000_000) }
            if let zs = await Self.fetchOpenTopo(batch.map { coords[$0] }) {
                for (k, idx) in batch.enumerated() {
                    guard k < zs.count, let v = zs[k], v > Self.invalidThreshold else { continue }
                    z[idx] = v
                }
            }
        }

        // 3) Reporter l'altitude sur tous les points (interpolation linéaire entre échantillons connus).
        let fullZ = Self.interpolate(sampleIdx: sampleIdx, sampleZ: z, count: n)
        var resolved = 0
        let enriched = points.enumerated().map { i, p -> TrackPoint in
            guard let alt = fullZ[i] else { return p }
            resolved += 1
            return TrackPoint(latitude: p.latitude, longitude: p.longitude, altitude: alt,
                              timestamp: p.timestamp, heartRate: p.heartRate, cadence: p.cadence, power: p.power)
        }
        return (enriched, resolved)
    }

    /// Étend les altitudes des indices échantillonnés à l'ensemble des points par interpolation linéaire.
    private static func interpolate(sampleIdx: [Int], sampleZ: [Double?], count n: Int) -> [Double?] {
        if sampleIdx.count == n { return sampleZ } // pas d'échantillonnage : retour direct.
        let known: [(Int, Double)] = sampleIdx.enumerated().compactMap { s, idx in sampleZ[s].map { (idx, $0) } }
        guard !known.isEmpty else { return [Double?](repeating: nil, count: n) }
        var out = [Double?](repeating: nil, count: n)
        var ki = 0
        for i in 0..<n {
            while ki + 1 < known.count && known[ki + 1].0 <= i { ki += 1 }
            let (i0, z0) = known[ki]
            if ki + 1 < known.count {
                let (i1, z1) = known[ki + 1]
                if i <= i0 { out[i] = z0 }
                else if i >= i1 { out[i] = z1 }
                else { out[i] = z0 + (z1 - z0) * Double(i - i0) / Double(i1 - i0) }
            } else {
                out[i] = z0
            }
        }
        return out
    }

    // MARK: - IGN

    private struct IGNResponse: Decodable { let elevations: [IGNElevation] }
    private struct IGNElevation: Decodable { let z: Double }

    private static func fetchIGN(_ coords: [(Double, Double)]) async -> [Double]? {
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

    private static func fetchOpenTopo(_ coords: [(Double, Double)]) async -> [Double?]? {
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

    private static func get(_ url: URL) async -> Data? {
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
