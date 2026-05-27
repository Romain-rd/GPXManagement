import XCTest
import GPXCore
@testable import GPXManagement

final class ActivityFiltersTests: XCTestCase {
    private func sample(type: ActivityType = .cyclingRoad, year: Int = 2025, tags: [String] = []) -> ActivitySummary {
        var c = DateComponents(); c.year = year; c.month = 6; c.day = 1
        let date = Calendar.current.date(from: c)!
        return ActivitySummary(
            id: UUID(), title: "x", activityType: type, startDate: date, endDate: date,
            distance: 0, duration: 0, movingDuration: 0, elevationGain: 0, elevationLoss: 0,
            avgSpeed: 0, maxSpeed: 0, avgHeartRate: nil, maxHeartRate: nil,
            sourceFileName: "x.gpx", sourceFileFormat: .gpx, tags: tags, notes: nil
        )
    }

    func testEmptyFilterMatchesEverything() {
        let filters = ActivityFilters()
        XCTAssertTrue(filters.matches(sample()))
    }

    func testActivityTypeFilter() {
        var filters = ActivityFilters()
        filters.activityTypes = [.cyclingRoad]
        XCTAssertTrue(filters.matches(sample(type: .cyclingRoad)))
        XCTAssertFalse(filters.matches(sample(type: .hiking)))
    }

    func testYearFilter() {
        var filters = ActivityFilters()
        filters.years = [2025]
        XCTAssertTrue(filters.matches(sample(year: 2025)))
        XCTAssertFalse(filters.matches(sample(year: 2024)))
    }

    func testTagsFilterRequiresIntersection() {
        var filters = ActivityFilters()
        filters.tags = ["alpes", "ete"]
        XCTAssertTrue(filters.matches(sample(tags: ["alpes"])))
        XCTAssertTrue(filters.matches(sample(tags: ["ete", "famille"])))
        XCTAssertFalse(filters.matches(sample(tags: ["pyrenees"])))
        XCTAssertFalse(filters.matches(sample(tags: [])))
    }

    func testCombinedFiltersIntersection() {
        var filters = ActivityFilters()
        filters.activityTypes = [.skiingTouring]
        filters.years = [2024]
        XCTAssertTrue(filters.matches(sample(type: .skiingTouring, year: 2024)))
        XCTAssertFalse(filters.matches(sample(type: .skiingTouring, year: 2025)))
        XCTAssertFalse(filters.matches(sample(type: .cyclingRoad, year: 2024)))
    }
}
