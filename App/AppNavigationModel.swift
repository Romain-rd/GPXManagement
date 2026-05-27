import Foundation
import GPXCore

enum SidebarItem: Hashable, Sendable {
    case allActivities
    case activityType(ActivityType)
    case year(Int)
    case tag(String)
    case mapOverview
    case statistics
    case strava
}

enum NavigationMode: Hashable {
    case threeColumn
    case mapOverview
    case statistics
    case strava
}

@MainActor
@Observable
final class AppNavigationModel {
    var sidebarSelection: SidebarItem? = .allActivities
    var listSelection: Set<UUID> = []
    var mode: NavigationMode = .threeColumn
    var showPreferences: Bool = false

    func applySidebar(_ item: SidebarItem, to filters: inout ActivityFilters) {
        switch item {
        case .allActivities:
            filters = .init()
            mode = .threeColumn
        case .activityType(let type):
            filters = ActivityFilters(activityTypes: [type])
            mode = .threeColumn
        case .year(let y):
            filters = ActivityFilters(years: [y])
            mode = .threeColumn
        case .tag(let t):
            filters = ActivityFilters(tags: [t])
            mode = .threeColumn
        case .mapOverview:
            mode = .mapOverview
        case .statistics:
            mode = .statistics
        case .strava:
            mode = .strava
        }
    }
}
