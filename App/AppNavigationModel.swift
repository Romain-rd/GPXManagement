import Foundation
import GPXCore

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

enum SidebarDestination: Hashable {
    case allActivities
    case allCourses
    case activityType(ActivityType)
    case year(Int)
    case yearType(Int, ActivityType)
    case raid(UUID)
    case smartFilter(UUID)
}

@MainActor
@Observable
final class AppNavigationModel {
    var listSelection: Set<UUID> = []
    var visualizationMode: VisualizationMode = .activities
    var newRaidToken: Int = 0
    var sidebarSelection: SidebarDestination = .allActivities
    var editingSmartFilter: SmartFilter?

    var selectedRaidId: UUID? {
        if case .raid(let id) = sidebarSelection { return id }
        return nil
    }

    var selectedSmartFilterId: UUID? {
        if case .smartFilter(let id) = sidebarSelection { return id }
        return nil
    }

    var selectedActivityType: ActivityType? {
        switch sidebarSelection {
        case .activityType(let type):  return type
        case .yearType(_, let type):   return type
        default:                       return nil
        }
    }

    var selectedYear: Int? {
        switch sidebarSelection {
        case .year(let year):          return year
        case .yearType(let year, _):   return year
        default:                       return nil
        }
    }
}
