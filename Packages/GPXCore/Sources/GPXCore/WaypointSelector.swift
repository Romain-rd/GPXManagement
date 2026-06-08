import Foundation

public struct RouteWaypoints: Sendable, Equatable {
    public let start: TrackPoint
    /// Principaux points de passage, ordonnés le long du parcours (cols/sommets ou points éloignés).
    public let vias: [TrackPoint]
    public let end: TrackPoint
    public let isLoop: Bool

    public init(start: TrackPoint, vias: [TrackPoint], end: TrackPoint, isLoop: Bool) {
        self.start = start
        self.vias = vias
        self.end = end
        self.isLoop = isLoop
    }
}

public enum WaypointSelector {
    public static func waypoints(
        from points: [TrackPoint],
        loopThresholdMeters: Double = 500,
        elevationSignificanceMeters: Double = 150,
        minViaSeparationMeters: Double = 500,
        maxLoopVias: Int = 3
    ) -> RouteWaypoints? {
        guard let start = points.first, let end = points.last, points.count >= 2 else { return nil }

        let startEndDistance = GeoMath.distance(start, end)
        let isLoop = startEndDistance < loopThresholdMeters

        // Une boucle liste plusieurs points de passage (départ → cols/villes → …) ; un aller liste le point principal.
        let vias = selectVias(
            points: points,
            start: start,
            end: end,
            count: isLoop ? maxLoopVias : 1,
            elevationSignificanceMeters: elevationSignificanceMeters,
            minViaSeparationMeters: minViaSeparationMeters
        )

        return RouteWaypoints(start: start, vias: vias, end: end, isLoop: isLoop)
    }

    /// Jusqu'à `count` points de passage notables, bien séparés, ordonnés le long du parcours.
    /// Classés par altitude si le dénivelé est significatif (cols/sommets), sinon par éloignement du départ.
    private static func selectVias(
        points: [TrackPoint],
        start: TrackPoint,
        end: TrackPoint,
        count: Int,
        elevationSignificanceMeters: Double,
        minViaSeparationMeters: Double
    ) -> [TrackPoint] {
        guard count > 0 else { return [] }
        let altitudes = points.compactMap(\.altitude)
        let significant = (altitudes.max() ?? 0) - (altitudes.min() ?? 0) >= elevationSignificanceMeters

        let ranked: [(index: Int, point: TrackPoint)]
        if significant {
            ranked = points.enumerated()
                .filter { $0.element.altitude != nil }
                .sorted { ($0.element.altitude ?? 0) > ($1.element.altitude ?? 0) }
                .map { (index: $0.offset, point: $0.element) }
        } else {
            ranked = points.enumerated()
                .sorted { GeoMath.distance(start, $0.element) > GeoMath.distance(start, $1.element) }
                .map { (index: $0.offset, point: $0.element) }
        }

        var picked: [(index: Int, point: TrackPoint)] = []
        for cand in ranked {
            if GeoMath.distance(cand.point, start) < minViaSeparationMeters { continue }
            if GeoMath.distance(cand.point, end) < minViaSeparationMeters { continue }
            if picked.contains(where: { GeoMath.distance($0.point, cand.point) < minViaSeparationMeters }) { continue }
            picked.append(cand)
            if picked.count >= count { break }
        }
        return picked.sorted { $0.index < $1.index }.map(\.point)
    }
}
