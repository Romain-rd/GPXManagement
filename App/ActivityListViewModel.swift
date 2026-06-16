import Foundation
import GPXCore

enum LibraryScope {
    case activities  // traces réellement effectuées
    case courses     // parcours de préparation
}

@MainActor
@Observable
final class ActivityListViewModel {
    var allActivities: [ActivitySummary] = []
    var scope: LibraryScope = .activities
    var raids: [Raid] = []
    var smartFilters: [SmartFilter] = []
    var activeSmartFilter: SmartFilter?
    var activeType: ActivityType?
    var activeYear: Int?
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

    /// Traces réellement effectuées (alimente Années / Types / Raids / Filtres et les stats).
    var realActivities: [ActivitySummary] { allActivities.filter { !$0.isCourse } }
    /// Parcours de préparation (flux « Tous les parcours »).
    var courseActivities: [ActivitySummary] { allActivities.filter { $0.isCourse } }

    /// Ensemble visible selon le flux courant.
    private var scopedActivities: [ActivitySummary] {
        scope == .courses ? courseActivities : realActivities
    }

    var activitiesCount: Int { realActivities.count }
    var coursesCount: Int { courseActivities.count }

    var visibleActivities: [ActivitySummary] {
        let filtered = scopedActivities.filter { activity in
            if let type = activeType, activity.activityType != type { return false }
            if let year = activeYear, Calendar.current.component(.year, from: activity.startDate) != year { return false }
            if let smart = activeSmartFilter, !smart.matches(activity) { return false }
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
        let grouped = Dictionary(grouping: realActivities) { cal.component(.year, from: $0.startDate) }
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.year > $1.year }
    }

    var availableActivityTypes: [(type: ActivityType, count: Int)] {
        activityTypes(in: realActivities)
    }

    func availableActivityTypes(year: Int) -> [(type: ActivityType, count: Int)] {
        let cal = Calendar.current
        return activityTypes(in: realActivities.filter { cal.component(.year, from: $0.startDate) == year })
    }

    private func activityTypes(in activities: [ActivitySummary]) -> [(type: ActivityType, count: Int)] {
        let grouped = Dictionary(grouping: activities, by: \.activityType)
        return ActivityType.allCases
            .compactMap { type -> (ActivityType, Int)? in
                guard let count = grouped[type]?.count else { return nil }
                return (type, count)
            }
    }

