import Foundation

/// Source unique de vérité pour positionner un média sur une trace, utilisée partout (carte, web, PDF, film).
/// Position le long du parcours : **manuel → heure de prise → GPS**. L'heure prime sur le GPS car elle lève
/// l'ambiguïté des allers-retours (une même position correspond à deux instants du parcours).
public struct MediaTrackResolver {
    private let lats: [Double]
    private let lons: [Double]
    private let times: [Date?]
    private let cumulative: [Double]
    public let totalDistance: Double

    public init(points: [TrackPoint]) {
        lats = points.map(\.latitude)
        lons = points.map(\.longitude)
        times = points.map(\.timestamp)
        var cum: [Double] = []
        cum.reserveCapacity(points.count)
        var acc = 0.0
        for i in points.indices {
            if i > 0 { acc += GeoMath.haversine(lat1: lats[i - 1], lon1: lons[i - 1], lat2: lats[i], lon2: lons[i]) }
            cum.append(acc)
        }
        cumulative = cum
        totalDistance = cum.last ?? 0
    }

    public var isEmpty: Bool { lats.count < 2 }

    /// Distance le long de la trace (mètres) : manuel → heure → GPS. nil si rien d'exploitable.
    public func distance(manualMeters: Double?, captureDate: Date?, gpsLatitude: Double?, gpsLongitude: Double?) -> Double? {
        if let m = manualMeters { return clamp(m) }
        if let d = captureDate, let i = nearestTimeIndex(d) { return cumulative[i] }
        if let la = gpsLatitude, let lo = gpsLongitude, !isEmpty { return cumulative[nearestGPSIndex(la, lo)] }
        return nil
    }

    /// Coordonnée d'affichage : manuel (interpolé sur la trace) → GPS brut → heure (point de trace le plus proche).
    /// Le GPS brut est conservé tel quel pour l'affichage (position réelle de la photo) ; seul le manuel s'aligne sur la trace.
    public func displayCoordinate(manualMeters: Double?, captureDate: Date?, gpsLatitude: Double?, gpsLongitude: Double?) -> (latitude: Double, longitude: Double)? {
        if let m = manualMeters { return coordinate(atMeters: m) }
        if let la = gpsLatitude, let lo = gpsLongitude { return (la, lo) }
        if let d = captureDate, let i = nearestTimeIndex(d) { return (lats[i], lons[i]) }
        return nil
    }

    /// Coordonnée interpolée sur la polyligne à une distance donnée.
    public func coordinate(atMeters meters: Double) -> (latitude: Double, longitude: Double) {
        guard lats.count >= 2 else { return (lats.first ?? 0, lons.first ?? 0) }
        let target = clamp(meters)
        var i = 1
        while i < cumulative.count && cumulative[i] < target { i += 1 }
        let lo = i - 1, hi = Swift.min(i, lats.count - 1)
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (target - cumulative[lo]) / segLen : 0
        return (lats[lo] + (lats[hi] - lats[lo]) * t, lons[lo] + (lons[hi] - lons[lo]) * t)
    }

    /// Écart entre un point GPS et la trace (mètres) : sert à signaler une incohérence heure/GPS.
    public func distanceFromTrack(latitude: Double, longitude: Double) -> Double? {
        guard !isEmpty else { return nil }
        let i = nearestGPSIndex(latitude, longitude)
        return GeoMath.haversine(lat1: latitude, lon1: longitude, lat2: lats[i], lon2: lons[i])
    }

    private func clamp(_ meters: Double) -> Double { Swift.min(Swift.max(0, meters), totalDistance) }

    private func nearestTimeIndex(_ date: Date) -> Int? {
        var best: Int?
        var bestDelta = Double.greatestFiniteMagnitude
        for i in times.indices {
            guard let t = times[i] else { continue }
            let delta = abs(t.timeIntervalSince(date))
            if delta < bestDelta { bestDelta = delta; best = i }
        }
        return best
    }

    private func nearestGPSIndex(_ lat: Double, _ lon: Double) -> Int {
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for i in lats.indices {
            let d = GeoMath.haversine(lat1: lat, lon1: lon, lat2: lats[i], lon2: lons[i])
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}
