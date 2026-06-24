import Foundation
import GPXCore

/// Construction du contenu des événements Calendrier (activités, parcours, raids), sans EventKit.
extension CalendarEvent {

    // MARK: Formatage

    private static func hms(_ seconds: Double) -> String? {
        guard seconds >= 60 else { return nil }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(m) min"
    }

    /// Fin d'un événement journée entière couvrant jusqu'au jour `last` INCLUS : EventKit traite la fin comme
    /// exclusive (l'événement s'arrête au début de `endDate`), il faut donc viser le lendemain de `last`.
    private static func allDayEnd(_ last: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? last
    }

    /// Notes détaillées selon le type : distance/dénivelés, temps (total/mouvement/pause), vitesses, pente, FC.
    /// Les métriques de déplacement sont masquées pour les sports « sur place » (yoga, muscu, raquette…).
    private static func detailNotes(type: ActivityType, stats: ActivityStats, extra: [String] = []) -> String {
        let moves = type.tracksDistanceAndSpeed
        var lines = [type.displayName]

        var dist: [String] = []
        if moves, stats.distance > 0 { dist.append(String(format: "%.1f km", stats.distance / 1000)) }
        if moves, stats.elevationGain > 0 { dist.append("↑ \(Int(stats.elevationGain.rounded())) m") }
        if moves, stats.elevationLoss > 0 { dist.append("↓ \(Int(stats.elevationLoss.rounded())) m") }
        if !dist.isEmpty { lines.append(dist.joined(separator: " · ")) }

        var time: [String] = []
        if let d = hms(stats.duration) { time.append("Durée \(d)") }
        if stats.movingDuration > 0, stats.movingDuration < stats.duration - 30, let mv = hms(stats.movingDuration) { time.append("mouvement \(mv)") }
        if stats.duration - stats.movingDuration > 60, let pause = hms(stats.duration - stats.movingDuration) { time.append("pause \(pause)") }
        if !time.isEmpty { lines.append(time.joined(separator: " · ")) }

        var speed: [String] = []
        if moves, stats.avgSpeed > 0 { speed.append(String(format: "Moy %.1f km/h", stats.avgSpeed * 3.6)) }
        if moves, stats.maxSpeed > 0 { speed.append(String(format: "max %.1f km/h", stats.maxSpeed * 3.6)) }
        if moves, stats.maxSlope > 0 { speed.append(String(format: "pente max %.0f %%", stats.maxSlope)) }
        if !speed.isEmpty { lines.append(speed.joined(separator: " · ")) }

        var hr: [String] = []
        if let a = stats.avgHeartRate, a > 0 { hr.append("FC moy \(Int(a.rounded()))") }
        if let m = stats.maxHeartRate, m > 0 { hr.append("max \(Int(m.rounded()))") }
        if !hr.isEmpty { lines.append(hr.joined(separator: " · ") + " bpm") }

        lines.append(contentsOf: extra)
        return lines.joined(separator: "\n")
    }

    private static func stats(of a: ActivitySummary) -> ActivityStats {
        ActivityStats(distance: a.distance, duration: a.duration, movingDuration: a.movingDuration,
                      elevationGain: a.elevationGain, elevationLoss: a.elevationLoss,
                      avgSpeed: a.avgSpeed, maxSpeed: a.maxSpeed, maxSlope: a.maxSlope,
                      avgHeartRate: a.avgHeartRate, maxHeartRate: a.maxHeartRate, boundingBox: .zero)
    }

    // MARK: Activité

    /// Événement horaire d'une activité réalisée (début → fin réels, repli durée/+1 h si la fin n'est pas après le début).
    static func activity(_ a: ActivitySummary, location: String?, webURL: String?) -> CalendarEvent {
        let end = a.endDate > a.startDate ? a.endDate : a.startDate.addingTimeInterval(max(a.duration, 3600))
        return CalendarEvent(identityKey: "gpx:activity/\(a.id.uuidString)",
                             title: "\(a.activityType.emoji) \(a.title)",
                             startDate: a.startDate, endDate: end, isAllDay: false,
                             location: location, notes: detailNotes(type: a.activityType, stats: stats(of: a)),
                             url: webURL.flatMap { URL(string: $0) })
    }

    // MARK: Parcours

