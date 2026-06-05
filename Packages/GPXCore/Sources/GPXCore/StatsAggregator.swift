import Foundation

public enum StatsPeriod: Sendable, Hashable {
    case year(Int)
    case month(year: Int, month: Int)
    case custom(start: Date, end: Date)

    public func contains(_ date: Date, calendar: Calendar = .iso8601UTC) -> Bool {
        let comps = calendar.dateComponents([.year, .month], from: date)
        switch self {
        case .year(let y):
            return comps.year == y
        case .month(let y, let m):
            return comps.year == y && comps.month == m
        case .custom(let start, let end):
            return date >= start && date <= end
        }
    }
}

public enum StatsMetric: String, Sendable, CaseIterable, Identifiable {
    case distance
    case elevationGain
    case duration
    case count

    public var id: String { rawValue }

    public func value(for s: ActivitySummary) -> Double {
        switch self {
        case .distance:      return s.distance
        case .elevationGain: return s.elevationGain
        case .duration:      return s.duration
        case .count:         return 1
        }
    }
}

public struct StatsQuery: Sendable, Hashable {
    public let period: StatsPeriod
    public let activityTypes: Set<ActivityType>?

    public init(period: StatsPeriod, activityTypes: Set<ActivityType>? = nil) {
        self.period = period
        self.activityTypes = activityTypes
    }
}

public struct StatsResult: Sendable, Equatable {
    public let totalDistance: Double
    public let totalElevationGain: Double
    public let totalDuration: Double
    public let activityCount: Int
    public let byActivityType: [ActivityType: TypeBreakdown]
    public let byMonth: [Int: MonthBreakdown]?

    public init(totalDistance: Double, totalElevationGain: Double, totalDuration: Double, activityCount: Int, byActivityType: [ActivityType: TypeBreakdown], byMonth: [Int: MonthBreakdown]?) {
        self.totalDistance = totalDistance
        self.totalElevationGain = totalElevationGain
        self.totalDuration = totalDuration
        self.activityCount = activityCount
        self.byActivityType = byActivityType
        self.byMonth = byMonth
    }

    public static let zero = StatsResult(
        totalDistance: 0,
        totalElevationGain: 0,
        totalDuration: 0,
        activityCount: 0,
        byActivityType: [:],
        byMonth: nil
    )
}

public struct TypeBreakdown: Sendable, Equatable {
    public let totalDistance: Double
    public let totalElevationGain: Double
    public let totalDuration: Double
    public let activityCount: Int

    public init(totalDistance: Double, totalElevationGain: Double, totalDuration: Double, activityCount: Int) {
        self.totalDistance = totalDistance
        self.totalElevationGain = totalElevationGain
        self.totalDuration = totalDuration
        self.activityCount = activityCount
    }
}

public struct MonthBreakdown: Sendable, Equatable {
    public let month: Int
    public let totalDistance: Double
    public let totalElevationGain: Double
    public let totalDuration: Double
    public let activityCount: Int
    public let byActivityType: [ActivityType: Double]

    public init(month: Int, totalDistance: Double, totalElevationGain: Double, totalDuration: Double, activityCount: Int, byActivityType: [ActivityType: Double]) {
        self.month = month
        self.totalDistance = totalDistance
        self.totalElevationGain = totalElevationGain
        self.totalDuration = totalDuration
        self.activityCount = activityCount
        self.byActivityType = byActivityType
    }
}

public enum StatsAggregator {
    public static func compute(activities: [ActivitySummary], query: StatsQuery, calendar: Calendar = .iso8601UTC) -> StatsResult {
        let filtered = activities.filter { activity in
            if !query.period.contains(activity.startDate, calendar: calendar) { return false }
            if let types = query.activityTypes, !types.isEmpty, !types.contains(activity.activityType) { return false }
            return true
        }

        var totalDistance: Double = 0
        var totalGain: Double = 0
        var totalDuration: Double = 0
        var typeMap: [ActivityType: (dist: Double, gain: Double, dur: Double, count: Int)] = [:]
        var monthMap: [Int: (dist: Double, gain: Double, dur: Double, count: Int, byType: [ActivityType: Double])] = [:]

        for a in filtered {
            totalDistance += a.distance
            totalGain += a.elevationGain
            totalDuration += a.duration

            var current = typeMap[a.activityType] ?? (0, 0, 0, 0)
            current.dist += a.distance
            current.gain += a.elevationGain
            current.dur += a.duration
            current.count += 1
            typeMap[a.activityType] = current

            if case .year = query.period {
                let month = calendar.component(.month, from: a.startDate)
                var monthEntry = monthMap[month] ?? (0, 0, 0, 0, [:])
                monthEntry.dist += a.distance
                monthEntry.gain += a.elevationGain
                monthEntry.dur += a.duration
                monthEntry.count += 1
                monthEntry.byType[a.activityType, default: 0] += a.distance
                monthMap[month] = monthEntry
            }
        }

        let byType = typeMap.mapValues { entry in
            TypeBreakdown(totalDistance: entry.dist, totalElevationGain: entry.gain, totalDuration: entry.dur, activityCount: entry.count)
        }

        let byMonth: [Int: MonthBreakdown]?
        if case .year = query.period {
            byMonth = monthMap.reduce(into: [:]) { (acc, kv) in
                acc[kv.key] = MonthBreakdown(
                    month: kv.key,
                    totalDistance: kv.value.dist,
                    totalElevationGain: kv.value.gain,
                    totalDuration: kv.value.dur,
                    activityCount: kv.value.count,
                    byActivityType: kv.value.byType
                )
            }
        } else {
            byMonth = nil
        }

        return StatsResult(
            totalDistance: totalDistance,
            totalElevationGain: totalGain,
            totalDuration: totalDuration,
            activityCount: filtered.count,
            byActivityType: byType,
            byMonth: byMonth
        )
    }
}

