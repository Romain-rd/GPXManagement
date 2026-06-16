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

    /// Bornes d'étapes : pour chaque `.stageStop` (dans l'ordre), l'indice du point de `points` le plus proche.
    /// Sert à dériver les plages d'étapes sans stocker d'indices fragiles dans la trace.
    public static func stageBoundaries(_ waypoints: [RouteWaypoint], on points: [TrackPoint]) -> [(stopId: UUID, index: Int)] {
        guard !points.isEmpty else { return [] }
        return waypoints.filter { $0.role == .stageStop }.map { wp in
            var bestIndex = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (i, p) in points.enumerated() {
                let d = GeoMath.haversine(lat1: wp.latitude, lon1: wp.longitude, lat2: p.latitude, lon2: p.longitude)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            return (wp.id, bestIndex)
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
