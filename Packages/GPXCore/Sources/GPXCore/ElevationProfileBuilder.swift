import Foundation

public struct ElevationProfilePoint: Sendable, Equatable {
    public let distanceFromStart: Double
    public let altitude: Double
    public let slope: Double
    public let timestamp: Date?
    public let heartRate: Double?
    public let latitude: Double?
    public let longitude: Double?

    public init(distanceFromStart: Double, altitude: Double, slope: Double, timestamp: Date? = nil, heartRate: Double? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.distanceFromStart = distanceFromStart
        self.altitude = altitude
        self.slope = slope
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum ElevationProfileBuilder {
    private static let earthRadius: Double = 6_371_000
    private static let slopeHalfWindowMeters: Double = 75
    private static let smoothingWindow = 9

    public static func build(points: [TrackPoint]) -> [ElevationProfilePoint] {
        let withAlt = points.filter { $0.altitude != nil }
        guard withAlt.count >= 2 else { return [] }

        var distances: [Double] = [0]
        distances.reserveCapacity(withAlt.count)
        for i in 1..<withAlt.count {
            let p = withAlt[i - 1]
            let q = withAlt[i]
            distances.append(distances[i - 1] + haversine(lat1: p.latitude, lon1: p.longitude, lat2: q.latitude, lon2: q.longitude))
        }

        let altitudes = withAlt.map { $0.altitude ?? 0 }
        let smoothed = movingAverage(altitudes, window: smoothingWindow)

        var profile: [ElevationProfilePoint] = []
        profile.reserveCapacity(withAlt.count)

        for i in 0..<withAlt.count {
            let slope = computeSlope(at: i, distances: distances, smoothedAltitudes: smoothed)
            profile.append(ElevationProfilePoint(distanceFromStart: distances[i], altitude: smoothed[i], slope: slope, timestamp: withAlt[i].timestamp, heartRate: withAlt[i].heartRate, latitude: withAlt[i].latitude, longitude: withAlt[i].longitude))
        }
        return profile
    }

    /// Profil « mouvement » construit sur TOUS les points (sans exiger d'altitude) : distance/temps/coordonnées.
    /// Sert au profil de vitesse pour les activités sans altitude (ex. voile). Altitude=0 et pente=0.
    public static func buildMotion(points: [TrackPoint]) -> [ElevationProfilePoint] {
        guard points.count >= 2 else { return [] }
        var result: [ElevationProfilePoint] = []
        result.reserveCapacity(points.count)
        var dist = 0.0
        for i in 0..<points.count {
            if i > 0 {
                dist += haversine(lat1: points[i - 1].latitude, lon1: points[i - 1].longitude, lat2: points[i].latitude, lon2: points[i].longitude)
            }
            let p = points[i]
            result.append(ElevationProfilePoint(distanceFromStart: dist, altitude: p.altitude ?? 0, slope: 0, timestamp: p.timestamp, heartRate: p.heartRate, latitude: p.latitude, longitude: p.longitude))
        }
        return result
    }

    private static let movingSpeedThreshold: Double = 0.5

    /// Temps cumulé en mouvement vs à l'arrêt, calculé sur le profil non décimé.
    /// Les intervalles aberrants (gaps > 5 min, généralement enregistrement coupé) sont ignorés.
    public static func movementTime(_ profile: [ElevationProfilePoint]) -> (moving: TimeInterval, paused: TimeInterval) {
        guard profile.count >= 2 else { return (0, 0) }
        var moving: TimeInterval = 0
        var paused: TimeInterval = 0
        for i in 0..<(profile.count - 1) {
            guard let t1 = profile[i].timestamp, let t2 = profile[i + 1].timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0, dt <= 300 else { continue }
            let dd = profile[i + 1].distanceFromStart - profile[i].distanceFromStart
            if dd / dt > movingSpeedThreshold { moving += dt } else { paused += dt }
        }
        return (moving, paused)
    }

    /// Temps cumulé passé dans chaque catégorie de pente, calculé sur le profil non décimé.
    /// Les intervalles aberrants (gaps/pauses > 5 min) sont ignorés.
    /// Marque les segments appartenant à une pause longue : rester dans `pauseRadiusMeters` pendant ≥ `pauseMinSeconds`
    /// (robuste au jitter GPS à l'arrêt). Retourne un drapeau par segment (taille = profile.count − 1).
    public static func pausedSegmentFlags(_ profile: [ElevationProfilePoint], pauseMinSeconds: Double, pauseRadiusMeters: Double) -> [Bool] {
        let n = profile.count
        guard n > 1 else { return [] }
        func dist(_ a: Int, _ b: Int) -> Double? {
            guard let la = profile[a].latitude, let lo = profile[a].longitude,
                  let lb = profile[b].latitude, let lob = profile[b].longitude else { return nil }
            return haversine(lat1: la, lon1: lo, lat2: lb, lon2: lob)
        }
        var paused = [Bool](repeating: false, count: n - 1)
        var i = 0
        while i < n - 1 {
            var j = i
            while j + 1 < n, let d = dist(i, j + 1), d <= pauseRadiusMeters { j += 1 }
            if j > i, let ti = profile[i].timestamp, let tj = profile[j].timestamp, tj.timeIntervalSince(ti) >= pauseMinSeconds {
                for s in i..<j { paused[s] = true }
                i = j + 1
            } else {
                i += 1
            }
        }
        return paused
    }

    /// Répartition du temps en 4 seaux disjoints (somme = temps écoulé) : montée, descente, plat, pause.
    /// Le reste (hors pause) est classé par pente lissée (zone morte `flatPercent` autour de 0 = plat).
    public static func timeBreakdown(_ profile: [ElevationProfilePoint],
                                     pauseMinSeconds: Double = 300, pauseRadiusMeters: Double = 40,
                                     flatPercent: Double = 1.0) -> (ascending: TimeInterval, descending: TimeInterval, flat: TimeInterval, paused: TimeInterval) {
        let n = profile.count
        guard n > 1 else { return (0, 0, 0, 0) }
        let paused = pausedSegmentFlags(profile, pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        var asc: TimeInterval = 0, desc: TimeInterval = 0, flat: TimeInterval = 0, pau: TimeInterval = 0
        for s in 0..<(n - 1) {
            guard let t1 = profile[s].timestamp, let t2 = profile[s + 1].timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0 else { continue }
            if paused[s] { pau += dt; continue }
            let slope = profile[s].slope
            if slope > flatPercent { asc += dt }
            else if slope < -flatPercent { desc += dt }
            else { flat += dt }
        }
        return (asc, desc, flat, pau)
    }

    /// Temps par catégorie de pente **hors pauses** + temps total des pauses (mêmes pauses que `timeBreakdown`).
    /// Pour la légende du profil : les bandes de pente + la pause somment au temps total écoulé.
    public static func slopeTimesAndPause(_ profile: [ElevationProfilePoint], scale: SlopeScale = .percent,
                                          pauseMinSeconds: Double = 300, pauseRadiusMeters: Double = 40)
        -> (byCategory: [SlopeCategory: TimeInterval], paused: TimeInterval) {
        let n = profile.count
        guard n > 1 else { return ([:], 0) }
        let paused = pausedSegmentFlags(profile, pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        var byCat: [SlopeCategory: TimeInterval] = [:]
        var pau: TimeInterval = 0
        for s in 0..<(n - 1) {
            guard let t1 = profile[s].timestamp, let t2 = profile[s + 1].timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0 else { continue }
            if paused[s] { pau += dt; continue }
            byCat[scale.category(for: profile[s].slope), default: 0] += dt
        }
        return (byCat, pau)
    }

    public static func timeByCategory(_ profile: [ElevationProfilePoint], scale: SlopeScale = .percent) -> [SlopeCategory: TimeInterval] {
        guard profile.count >= 2 else { return [:] }
        var result: [SlopeCategory: TimeInterval] = [:]
        for i in 0..<(profile.count - 1) {
            guard let t1 = profile[i].timestamp, let t2 = profile[i + 1].timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0, dt <= 300 else { continue }
            let category = scale.category(for: profile[i].slope)
            result[category, default: 0] += dt
        }
        return result
    }

    public static func decimate(_ profile: [ElevationProfilePoint], tolerance: Double = 1.0, maxPoints: Int = 5000) -> [ElevationProfilePoint] {
        guard profile.count > maxPoints else { return profile }
        let indices = douglasPeucker(profile: profile, tolerance: tolerance)
        return indices.map { profile[$0] }
    }

    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count >= window else { return values }
        let half = window / 2
        var result = [Double](repeating: 0, count: values.count)
        for i in 0..<values.count {
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            let slice = values[lo...hi]
            result[i] = slice.reduce(0, +) / Double(slice.count)
        }
        return result
    }

    private static func computeSlope(at i: Int, distances: [Double], smoothedAltitudes: [Double]) -> Double {
        let center = distances[i]
        var loIdx = i
        while loIdx > 0, center - distances[loIdx] < slopeHalfWindowMeters {
            loIdx -= 1
        }
        var hiIdx = i
        while hiIdx < distances.count - 1, distances[hiIdx] - center < slopeHalfWindowMeters {
            hiIdx += 1
        }
        let dDist = distances[hiIdx] - distances[loIdx]
        guard dDist > 1 else { return 0 }
        let dAlt = smoothedAltitudes[hiIdx] - smoothedAltitudes[loIdx]
        return (dAlt / dDist) * 100.0
    }

    private static func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }

    private static func douglasPeucker(profile: [ElevationProfilePoint], tolerance: Double) -> [Int] {
        guard profile.count > 2 else { return Array(0..<profile.count) }
        var keep = [Bool](repeating: false, count: profile.count)
        keep[0] = true
        keep[profile.count - 1] = true
        simplify(profile: profile, start: 0, end: profile.count - 1, tolerance: tolerance, keep: &keep)
        return (0..<profile.count).filter { keep[$0] }
    }

    private static func simplify(profile: [ElevationProfilePoint], start: Int, end: Int, tolerance: Double, keep: inout [Bool]) {
        guard end - start > 1 else { return }
        var maxDistance: Double = 0
        var maxIndex = start
        let x1 = profile[start].distanceFromStart
        let y1 = profile[start].altitude
        let x2 = profile[end].distanceFromStart
        let y2 = profile[end].altitude
        let dx = x2 - x1
        let dy = y2 - y1
        let length = sqrt(dx * dx + dy * dy)
        for i in (start + 1)..<end {
            let x0 = profile[i].distanceFromStart
            let y0 = profile[i].altitude
            let dist: Double
            if length > 0 {
                dist = abs(dy * x0 - dx * y0 + x2 * y1 - y2 * x1) / length
            } else {
                let ex = x0 - x1
                let ey = y0 - y1
                dist = sqrt(ex * ex + ey * ey)
            }
            if dist > maxDistance {
                maxDistance = dist
                maxIndex = i
            }
        }
        if maxDistance > tolerance {
            keep[maxIndex] = true
            simplify(profile: profile, start: start, end: maxIndex, tolerance: tolerance, keep: &keep)
            simplify(profile: profile, start: maxIndex, end: end, tolerance: tolerance, keep: &keep)
        }
    }
}

public enum SlopeCategory: Sendable, Hashable {
    case gentle
    case moderate
    case steep
    case veryStep
    case descent

    /// Bandes ascendantes, de la plus douce à la plus raide (la descente est traitée à part).
    static let ascending: [SlopeCategory] = [.gentle, .moderate, .steep, .veryStep]

    /// Couleur canonique RGB (0–1) — source unique pour l'app, la trace sur carte et l'export HTML.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .gentle:   return (0.20, 0.78, 0.35) // vert
        case .moderate: return (1.00, 0.80, 0.00) // jaune
        case .steep:    return (1.00, 0.58, 0.00) // orange
        case .veryStep: return (1.00, 0.23, 0.19) // rouge
        case .descent:  return (0.00, 0.48, 1.00) // bleu
        }
    }
}

