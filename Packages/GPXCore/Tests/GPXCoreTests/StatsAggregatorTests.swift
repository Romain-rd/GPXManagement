import XCTest
@testable import GPXCore

final class StatsAggregatorTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar.iso8601UTC.date(from: c)!
    }

    private func activity(type: ActivityType = .cyclingRoad, year: Int = 2025, month: Int = 6, day: Int = 1, distance: Double = 10_000, elevationGain: Double = 500, duration: Double = 3600) -> ActivitySummary {
        let d = date(year, month, day)
        return ActivitySummary(
            id: UUID(), title: "t", activityType: type, startDate: d, endDate: d.addingTimeInterval(duration),
            distance: distance, duration: duration, movingDuration: duration,
            elevationGain: elevationGain, elevationLoss: 0,
            avgSpeed: 0, maxSpeed: 0, avgHeartRate: nil, maxHeartRate: nil,
            sourceFileName: "", sourceFileFormat: .gpx, tags: [], notes: nil
        )
    }

    func testYearAggregationTotals() {
        let activities = [
            activity(type: .cyclingRoad, year: 2025, month: 3, distance: 50_000, elevationGain: 800),
            activity(type: .cyclingRoad, year: 2025, month: 7, distance: 80_000, elevationGain: 1_200),
            activity(type: .hiking,     year: 2025, month: 8, distance: 12_000, elevationGain: 600),
            activity(type: .cyclingRoad, year: 2024, month: 3, distance: 999_999, elevationGain: 999_999)
        ]
        let result = StatsAggregator.compute(activities: activities, query: StatsQuery(period: .year(2025)))
        XCTAssertEqual(result.totalDistance, 142_000)
        XCTAssertEqual(result.totalElevationGain, 2_600)
        XCTAssertEqual(result.activityCount, 3)
        XCTAssertEqual(result.byActivityType[.cyclingRoad]?.totalDistance, 130_000)
        XCTAssertEqual(result.byActivityType[.hiking]?.activityCount, 1)
        XCTAssertNotNil(result.byMonth)
        XCTAssertEqual(result.byMonth?[7]?.totalDistance, 80_000)
        XCTAssertEqual(result.byMonth?[8]?.byActivityType[.hiking], 12_000)
    }

    func testActivityTypeFilter() {
        let activities = [
            activity(type: .cyclingRoad, year: 2025, distance: 10),
            activity(type: .hiking, year: 2025, distance: 20)
        ]
        let result = StatsAggregator.compute(activities: activities, query: StatsQuery(period: .year(2025), activityTypes: [.hiking]))
        XCTAssertEqual(result.activityCount, 1)
        XCTAssertEqual(result.totalDistance, 20)
    }

    func testMonthPeriodNoMonthlyBreakdown() {
        let activities = [
            activity(year: 2025, month: 6, distance: 10),
            activity(year: 2025, month: 7, distance: 20)
        ]
        let result = StatsAggregator.compute(activities: activities, query: StatsQuery(period: .month(year: 2025, month: 6)))
        XCTAssertEqual(result.totalDistance, 10)
        XCTAssertNil(result.byMonth)
    }

    func testEmptyActivities() {
        let result = StatsAggregator.compute(activities: [], query: StatsQuery(period: .year(2025)))
        XCTAssertEqual(result.activityCount, 0)
        XCTAssertEqual(result.totalDistance, 0)
        XCTAssertEqual(result.byMonth?.count ?? 0, 0)
    }
}

final class YearComparisonBuilderTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar.iso8601UTC.date(from: c)!
    }

    private func activity(year: Int = 2025, month: Int = 1, day: Int = 1, distance: Double = 10_000) -> ActivitySummary {
        let d = date(year, month, day)
        return ActivitySummary(
            id: UUID(), title: "t", activityType: .cyclingRoad, startDate: d, endDate: d,
            distance: distance, duration: 0, movingDuration: 0,
            elevationGain: 0, elevationLoss: 0,
            avgSpeed: 0, maxSpeed: 0, avgHeartRate: nil, maxHeartRate: nil,
            sourceFileName: "", sourceFileFormat: .gpx, tags: [], notes: nil
        )
    }

    func testCumulativeMonotonicallyIncreasing() {
        let activities = [
            activity(year: 2025, month: 1, day: 5, distance: 10_000),
            activity(year: 2025, month: 4, day: 15, distance: 20_000),
            activity(year: 2025, month: 10, day: 1, distance: 30_000)
        ]
        let curve = YearComparisonBuilder.cumulative(activities: activities, year: 2025, metric: .distance)
        XCTAssertEqual(curve.count, 365)
        XCTAssertEqual(curve[0].cumulativeValue, 0)
        XCTAssertEqual(curve.last?.cumulativeValue, 60_000)
        for i in 1..<curve.count {
            XCTAssertGreaterThanOrEqual(curve[i].cumulativeValue, curve[i - 1].cumulativeValue)
        }
    }

    func testCumulativeRespectsMetric() {
        let activities = [
            activity(year: 2025, month: 6, day: 1, distance: 100_000)
        ]
        let countCurve = YearComparisonBuilder.cumulative(activities: activities, year: 2025, metric: .count)
        XCTAssertEqual(countCurve.last?.cumulativeValue, 1)
    }

    func testLeapYearHas366Days() {
        let curve = YearComparisonBuilder.cumulative(activities: [], year: 2024, metric: .distance)
        XCTAssertEqual(curve.count, 366)
    }
}
