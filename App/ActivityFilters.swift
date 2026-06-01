import Foundation
import GPXCore

struct ActivityFilters: Equatable {
    var activityTypes: Set<ActivityType> = []
    var years: Set<Int> = []
    var tags: Set<String> = []
    var sources: Set<ActivitySource> = []
    var raids: Set<UUID> = []

    var isEmpty: Bool {
        activityTypes.isEmpty && years.isEmpty && tags.isEmpty && sources.isEmpty && raids.isEmpty
    }

    /// Intersection (ET) entre facettes ; union (OU) à l'intérieur d'une facette.
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
        if !sources.isEmpty, !sources.contains(summary.source) { return false }
        if !raids.isEmpty {
            guard let raidId = summary.raidId, raids.contains(raidId) else { return false }
        }
        return true
    }

    mutating func toggleType(_ type: ActivityType) {
        if activityTypes.contains(type) { activityTypes.remove(type) } else { activityTypes.insert(type) }
    }

    mutating func toggleYear(_ year: Int) {
        if years.contains(year) { years.remove(year) } else { years.insert(year) }
    }

    mutating func toggleTag(_ tag: String) {
        if tags.contains(tag) { tags.remove(tag) } else { tags.insert(tag) }
    }

    mutating func toggleSource(_ source: ActivitySource) {
        if sources.contains(source) { sources.remove(source) } else { sources.insert(source) }
    }

    mutating func toggleRaid(_ raidId: UUID) {
        if raids.contains(raidId) { raids.remove(raidId) } else { raids.insert(raidId) }
    }

    mutating func reset() {
        self = .init()
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
