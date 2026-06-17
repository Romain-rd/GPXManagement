import Foundation
import GPXCore
import MapKit

/// Calcule un raccord piéton entre deux points (du tracé vers un point hors-trace).
/// Nommage de points via OpenStreetMap : cols/sommets (Overpass, une requête groupée) puis lieu habité (Nominatim).
enum OSMNaming {
    struct NamedPoint { let coordinate: CLLocationCoordinate2D; let name: String }

    /// Cols, sommets et lieux-dits remarquables à proximité de l'ensemble des points (une seule requête Overpass).
    static func passes(near coords: [CLLocationCoordinate2D]) async -> [NamedPoint] {
        guard !coords.isEmpty else { return [] }
        let around = coords.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let query = "[out:json][timeout:25];(" +
            "node(around:800,\(around))[mountain_pass];" +
            "node(around:800,\(around))[natural=saddle];" +
            "node(around:600,\(around))[natural=peak][name];" +
            ");out tags;"
        struct Resp: Decodable { let elements: [El]; struct El: Decodable { let lat: Double?; let lon: Double?; let tags: [String: String]? } }
        // Plusieurs miroirs publics : leur disponibilité est inégale, on bascule au premier qui répond.
        let hosts = [
            "https://overpass-api.de/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"
        ]
        for host in hosts {
            guard let url = URL(string: host) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(Resp.self, from: data) else { continue }
            return parsed.elements.compactMap { e in
                guard let lat = e.lat, let lon = e.lon, let name = e.tags?["name"], !name.isEmpty else { return nil }
                return NamedPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), name: name)
            }
        }
        return []
    }

    /// Le nom le plus proche d'une coordonnée dans une liste, si sous le seuil (mètres).
    static func nearestName(_ points: [NamedPoint], to c: CLLocationCoordinate2D, within meters: Double) -> String? {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var best: (Double, String)?
        for p in points {
            let d = CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude).distance(from: here)
            if d <= meters, best == nil || d < best!.0 { best = (d, p.name) }
        }
        return best?.1
    }

    /// Lieu habité (ville/village) via Nominatim — repli quand aucun col/sommet n'est proche.
    static func place(_ c: CLLocationCoordinate2D) async -> String? {
        var comps = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: String(format: "%.6f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", c.longitude)),
            URLQueryItem(name: "zoom", value: "14"),
            URLQueryItem(name: "addressdetails", value: "1")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("GPXManagement/1.0 (rd_claude@demoustier.com)", forHTTPHeaderField: "User-Agent")
        struct Resp: Decodable { let name: String?; let address: [String: String]? }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return nil }
        let a = r.address ?? [:]
        for key in ["village", "town", "city", "hamlet", "municipality", "suburb", "locality"] {
            if let v = a[key], !v.isEmpty { return v }
        }
        if let n = r.name, !n.isEmpty { return n }
        return a["county"]
    }
}
