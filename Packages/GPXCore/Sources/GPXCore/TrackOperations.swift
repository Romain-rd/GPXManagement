import Foundation

/// Opérations d'édition de traces (non destructives : produisent de nouveaux tableaux de points).
public enum TrackOperations {

    /// Scinde la trace au point `index` — inclus dans les deux moitiés pour la continuité.
    public static func split(points: [TrackPoint], at index: Int) -> (left: [TrackPoint], right: [TrackPoint]) {
        guard !points.isEmpty else { return ([], []) }
        let i = max(0, min(index, points.count - 1))
        return (Array(points[0...i]), Array(points[i...]))
    }

    /// Fusionne plusieurs traces en une, ordonnée par timestamp, en dédoublonnant les horodatages identiques.
    /// Les points sans horodatage sont conservés à la fin, dans leur ordre d'origine.
    public static func merge(_ tracks: [[TrackPoint]]) -> [TrackPoint] {
        let all = tracks.flatMap { $0 }
        let timed = all.filter { $0.timestamp != nil }.sorted { $0.timestamp! < $1.timestamp! }
        let untimed = all.filter { $0.timestamp == nil }
        var result: [TrackPoint] = []
        var lastTimestamp: Date?
        for p in timed {
            if let lastTimestamp, p.timestamp == lastTimestamp { continue }
            result.append(p)
            lastTimestamp = p.timestamp
        }
        result.append(contentsOf: untimed)
        return result
    }

    public struct CleanResult: Sendable, Equatable {
        public let cleaned: [TrackPoint]
        public let removedIndices: [Int]
        public init(cleaned: [TrackPoint], removedIndices: [Int]) {
            self.cleaned = cleaned
            self.removedIndices = removedIndices
        }
    }

    /// Retire les points aberrants : vitesse instantanée > `maxSpeed` (m/s) ou saut > 500 m en < 2 s.
    /// La comparaison se fait toujours par rapport au dernier point conservé.
    public static func cleanOutliers(points: [TrackPoint], maxSpeed: Double = 80) -> CleanResult {
        guard points.count > 1 else { return CleanResult(cleaned: points, removedIndices: []) }
        var cleaned: [TrackPoint] = [points[0]]
        var removed: [Int] = []
        var lastKept = points[0]
        for i in 1..<points.count {
            let p = points[i]
            let distance = Self.haversine(lastKept, p)
            let dt: Double? = (p.timestamp != nil && lastKept.timestamp != nil)
                ? p.timestamp!.timeIntervalSince(lastKept.timestamp!) : nil
            var isOutlier = false
            if let dt, dt > 0, distance / dt > maxSpeed { isOutlier = true }
            if distance > 500, let dt, dt < 2 { isOutlier = true }
            if isOutlier {
                removed.append(i)
            } else {
                cleaned.append(p)
                lastKept = p
            }
        }
        return CleanResult(cleaned: cleaned, removedIndices: removed)
    }

    /// Simplifie la trace par Douglas-Peucker 2D ; `tolerance` en mètres. Premier et dernier points conservés.
    public static func simplify(points: [TrackPoint], tolerance: Double) -> [TrackPoint] {
        guard tolerance > 0, points.count > 2 else { return points }
        let lat0 = points[0].latitude
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        douglasPeucker(points, 0, points.count - 1, tolerance, lat0, &keep)
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Privé

    private static func douglasPeucker(_ pts: [TrackPoint], _ start: Int, _ end: Int,
                                       _ tolerance: Double, _ lat0: Double, _ keep: inout [Bool]) {
        guard end > start + 1 else { return }
        var maxDistance = 0.0
        var farthest = start
        for i in (start + 1)..<end {
            let d = perpendicularDistance(pts[i], pts[start], pts[end], lat0)
            if d > maxDistance { maxDistance = d; farthest = i }
        }
        guard maxDistance > tolerance else { return }
        keep[farthest] = true
        douglasPeucker(pts, start, farthest, tolerance, lat0, &keep)
        douglasPeucker(pts, farthest, end, tolerance, lat0, &keep)
    }

    /// Projection équirectangulaire locale (mètres) autour de `lat0`.
    private static func project(_ p: TrackPoint, _ lat0: Double) -> (x: Double, y: Double) {
        let metersPerDegLat = 110_540.0
        let metersPerDegLon = 111_320.0 * cos(lat0 * .pi / 180)
        return (p.longitude * metersPerDegLon, p.latitude * metersPerDegLat)
    }

    /// Distance (m) d'un point à la droite (a,b), en projection locale.
    private static func perpendicularDistance(_ p: TrackPoint, _ a: TrackPoint, _ b: TrackPoint, _ lat0: Double) -> Double {
        let pp = project(p, lat0), pa = project(a, lat0), pb = project(b, lat0)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(pp.x - pa.x, pp.y - pa.y) }
        let cross = abs(dy * pp.x - dx * pp.y + pb.x * pa.y - pb.y * pa.x)
        return cross / sqrt(lengthSquared)
    }

    private static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}