/// Échelle de classement de la pente, en % (grade). `bounds` contient N bornes croissantes → N+1 bandes ascendantes.
public struct SlopeScale: Sendable, Equatable {
    public let bounds: [Double]

    public static let percent = SlopeScale(bounds: [4, 8, 12])

    public init(bounds: [Double]) {
        self.bounds = bounds
    }

    /// Catégories de cette échelle dans l'ordre d'affichage (bandes ascendantes puis descente).
    public var categories: [SlopeCategory] {
        Array(SlopeCategory.ascending.prefix(bounds.count + 1)) + [.descent]
    }

    public func category(for slope: Double) -> SlopeCategory {
        if slope < -bounds[0] { return .descent }
        let absVal = abs(slope)
        for (i, bound) in bounds.enumerated() where absVal < bound {
            return SlopeCategory.ascending[i]
        }
        return SlopeCategory.ascending[bounds.count]
    }

    public func label(for category: SlopeCategory) -> String {
        guard let idx = SlopeCategory.ascending.firstIndex(of: category) else { return "Descente" }
        func n(_ v: Double) -> String { String(Int(v.rounded())) }
        if idx == 0 {
            return "0–\(n(bounds[0])) %"
        } else if idx >= bounds.count {
            return "> \(n(bounds[bounds.count - 1])) %"
        } else {
            return "\(n(bounds[idx - 1]))–\(n(bounds[idx])) %"
        }
    }
}
