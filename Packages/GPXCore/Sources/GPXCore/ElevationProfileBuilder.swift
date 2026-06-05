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
    public static func timeByCategory(_ profile: [ElevationProfilePoint], step: Double = 4) -> [SlopeCategory: TimeInterval] {
        guard profile.count >= 2 else { return [:] }
        var result: [SlopeCategory: TimeInterval] = [:]
        for i in 0..<(profile.count - 1) {
            guard let t1 = profile[i].timestamp, let t2 = profile[i + 1].timestamp else { continue }
            let dt = t2.timeIntervalSince(t1)
            guard dt > 0, dt <= 300 else { continue }
            let category = SlopeCategory.category(for: profile[i].slope, step: step)
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

    public static func category(for slope: Double, step: Double = 4) -> SlopeCategory {
        if slope < -step { return .descent }
        let absVal = abs(slope)
        switch absVal {
        case ..<step:       return .gentle
        case ..<(step * 2): return .moderate
        case ..<(step * 3): return .steep
        default:            return .veryStep
        }
    }
}
