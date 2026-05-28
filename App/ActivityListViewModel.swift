import Foundation
import GPXCore

@MainActor
@Observable
final class ActivityListViewModel {
    var allActivities: [ActivitySummary] = []
    var filters: ActivityFilters = .init()
    var sortOrder: ActivitySortOrder = .dateDescending
    var searchText: String = ""
    var isLoading: Bool = false
    var error: String?
    var renamingIds: Set<UUID> = []

    private let repository: CoreDataActivityRepository

    init(repository: CoreDataActivityRepository) {
        self.repository = repository
    }

    var visibleActivities: [ActivitySummary] {
        let filtered = allActivities.filter { activity in
            if !filters.matches(activity) { return false }
            if !searchText.isEmpty {
                let needle = Self.foldedLowercased(searchText)
                let inTitle = Self.foldedLowercased(activity.title).contains(needle)
                let inNotes = Self.foldedLowercased(activity.notes ?? "").contains(needle)
                let inTags = activity.tags.contains { Self.foldedLowercased($0).contains(needle) }
                if !(inTitle || inNotes || inTags) { return false }
            }
            return true
        }
        return sorted(filtered, by: sortOrder)
    }

    private static func foldedLowercased(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    var availableYears: [(year: Int, count: Int)] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allActivities) { cal.component(.year, from: $0.startDate) }
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.year > $1.year }
    }

    var availableActivityTypes: [(type: ActivityType, count: Int)] {
        let grouped = Dictionary(grouping: allActivities, by: \.activityType)
        return ActivityType.allCases
            .compactMap { type -> (ActivityType, Int)? in
                guard let count = grouped[type]?.count else { return nil }
                return (type, count)
            }
    }

    var availableTags: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for activity in allActivities {
            for tag in activity.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.tag < $1.tag }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            allActivities = try await repository.fetchAllSummaries()
        } catch {
            self.error = "Échec du chargement : \(error.localizedDescription)"
        }
    }

    func delete(id: UUID) async {
        do {
            try await repository.deleteActivity(id: id)
            allActivities.removeAll { $0.id == id }
        } catch {
            self.error = "Échec de la suppression : \(error.localizedDescription)"
        }
    }

    func updateNotes(id: UUID, notes: String) async {
        do {
            try await repository.updateNotes(id: id, notes: notes)
            if let idx = allActivities.firstIndex(where: { $0.id == id }) {
                allActivities[idx] = allActivities[idx].updatingNotes(notes)
            }
        } catch {
            self.error = "Échec de la mise à jour : \(error.localizedDescription)"
        }
    }

    func updateTitle(id: UUID, title: String) async {
        do {
            try await repository.updateTitle(id: id, title: title)
            if let idx = allActivities.firstIndex(where: { $0.id == id }) {
                allActivities[idx] = allActivities[idx].updatingTitle(title)
            }
        } catch {
            self.error = "Échec du renommage : \(error.localizedDescription)"
        }
    }

    func updateType(id: UUID, type: ActivityType) async {
        do {
            try await repository.updateActivityType(id: id, rawValue: type.rawValue)
            if let idx = allActivities.firstIndex(where: { $0.id == id }) {
                allActivities[idx] = allActivities[idx].updatingActivityType(type)
            }
        } catch {
            self.error = "Échec du changement de type : \(error.localizedDescription)"
        }
    }

    func autoRename(id: UUID) async {
        renamingIds.insert(id)
        defer { renamingIds.remove(id) }
        guard let data = try? await repository.fetchTrackData(id: id), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data),
              let name = await RouteNamer.suggestName(points: points) else {
            error = "Impossible de déterminer un nom depuis le parcours (pas de réseau ou pas de GPS ?)."
            return
        }
        await updateTitle(id: id, title: name)
    }


    private func sorted(_ items: [ActivitySummary], by order: ActivitySortOrder) -> [ActivitySummary] {
        switch order {
        case .dateDescending: return items.sorted { $0.startDate > $1.startDate }
        case .dateAscending:  return items.sorted { $0.startDate < $1.startDate }
        case .distance:       return items.sorted { $0.distance > $1.distance }
        case .duration:       return items.sorted { $0.duration > $1.duration }
        case .elevationGain:  return items.sorted { $0.elevationGain > $1.elevationGain }
        }
    }
}
