import Foundation

/// Point de passage (ancrage) d'un itinéraire éditable : le tracé dense est obtenu en routant entre eux.
public struct RouteWaypoint: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    public var name: String?

    public init(id: UUID = UUID(), latitude: Double, longitude: Double, name: String? = nil) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
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
