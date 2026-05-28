import Foundation
import GPXCore

enum SidebarItem: Hashable, Sendable {
    case allActivities
    case activityType(ActivityType)
    case year(Int)
    case tag(String)
}

enum VisualizationMode: String, CaseIterable, Identifiable, Sendable {
    case activities
    case statistics
    case mapOverview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activities:  return "Activités"
        case .statistics:  return "Statistiques"
        case .mapOverview: return "Vue d'ensemble"
        }
    }

    var systemImage: String {
        switch self {
        case .activities:  return "list.bullet"
        case .statistics:  return "chart.bar.xaxis"
        case .mapOverview: return "map"
        }
    }
}

@MainActor
@Observable
final class AppNavigationModel {
    var sidebarSelection: SidebarItem? = .allActivities
    var listSelection: Set<UUID> = []
    var visualizationMode: VisualizationMode = .activities

    func applySidebar(_ item: SidebarItem, to filters: inout ActivityFilters) {
        switch item {
        case .allActivities:
            filters = .init()
        case .activityType(let type):
            filters = ActivityFilters(activityTypes: [type])
        case .year(let y):
            filters = ActivityFilters(years: [y])
        case .tag(let t):
            filters = ActivityFilters(tags: [t])
        }
    }
}
