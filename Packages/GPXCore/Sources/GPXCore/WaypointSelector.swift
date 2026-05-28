import Foundation

public struct RouteWaypoints: Sendable, Equatable {
    public let start: TrackPoint
    public let via: TrackPoint?
    public let end: TrackPoint
    public let isLoop: Bool

    public init(start: TrackPoint, via: TrackPoint?, end: TrackPoint, isLoop: Bool) {
        self.start = start
        self.via = via
        self.end = end
        self.isLoop = isLoop
    }
}

public enum WaypointSelector {
    public static func waypoints(
        from points: [TrackPoint],
        loopThresholdMeters: Double = 500,
        elevationSignificanceMeters: Double = 150,
        minViaSeparationMeters: Double = 500
    ) -> RouteWaypoints? {
        guard let start = points.first, let end = points.last, points.count >= 2 else { return nil }

        let startEndDistance = GeoMath.distance(start, end)
        let isLoop = startEndDistance < loopThresholdMeters

        let via = selectVia(
            points: points,
            start: start,
            end: end,
            elevationSignificanceMeters: elevationSignificanceMeters,
            minViaSeparationMeters: minViaSeparationMeters
        )

        return RouteWaypoints(start: start, via: via, end: end, isLoop: isLoop)
    }

    private static func selectVia(
        points: [TrackPoint],
        start: TrackPoint,
        end: TrackPoint,
        elevationSignificanceMeters: Double,
        minViaSeparationMeters: Double
    ) -> TrackPoint? {
        let altitudes = points.compactMap(\.altitude)
        let candidate: TrackPoint?

        if let minAlt = altitudes.min(), let maxAlt = altitudes.max(), (maxAlt - minAlt) >= elevationSignificanceMeters {
            candidate = points
                .filter { $0.altitude != nil }
                .max { ($0.altitude ?? 0) < ($1.altitude ?? 0) }
        } else {
            candidate = points.max { GeoMath.distance(start, $0) < GeoMath.distance(start, $1) }
        }

        guard let candidate else { return nil }
        if GeoMath.distance(candidate, start) < minViaSeparationMeters { return nil }
        if GeoMath.distance(candidate, end) < minViaSeparationMeters { return nil }
        return candidate
    }
}
