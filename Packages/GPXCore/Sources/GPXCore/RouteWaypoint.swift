import Foundation

/// Point de passage (ancrage) d'un itinéraire éditable : le tracé dense est obtenu en routant entre eux.
public struct RouteWaypoint: Codable, Identifiable, Sendable, Hashable {
    /// Rôle d'un point de passage. `.shaping` oriente le routeur sans être affiché ;
    /// `.poi` est un point d'intérêt nommé traversé sans coupure ; `.stageStop` est une frontière d'étape.
    public enum Role: String, Codable, Sendable, CaseIterable {
        case shaping, poi, stageStop
    }

    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    public var name: String?
    public var role: Role

    public init(id: UUID = UUID(), latitude: Double, longitude: Double, name: String? = nil, role: Role = .shaping) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case id, latitude, longitude, name, role }

    // Décodage tolérant : un blob antérieur (sans `role`) se relit en `.shaping`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .shaping
    }

    /// Ancrages de routage `.shaping` dérivés d'un tracé : tracé simplifié (Douglas-Peucker) puis borné à ~40 points.
    public static func derivedAnchors(from points: [TrackPoint]) -> [RouteWaypoint] {
        guard points.count >= 2 else { return [] }
        var anchors = TrackOperations.simplify(points: points, tolerance: 50)
        if anchors.count > 40 {
            let step = max(1, anchors.count / 40)
            var reduced = stride(from: 0, to: anchors.count, by: step).map { anchors[$0] }
            if reduced.last != points[points.count - 1] { reduced.append(points[points.count - 1]) }
            anchors = reduced
        }
        return anchors.map { RouteWaypoint(latitude: $0.latitude, longitude: $0.longitude, role: .shaping) }
    }

    /// Indice du point de `points` le plus proche d'une coordonnée (plus proche au sens haversine).
    public static func nearestIndex(latitude: Double, longitude: Double, in points: [TrackPoint]) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let d = GeoMath.haversine(lat1: latitude, lon1: longitude, lat2: p.latitude, lon2: p.longitude)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Bornes d'étapes : pour chaque `.stageStop` (dans l'ordre), l'indice du point de `points` le plus proche.
    /// Sert à dériver les plages d'étapes sans stocker d'indices fragiles dans la trace.
    public static func stageBoundaries(_ waypoints: [RouteWaypoint], on points: [TrackPoint]) -> [(stopId: UUID, index: Int)] {
        guard !points.isEmpty else { return [] }
        return waypoints.filter { $0.role == .stageStop }.map {
            ($0.id, nearestIndex(latitude: $0.latitude, longitude: $0.longitude, in: points))
        }
    }
}

public enum RouteWaypointCodec {
    public static func encode(_ waypoints: [RouteWaypoint]) -> Data? {
        waypoints.isEmpty ? nil : try? JSONEncoder().encode(waypoints)
    }
    public static func decode(_ data: Data?) -> [RouteWaypoint] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RouteWaypoint].self, from: data)) ?? []
    }
}