    var availableTags: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for activity in realActivities {
            for tag in activity.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.tag < $1.tag }
    }

    var availableSources: [(source: ActivitySource, count: Int)] {
        var counts: [ActivitySource: Int] = [:]
        for activity in realActivities { counts[activity.source, default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.source.sortKey < $1.source.sortKey }
    }

    var availableRaids: [(raid: Raid, count: Int)] {
        var counts: [UUID: Int] = [:]
        for activity in realActivities {
            if let raidId = activity.raidId { counts[raidId, default: 0] += 1 }
        }
        return raids
            .map { ($0, counts[$0.id] ?? 0) }
            .sorted { ($0.0.startDate ?? .distantPast) > ($1.0.startDate ?? .distantPast) }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            allActivities = try await repository.fetchAllSummaries()
            raids = try await repository.fetchRaids()
            smartFilters = try await repository.fetchSmartFilters()
        } catch {
            self.error = "Échec du chargement : \(error.localizedDescription)"
        }
    }

    var availableStagedRoutes: [ActivitySummary] {
        allActivities.filter { $0.isStagedRoute }.sorted { $0.startDate > $1.startDate }
    }

    /// Passe une trace en « parcours en étapes » (crée une étape initiale couvrant tout si aucune n'existe).
    @discardableResult
    func createStagedRoute(from activityId: UUID) async -> UUID? {
        do {
            let data = try await repository.fetchTrackData(id: activityId)
            let count = data.flatMap { try? TrackPointCodec.decode($0).count } ?? 0
            guard count > 1 else { self.error = "Trace sans points exploitables."; return nil }
            try await repository.setStagedRoute(activityId: activityId, true)
            let existing = try await repository.fetchStages(activityId: activityId)
            if existing.isEmpty {
                let stage = Stage(activityId: activityId, order: 0, name: "Étape 1", startIndex: 0, endIndex: count - 1)
                try await repository.replaceStages(activityId: activityId, with: [stage])
            }
            await reload()
            return activityId
        } catch {
            self.error = "Échec de la création du parcours : \(error.localizedDescription)"
            return nil
        }
    }

    func deleteStagedRoute(_ activityId: UUID) async {
        do {
            try await repository.setStagedRoute(activityId: activityId, false)
            try await repository.deleteStages(activityId: activityId)
            await reload()
        } catch {
            self.error = "Échec de la suppression du parcours : \(error.localizedDescription)"
        }
    }

    func suggestedRaidName(for ids: Set<UUID>) -> String {
        let dates = allActivities.filter { ids.contains($0.id) }.map(\.startDate)
        guard let earliest = dates.min() else { return "Nouveau raid" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "LLLL yyyy"
        return "Raid " + f.string(from: earliest)
    }

    @discardableResult
    func createRaid(name: String, activityIds: Set<UUID>) async -> UUID? {
        let raid = Raid(name: name)
        do {
            try await repository.createRaid(raid)
            try await repository.setRaid(activityIds: Array(activityIds), raidId: raid.id)
            await reload()
            await refreshRaidDates(raid.id)
            return raid.id
        } catch {
            self.error = "Échec de la création du raid : \(error.localizedDescription)"
            return nil
        }
    }

    func addToRaid(_ raidId: UUID, activityIds: Set<UUID>) async {
        do {
            try await repository.setRaid(activityIds: Array(activityIds), raidId: raidId)
            await reload()
            await refreshRaidDates(raidId)
        } catch {
            self.error = "Échec de l'ajout au raid : \(error.localizedDescription)"
        }
    }

    func removeFromRaid(activityIds: Set<UUID>) async {
        let affected = Set(allActivities.filter { activityIds.contains($0.id) }.compactMap(\.raidId))
        do {
            try await repository.setRaid(activityIds: Array(activityIds), raidId: nil)
            await reload()
            for raidId in affected { await refreshRaidDates(raidId) }
        } catch {
            self.error = "Échec du retrait du raid : \(error.localizedDescription)"
        }
    }

    func count(for filter: SmartFilter) -> Int {
        realActivities.filter { filter.matches($0) }.count
    }

    func saveSmartFilter(_ filter: SmartFilter) async {
        var updated = filter
        updated.updatedAt = Date()
        do {
            if smartFilters.contains(where: { $0.id == updated.id }) {
                try await repository.updateSmartFilter(updated)
                if let idx = smartFilters.firstIndex(where: { $0.id == updated.id }) { smartFilters[idx] = updated }
            } else {
                try await repository.createSmartFilter(updated)
                smartFilters.append(updated)
            }
            if activeSmartFilter?.id == updated.id { activeSmartFilter = updated }
        } catch {
            self.error = "Échec de l'enregistrement du filtre : \(error.localizedDescription)"
        }
    }

    func deleteSmartFilter(_ id: UUID) async {
        do {
            try await repository.deleteSmartFilter(id: id)
            smartFilters.removeAll { $0.id == id }
        } catch {
            self.error = "Échec de la suppression du filtre : \(error.localizedDescription)"
        }
    }

    func saveRaid(_ raid: Raid) async {
        var updated = raid
        updated.updatedAt = Date()
        do {
            try await repository.updateRaid(updated)
            if let idx = raids.firstIndex(where: { $0.id == updated.id }) { raids[idx] = updated }
        } catch {
            self.error = "Échec de l'enregistrement du raid : \(error.localizedDescription)"
        }
    }

    func renameRaid(_ raidId: UUID, name: String) async {
        guard var raid = raids.first(where: { $0.id == raidId }) else { return }
        raid.name = name
        raid.updatedAt = Date()
        do {
            try await repository.updateRaid(raid)
            if let idx = raids.firstIndex(where: { $0.id == raidId }) { raids[idx] = raid }
        } catch {
            self.error = "Échec du renommage du raid : \(error.localizedDescription)"
        }
    }

    func deleteRaid(_ raidId: UUID) async {
        do {
            try await repository.deleteRaid(id: raidId)
            await reload()
        } catch {
            self.error = "Échec de la suppression du raid : \(error.localizedDescription)"
        }
    }

    private func refreshRaidDates(_ raidId: UUID) async {
        guard var raid = raids.first(where: { $0.id == raidId }) else { return }
        let members = allActivities.filter { $0.raidId == raidId }
        raid.startDate = members.map(\.startDate).min()
        raid.endDate = members.map(\.endDate).max()
        raid.updatedAt = Date()
        do {
            try await repository.updateRaid(raid)
            if let idx = raids.firstIndex(where: { $0.id == raidId }) { raids[idx] = raid }
        } catch {
            // dates non critiques : ignorer l'échec
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

    func updateType(ids: Set<UUID>, type: ActivityType) async {
        for id in ids {
            await updateType(id: id, type: type)
        }
    }

    func setIsCourse(id: UUID, isCourse: Bool) async {
        do {
            try await repository.setIsCourse(id: id, isCourse: isCourse)
            if let idx = allActivities.firstIndex(where: { $0.id == id }) {
                allActivities[idx] = allActivities[idx].updatingIsCourse(isCourse)
            }
        } catch {
            self.error = "Échec du changement de catégorie : \(error.localizedDescription)"
        }
    }

    func setIsCourse(ids: Set<UUID>, isCourse: Bool) async {
        for id in ids { await setIsCourse(id: id, isCourse: isCourse) }
    }

    /// Reclassement unique des traces existantes depuis leur tracé (joué une seule fois).
    func classifyCoursesIfNeeded() async {
        let key = "didReconcileCoursesV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            let count = try await repository.reconcileCoursesFromTracks()
            UserDefaults.standard.set(true, forKey: key)
            if count > 0 { await reload() }
        } catch {
            self.error = "Échec du reclassement des parcours : \(error.localizedDescription)"
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
