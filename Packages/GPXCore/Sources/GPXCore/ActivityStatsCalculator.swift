import Foundation

public struct BoundingBox: Sendable, Equatable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    public static let zero = BoundingBox(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0)
}

public struct ActivityStats: Sendable, Equatable {
    public let distance: Double
    public let duration: Double
    public let movingDuration: Double
    public let elevationGain: Double
    public let elevationLoss: Double
    public let avgSpeed: Double
    public let maxSpeed: Double
    public let avgHeartRate: Double?
    public let maxHeartRate: Double?
    public let boundingBox: BoundingBox

    public static let zero = ActivityStats(
        distance: 0, duration: 0, movingDuration: 0,
        elevationGain: 0, elevationLoss: 0,
        avgSpeed: 0, maxSpeed: 0,
        avgHeartRate: nil, maxHeartRate: nil,
        boundingBox: .zero
    )

    public init(distance: Double, duration: Double, movingDuration: Double, elevationGain: Double, elevationLoss: Double, avgSpeed: Double, maxSpeed: Double, avgHeartRate: Double?, maxHeartRate: Double?, boundingBox: BoundingBox) {
        self.distance = distance
        self.duration = duration
        self.movingDuration = movingDuration
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.avgSpeed = avgSpeed
        self.maxSpeed = maxSpeed
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.boundingBox = boundingBox
    }
}

public enum ActivityStatsCalculator {
    private static let earthRadius: Double = 6_371_000
    private static let movingThreshold: Double = 0.5
    private static let elevationFilterMeters: Double = 3.0
    private static let maxSpeedWindowSeconds: Double = 5.0

    public static func compute(points: [TrackPoint]) -> ActivityStats {
        guard points.count > 1 else { return .zero }

        let bbox = boundingBox(points)

        var distance: Double = 0
        var movingDuration: Double = 0
        var cumulativeDistances: [Double] = [0]
        cumulativeDistances.reserveCapacity(points.count)
        var times: [Date?] = [points[0].timestamp]
        times.reserveCapacity(points.count)

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let segment = haversine(lat1: prev.latitude, lon1: prev.longitude, lat2: curr.latitude, lon2: curr.longitude)
            distance += segment
            cumulativeDistances.append(distance)
            times.append(curr.timestamp)

            if let t1 = prev.timestamp, let t2 = curr.timestamp {
                let dt = t2.timeIntervalSince(t1)
                if dt > 0 && segment / dt > movingThreshold {
                    movingDuration += dt
                }
            }
        }

        let duration: Double
        if let first = points.first?.timestamp, let last = points.last?.timestamp {
            duration = max(0, last.timeIntervalSince(first))
        } else {
            duration = 0
        }

        let avgSpeed: Double
        if movingDuration > 0 {
            avgSpeed = distance / movingDuration
        } else if duration > 0 {
            avgSpeed = distance / duration
        } else {
            avgSpeed = 0
        }

        let maxSpeed = computeMaxSpeed(cumulativeDistances: cumulativeDistances, times: times)
        let (gain, loss) = computeElevation(points: points)
        let (avgHR, maxHR) = computeHeartRate(points: points)

        return ActivityStats(
            distance: distance,
            duration: duration,
            movingDuration: movingDuration,
            elevationGain: gain,
            elevationLoss: loss,
            avgSpeed: avgSpeed,
            maxSpeed: maxSpeed,
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            boundingBox: bbox
        )
    }

    private static func boundingBox(_ points: [TrackPoint]) -> BoundingBox {
        var minLat = points[0].latitude, maxLat = points[0].latitude
        var minLon = points[0].longitude, maxLon = points[0].longitude
        for p in points {
            if p.latitude < minLat { minLat = p.latitude }
            if p.latitude > maxLat { maxLat = p.latitude }
            if p.longitude < minLon { minLon = p.longitude }
            if p.longitude > maxLon { maxLon = p.longitude }
        }
        return BoundingBox(minLatitude: minLat, maxLatitude: maxLat, minLongitude: minLon, maxLongitude: maxLon)
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

    private static func computeElevation(points: [TrackPoint]) -> (gain: Double, loss: Double) {
        let elevations = points.compactMap(\.altitude)
        guard elevations.count > 1 else { return (0, 0) }

        var smoothed = [Double](repeating: 0, count: elevations.count)
        let alpha = 0.2
        smoothed[0] = elevations[0]
        for i in 1..<elevations.count {
            smoothed[i] = alpha * elevations[i] + (1 - alpha) * smoothed[i - 1]
        }

        var gain: Double = 0
        var loss: Double = 0
        var anchor = smoothed[0]
        for value in smoothed.dropFirst() {
            let delta = value - anchor
            if delta >= elevationFilterMeters {
                gain += delta
                anchor = value
            } else if delta <= -elevationFilterMeters {
                loss += -delta
                anchor = value
            }
        }
        return (gain, loss)
    }

    private static func computeMaxSpeed(cumulativeDistances: [Double], times: [Date?]) -> Double {
        var maxSpeed: Double = 0
        var i = 0
        while i < cumulativeDistances.count {
            guard let ti = times[i] else { i += 1; continue }
            var j = i + 1
            while j < cumulativeDistances.count {
                guard let tj = times[j] else { j += 1; continue }
                let dt = tj.timeIntervalSince(ti)
                if dt >= maxSpeedWindowSeconds {
                    let dd = cumulativeDistances[j] - cumulativeDistances[i]
                    let v = dd / dt
                    if v > maxSpeed { maxSpeed = v }
                    break
                }
                j += 1
            }
            i += 1
        }
        return maxSpeed
    }

    private static func computeHeartRate(points: [TrackPoint]) -> (avg: Double?, max: Double?) {
        let hrs = points.compactMap(\.heartRate)
        guard !hrs.isEmpty else { return (nil, nil) }
        let avg = hrs.reduce(0, +) / Double(hrs.count)
        let maxHR = hrs.max() ?? 0
        return (avg, maxHR)
    }
}
