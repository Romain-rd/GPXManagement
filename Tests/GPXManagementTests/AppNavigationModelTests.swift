import XCTest
import GPXCore
@testable import GPXManagement

@MainActor
final class AppNavigationModelTests: XCTestCase {
    func testActivityTypeSidebarFiltersList() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        nav.applySidebar(.activityType(.cyclingRoad), to: &filters)
        XCTAssertEqual(filters.activityTypes, [.cyclingRoad])
        XCTAssertEqual(nav.mode, .threeColumn)
    }

    func testYearSidebarFiltersList() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        nav.applySidebar(.year(2024), to: &filters)
        XCTAssertEqual(filters.years, [2024])
    }

    func testAllActivitiesResetsFilters() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        filters.activityTypes = [.hiking]
        nav.applySidebar(.allActivities, to: &filters)
        XCTAssertTrue(filters.isEmpty)
    }

    func testMapOverviewChangesMode() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        nav.applySidebar(.mapOverview, to: &filters)
        XCTAssertEqual(nav.mode, .mapOverview)
    }
}