/// Statistiques d'un ensemble arbitraire d'activités (la sélection, ou la liste filtrée), sans notion de période.
public struct SelectionStats: Sendable, Equatable {
    public let count: Int
    public let totalDistance: Double
    public let totalElevationGain: Double
    public let totalDuration: Double
    public let totalMovingDuration: Double
    public let avgDistance: Double
    public let maxDistance: Double
    public let maxElevationGain: Double
    public let maxSlope: Double
    public let maxSpeed: Double
    public let firstDate: Date?
    public let lastDate: Date?
    public let byActivityType: [ActivityType: TypeBreakdown]

    public init(count: Int, totalDistance: Double, totalElevationGain: Double, totalDuration: Double, totalMovingDuration: Double, avgDistance: Double, maxDistance: Double, maxElevationGain: Double, maxSlope: Double, maxSpeed: Double, firstDate: Date?, lastDate: Date?, byActivityType: [ActivityType: TypeBreakdown]) {
        self.count = count
        self.totalDistance = totalDistance
        self.totalElevationGain = totalElevationGain
        self.totalDuration = totalDuration
        self.totalMovingDuration = totalMovingDuration
        self.avgDistance = avgDistance
        self.maxDistance = maxDistance
        self.maxElevationGain = maxElevationGain
        self.maxSlope = maxSlope
        self.maxSpeed = maxSpeed
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.byActivityType = byActivityType
    }

    public static let zero = SelectionStats(count: 0, totalDistance: 0, totalElevationGain: 0, totalDuration: 0, totalMovingDuration: 0, avgDistance: 0, maxDistance: 0, maxElevationGain: 0, maxSlope: 0, maxSpeed: 0, firstDate: nil, lastDate: nil, byActivityType: [:])

    public static func compute(_ activities: [ActivitySummary]) -> SelectionStats {
        guard let first = activities.first else { return .zero }
        var totalDistance = 0.0, totalGain = 0.0, totalDur = 0.0, totalMoving = 0.0
        var maxDist = 0.0, maxGain = 0.0, maxSlope = 0.0, maxSpeed = 0.0
        var minDate = first.startDate, maxDate = first.startDate
        var typeMap: [ActivityType: (dist: Double, gain: Double, dur: Double, count: Int)] = [:]

        for a in activities {
            totalDistance += a.distance
            totalGain += a.elevationGain
            totalDur += a.duration
            totalMoving += a.movingDuration
            maxDist = max(maxDist, a.distance)
            maxGain = max(maxGain, a.elevationGain)
            maxSlope = max(maxSlope, a.maxSlope)
            maxSpeed = max(maxSpeed, a.maxSpeed)
            if a.startDate < minDate { minDate = a.startDate }
            if a.startDate > maxDate { maxDate = a.startDate }

            var c = typeMap[a.activityType] ?? (0, 0, 0, 0)
            c.dist += a.distance; c.gain += a.elevationGain; c.dur += a.duration; c.count += 1
            typeMap[a.activityType] = c
        }

        let byType = typeMap.mapValues {
            TypeBreakdown(totalDistance: $0.dist, totalElevationGain: $0.gain, totalDuration: $0.dur, activityCount: $0.count)
        }
        return SelectionStats(
            count: activities.count,
            totalDistance: totalDistance,
            totalElevationGain: totalGain,
            totalDuration: totalDur,
            totalMovingDuration: totalMoving,
            avgDistance: totalDistance / Double(activities.count),
            maxDistance: maxDist,
            maxElevationGain: maxGain,
            maxSlope: maxSlope,
            maxSpeed: maxSpeed,
            firstDate: minDate,
            lastDate: maxDate,
            byActivityType: byType
        )
    }
}

public struct CumulativePoint: Sendable, Equatable, Identifiable {
    public let dayOfYear: Int
    public let cumulativeValue: Double
    public var id: Int { dayOfYear }

    public init(dayOfYear: Int, cumulativeValue: Double) {
        self.dayOfYear = dayOfYear
        self.cumulativeValue = cumulativeValue
    }
}

public enum YearComparisonBuilder {
    public static func cumulative(activities: [ActivitySummary], year: Int, metric: StatsMetric, calendar: Calendar = .iso8601UTC) -> [CumulativePoint] {
        let filtered = activities.filter { calendar.component(.year, from: $0.startDate) == year }
        let sorted = filtered.sorted { $0.startDate < $1.startDate }

        let lastDay = isLeapYear(year) ? 366 : 365
        var dailyTotal = [Double](repeating: 0, count: lastDay + 1)
        for a in sorted {
            let day = calendar.ordinality(of: .day, in: .year, for: a.startDate) ?? 1
            dailyTotal[day] += metric.value(for: a)
        }

        var cumulative: Double = 0
        var result: [CumulativePoint] = []
        result.reserveCapacity(lastDay)
        for d in 1...lastDay {
            cumulative += dailyTotal[d]
            result.append(CumulativePoint(dayOfYear: d, cumulativeValue: cumulative))
        }
        return result
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    }
}
