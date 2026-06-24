import Foundation
import GPXCore

/// Construction des événements Calendrier pour les parcours et les raids (le contenu pur, sans EventKit).
extension CalendarEvent {

    /// Fin d'un événement journée entière couvrant jusqu'au jour `last` INCLUS : EventKit traite la fin comme
    /// exclusive (l'événement s'arrête au début de `endDate`), il faut donc viser le lendemain de `last`.
    private static func allDayEnd(_ last: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? last
    }

    private static func metric(_ distance: Double, _ gain: Double) -> [String] {
        var parts: [String] = []
        if distance > 0 { parts.append(String(format: "%.1f km", distance / 1000)) }
        if gain > 0 { parts.append("+\(Int(gain.rounded())) m de D+") }
        return parts
    }

    /// Parcours en étapes : 1 événement journée entière par étape datée (« Jn · départ → arrivée ») + 1 chapeau J1→Jn.
    /// Les étapes sans date planifiée sont ignorées ; renvoie [] si aucune étape n'est datée.
    static func route(_ activity: ActivitySummary, repository: CoreDataActivityRepository) async -> [CalendarEvent] {
        guard let data = try? await repository.fetchTrackData(id: activity.id),
              let points = try? TrackPointCodec.decode(data), points.count >= 2,
              let resolved = try? await repository.fetchStagesResolved(activityId: activity.id, points: points),
              !resolved.isEmpty else { return [] }
        let stages = resolved.sorted { $0.order < $1.order }
        let waypoints = RouteWaypointCodec.decode((try? await repository.fetchRouteWaypointsData(id: activity.id)) ?? nil)
        let routeStart = (waypoints.first?.name ?? "").trimmingCharacters(in: .whitespaces)

        var stageEvents: [CalendarEvent] = []
        var dates: [Date] = []
        for (i, s) in stages.enumerated() {
            guard let date = s.plannedDate else { continue }
            let arrival = s.name.trimmingCharacters(in: .whitespaces)
            let departure = (i > 0 ? stages[i - 1].name : routeStart).trimmingCharacters(in: .whitespaces)
            let route = (!departure.isEmpty && !arrival.isEmpty) ? "\(departure) → \(arrival)"
                      : (arrival.isEmpty ? "Étape \(i + 1)" : arrival)
            let st = s.stats(in: points)
            var notes = metric(st.distance, st.elevationGain).joined(separator: " · ")
            if let n = s.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                notes += notes.isEmpty ? n : "\n\n\(n)"
            }
            stageEvents.append(CalendarEvent(identityKey: "gpx:stage/\(s.id.uuidString)",
                                             title: "J\(i + 1) · \(route)",
                                             startDate: date, endDate: date, isAllDay: true,
                                             location: arrival.isEmpty ? nil : arrival,
                                             notes: notes.isEmpty ? nil : notes, url: nil))
            dates.append(date)
        }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let webURL = (try? await repository.fetchWebPublishedURL(id: activity.id)) ?? nil
        var notes = "\(stageEvents.count) étape\(stageEvents.count > 1 ? "s" : "")"
        if let webURL, !webURL.isEmpty { notes += "\n\n\(webURL)" }
        let chapeau = CalendarEvent(identityKey: "gpx:route/\(activity.id.uuidString)",
                                    title: "\(activity.activityType.emoji) \(activity.title)",
                                    startDate: first, endDate: allDayEnd(last), isAllDay: true, location: nil,
                                    notes: notes, url: webURL.flatMap { URL(string: $0) })
        return stageEvents + [chapeau]
    }

    /// Identité du chapeau d'un parcours (état du bouton « Ajouter / Retirer »).
    static func routeChapeauKey(_ activityId: UUID) -> String { "gpx:route/\(activityId.uuidString)" }

    /// Raid : 1 événement horaire par activité membre + 1 chapeau journée entière couvrant le raid.
    static func raid(_ raid: Raid, members: [ActivitySummary], repository: CoreDataActivityRepository) async -> [CalendarEvent] {
        guard !members.isEmpty else { return [] }
        var events: [CalendarEvent] = []
        for m in members {
            let webURL = (try? await repository.fetchWebPublishedURL(id: m.id)) ?? nil
            let end = m.endDate > m.startDate ? m.endDate : m.startDate.addingTimeInterval(max(m.duration, 3600))
            var notes = [m.activityType.displayName]
            notes += metric(m.distance, m.elevationGain)
            events.append(CalendarEvent(identityKey: "gpx:raid/\(raid.id.uuidString)/member/\(m.id.uuidString)",
                                        title: "\(m.activityType.emoji) \(m.title)",
                                        startDate: m.startDate, endDate: end, isAllDay: false, location: nil,
                                        notes: notes.joined(separator: " · "),
                                        url: webURL.flatMap { URL(string: $0) }))
        }
        let start = raid.startDate ?? members.map(\.startDate).min() ?? members[0].startDate
        let last = raid.endDate ?? members.map(\.endDate).max() ?? members[0].endDate
        events.append(CalendarEvent(identityKey: raidChapeauKey(raid.id),
                                    title: "🏕️ \(raid.name)",
                                    startDate: start, endDate: allDayEnd(last), isAllDay: true, location: raid.place,
                                    notes: "\(members.count) activité\(members.count > 1 ? "s" : "")", url: nil))
        return events
    }

    /// Identité du chapeau d'un raid (état du bouton « Ajouter / Retirer »).
    static func raidChapeauKey(_ raidId: UUID) -> String { "gpx:raid/\(raidId.uuidString)" }
}
