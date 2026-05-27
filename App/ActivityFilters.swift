import Foundation
import GPXCore

struct ActivityFilters: Equatable {
    var activityTypes: Set<ActivityType> = []
    var years: Set<Int> = []
    var tags: Set<String> = []

    var isEmpty: Bool {
        activityTypes.isEmpty && years.isEmpty && tags.isEmpty
    }

    func matches(_ summary: ActivitySummary) -> Bool {
        if !activityTypes.isEmpty, !activityTypes.contains(summary.activityType) { return false }
        if !years.isEmpty {
            let year = Calendar.current.component(.year, from: summary.startDate)
            if !years.contains(year) { return false }
        }
        if !tags.isEmpty {
            let summaryTags = Set(summary.tags)
            if summaryTags.intersection(tags).isEmpty { return false }
        }
        return true
    }
}

enum ActivitySortOrder: String, CaseIterable, Sendable, Identifiable {
    case dateDescending
    case dateAscending
    case distance
    case duration
    case elevationGain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateDescending: return "Date (récent → ancien)"
        case .dateAscending:  return "Date (ancien → récent)"
        case .distance:       return "Distance"
        case .duration:       return "Durée"
        case .elevationGain:  return "Dénivelé +"
        }
    }
}
