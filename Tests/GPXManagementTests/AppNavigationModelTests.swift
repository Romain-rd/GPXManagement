import XCTest
import GPXCore
@testable import GPXManagement

@MainActor
final class AppNavigationModelTests: XCTestCase {
    func testDefaultVisualizationModeIsActivities() {
        let nav = AppNavigationModel()
        XCTAssertEqual(nav.visualizationMode, .activities)
    }

    func testListSelectionStartsEmpty() {
        let nav = AppNavigationModel()
        XCTAssertTrue(nav.listSelection.isEmpty)
    }
}

final class ActivityFiltersToggleTests: XCTestCase {
    func testToggleTypeAddsAndRemoves() {
        var filters = ActivityFilters()
        filters.toggleType(.cyclingRoad)
        XCTAssertEqual(filters.activityTypes, [.cyclingRoad])
        filters.toggleType(.cyclingRoad)
        XCTAssertTrue(filters.activityTypes.isEmpty)
    }

    func testTypeAndYearCombineAsAND() {
        var filters = ActivityFilters()
        filters.toggleType(.hiking)
        filters.toggleYear(2024)
        XCTAssertEqual(filters.activityTypes, [.hiking])
        XCTAssertEqual(filters.years, [2024])

        var c = DateComponents(); c.year = 2024; c.month = 6; c.day = 1
        let date2024 = Calendar.current.date(from: c)!
        c.year = 2025
        let date2025 = Calendar.current.date(from: c)!

        let hiking2024 = summary(type: .hiking, date: date2024)
        let hiking2025 = summary(type: .hiking, date: date2025)
        let cycling2024 = summary(type: .cyclingRoad, date: date2024)

        XCTAssertTrue(filters.matches(hiking2024))
        XCTAssertFalse(filters.matches(hiking2025))  // bonne année manquante
        XCTAssertFalse(filters.matches(cycling2024)) // bon type manquant
    }

    func testResetClearsEverything() {
        var filters = ActivityFilters()
        filters.toggleType(.hiking)
        filters.toggleYear(2024)
        filters.reset()
        XCTAssertTrue(filters.isEmpty)
    }

    private func summary(type: ActivityType, date: Date) -> ActivitySummary {
        ActivitySummary(
            id: UUID(), title: "t", activityType: type, startDate: date, endDate: date,
            distance: 0, duration: 0, movingDuration: 0, elevationGain: 0, elevationLoss: 0,
            avgSpeed: 0, maxSpeed: 0, avgHeartRate: nil, maxHeartRate: nil,
            sourceFileName: "", sourceFileFormat: .gpx, tags: [], notes: nil
        )
    }
}
