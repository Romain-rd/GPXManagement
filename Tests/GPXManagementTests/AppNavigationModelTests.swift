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
    }

    func testYearSidebarFiltersList() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        nav.applySidebar(.year(2024), to: &filters)
        XCTAssertEqual(filters.years, [2024])
    }

    func testTagSidebarFiltersList() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        nav.applySidebar(.tag("alpes"), to: &filters)
        XCTAssertEqual(filters.tags, ["alpes"])
    }

    func testAllActivitiesResetsFilters() {
        let nav = AppNavigationModel()
        var filters = ActivityFilters()
        filters.activityTypes = [.hiking]
        nav.applySidebar(.allActivities, to: &filters)
        XCTAssertTrue(filters.isEmpty)
    }

    func testDefaultVisualizationModeIsActivities() {
        let nav = AppNavigationModel()
        XCTAssertEqual(nav.visualizationMode, .activities)
    }

    func testVisualizationModeIndependentOfSidebar() {
        let nav = AppNavigationModel()
        nav.visualizationMode = .mapOverview
        var filters = ActivityFilters()
        nav.applySidebar(.activityType(.hiking), to: &filters)
        // changer le filtre ne doit pas changer le mode de visualisation
        XCTAssertEqual(nav.visualizationMode, .mapOverview)
    }
}