    /// Parcours en étapes : 1 événement journée entière par étape datée (« Jn · départ → arrivée ») + 1 chapeau J1→Jn.
    /// Les étapes sans date planifiée sont ignorées ; renvoie [] si aucune étape n'est datée. L'URL de la page web
    /// publiée est portée par chaque événement (étapes + chapeau).
    static func route(_ activity: ActivitySummary, repository: CoreDataActivityRepository) async -> [CalendarEvent] {
        guard let data = try? await repository.fetchTrackData(id: activity.id),
              let points = try? TrackPointCodec.decode(data), points.count >= 2,
              let resolved = try? await repository.fetchStagesResolved(activityId: activity.id, points: points),
              !resolved.isEmpty else { return [] }
        let stages = resolved.sorted { $0.order < $1.order }
        let waypoints = RouteWaypointCodec.decode((try? await repository.fetchRouteWaypointsData(id: activity.id)) ?? nil)
        let routeStart = (waypoints.first?.name ?? "").trimmingCharacters(in: .whitespaces)
        let webURL = (try? await repository.fetchWebPublishedURL(id: activity.id)) ?? nil
        let url = (webURL?.isEmpty == false) ? webURL : nil

        var stageEvents: [CalendarEvent] = []
        var dates: [Date] = []
        for (i, s) in stages.enumerated() {
            guard let date = s.plannedDate else { continue }
            let arrival = s.name.trimmingCharacters(in: .whitespaces)
            let departure = (i > 0 ? stages[i - 1].name : routeStart).trimmingCharacters(in: .whitespaces)
            let route = (!departure.isEmpty && !arrival.isEmpty) ? "\(departure) → \(arrival)"
                      : (arrival.isEmpty ? "Étape \(i + 1)" : arrival)
            var extra: [String] = []
            if let n = s.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { extra.append(n) }
            stageEvents.append(CalendarEvent(identityKey: "gpx:stage/\(s.id.uuidString)",
                                             title: "J\(i + 1) · \(route)",
                                             startDate: date, endDate: date, isAllDay: true,
                                             location: arrival.isEmpty ? nil : arrival,
                                             notes: detailNotes(type: activity.activityType, stats: s.stats(in: points), extra: extra),
                                             url: url.flatMap { URL(string: $0) }))
            dates.append(date)
        }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let extra = ["\(stageEvents.count) étape\(stageEvents.count > 1 ? "s" : "")"]
        let chapeau = CalendarEvent(identityKey: routeChapeauKey(activity.id),
                                    title: "\(activity.activityType.emoji) \(activity.title)",
                                    startDate: first, endDate: allDayEnd(last), isAllDay: true, location: nil,
                                    notes: detailNotes(type: activity.activityType, stats: ActivityStatsCalculator.compute(points: points), extra: extra),
                                    url: url.flatMap { URL(string: $0) })
        return stageEvents + [chapeau]
    }

    /// Identité du chapeau d'un parcours (état du bouton « Ajouter / Retirer »).
    static func routeChapeauKey(_ activityId: UUID) -> String { "gpx:route/\(activityId.uuidString)" }

    // MARK: Raid

    /// Raid : 1 événement horaire par activité membre + 1 chapeau journée entière couvrant le raid.
    static func raid(_ raid: Raid, members: [ActivitySummary], repository: CoreDataActivityRepository) async -> [CalendarEvent] {
        guard !members.isEmpty else { return [] }
        var events: [CalendarEvent] = []
        for m in members {
            let webURL = (try? await repository.fetchWebPublishedURL(id: m.id)) ?? nil
            let end = m.endDate > m.startDate ? m.endDate : m.startDate.addingTimeInterval(max(m.duration, 3600))
            events.append(CalendarEvent(identityKey: "gpx:raid/\(raid.id.uuidString)/member/\(m.id.uuidString)",
                                        title: "\(m.activityType.emoji) \(m.title)",
                                        startDate: m.startDate, endDate: end, isAllDay: false, location: nil,
                                        notes: detailNotes(type: m.activityType, stats: stats(of: m)),
                                        url: webURL.flatMap { URL(string: $0) }))
        }
        let start = raid.startDate ?? members.map(\.startDate).min() ?? members[0].startDate
        let last = raid.endDate ?? members.map(\.endDate).max() ?? members[0].endDate
        let raidURL = (try? await repository.fetchRaidWebPublishedURL(id: raid.id)) ?? nil
        events.append(CalendarEvent(identityKey: raidChapeauKey(raid.id),
                                    title: "🏕️ \(raid.name)",
                                    startDate: start, endDate: allDayEnd(last), isAllDay: true, location: raid.place,
                                    notes: "\(members.count) activité\(members.count > 1 ? "s" : "")",
                                    url: raidURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }))
        return events
    }

    /// Identité du chapeau d'un raid (état du bouton « Ajouter / Retirer »).
    static func raidChapeauKey(_ raidId: UUID) -> String { "gpx:raid/\(raidId.uuidString)" }
}
