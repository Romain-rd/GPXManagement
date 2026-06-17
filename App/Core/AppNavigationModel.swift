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
    case allRaids
    case activityType(ActivityType)
    case courseType(ActivityType)
    case raidType(ActivityType)
    case year(Int)
    case yearType(Int, ActivityType)
    case smartFilter(UUID)
}

@MainActor
@Observable
final class AppNavigationModel {
    var listSelection: Set<UUID> = []
    var visualizationMode: VisualizationMode = .activities
    var newRaidToken: Int = 0
    var newStagedRouteToken: Int = 0
    var sidebarSelection: SidebarDestination = .allActivities
    var editingSmartFilter: SmartFilter?
    /// Étape dont la fiche est affichée dans le volet de droite (mode parcours).
    var selectedStageId: UUID?
    /// Visibilité de l'inspecteur d'étape (colonne de droite escamotable, pilotée par le bouton de la barre de titre).
    var showStageInspector: Bool = true
    /// Parcours à sélectionner une fois le flux « Tous les parcours » activé (l'onChange de sidebarSelection vide listSelection).
    var pendingCourseSelection: UUID?
    /// Raid sélectionné dans la liste centrale (« Tous les raids ») — son détail s'affiche dans la 3ᵉ colonne.
    var selectedRaidInListId: UUID?
    /// Raid à sélectionner une fois le flux « Tous les raids » activé (même logique que pendingCourseSelection).
    var pendingRaidSelection: UUID?

    /// Sélectionne un raid dans la liste (détail en 3ᵉ colonne) ; déselectionne activité/étape.
    func selectRaid(_ id: UUID) {
        listSelection = []
        selectedStageId = nil
        selectedRaidInListId = id
    }

    /// Ouvre un parcours comme une activité : flux « Tous les parcours » + sélection (détail dans la 3ᵉ colonne).
    func openCourse(_ id: UUID) {
        selectedStageId = nil
        if sidebarSelection == .allCourses {
            listSelection = [id]
        } else {
            pendingCourseSelection = id
            sidebarSelection = .allCourses
        }
    }

    /// Ouvre un raid : flux « Tous les raids » + sélection (détail dans la 3ᵉ colonne).
    func openRaid(_ id: UUID) {
        if sidebarSelection == .allRaids {
            selectRaid(id)
        } else {
            pendingRaidSelection = id
            sidebarSelection = .allRaids
        }
    }

    var selectedSmartFilterId: UUID? {
        if case .smartFilter(let id) = sidebarSelection { return id }
        return nil
    }

    var selectedActivityType: ActivityType? {
        switch sidebarSelection {
        case .activityType(let type):  return type
        case .yearType(_, let type):   return type
        case .courseType(let type):    return type
        case .raidType(let type):      return type
        default:                       return nil
        }
    }

    /// Vrai quand le flux courant porte sur les parcours (« Tous les parcours » ou un type de parcours).
    var isCoursesScope: Bool {
        switch sidebarSelection {
        case .allCourses, .courseType:  return true
        default:                        return false
        }
    }

    /// Vrai quand le flux courant porte sur les raids (« Tous les raids » ou un type de raid).
    var isRaidsScope: Bool {
        switch sidebarSelection {
        case .allRaids, .raidType:  return true
        default:                    return false
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
