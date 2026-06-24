import EventKit
import GPXCore

/// Contenu d'un événement Calendrier, indépendant de l'UI et du stockage EventKit.
/// `identityKey` (ex. « gpx:activity/<uuid> ») sert à dédoublonner : un réexport met à jour l'événement existant.
struct CalendarEvent {
    let identityKey: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
}

extension CalendarEvent {
    /// Événement horaire d'une activité réalisée (début → fin réels, repli durée/+1 h si la fin n'est pas après le début).
    static func activity(_ a: ActivitySummary, location: String?, webURL: String?) -> CalendarEvent {
        var parts = [a.activityType.displayName]
        if a.distance > 0 { parts.append(String(format: "%.1f km", a.distance / 1000)) }
        if a.elevationGain > 0 { parts.append("+\(Int(a.elevationGain.rounded())) m de D+") }
        let end = a.endDate > a.startDate ? a.endDate : a.startDate.addingTimeInterval(max(a.duration, 3600))
        return CalendarEvent(identityKey: "gpx:activity/\(a.id.uuidString)",
                             title: "\(a.activityType.emoji) \(a.title)",
                             startDate: a.startDate, endDate: end, isAllDay: false,
                             location: location, notes: parts.joined(separator: " · "),
                             url: webURL.flatMap { URL(string: $0) })
    }
}

/// Pont vers Calendrier.app via EventKit : autorisation, calendrier dédié « GPXManagement », et écriture idempotente.
@MainActor
final class CalendarExportService {
    static let shared = CalendarExportService()
    private let store = EKEventStore()
    private init() {}

    enum CalendarError: LocalizedError {
        case accessDenied, noSource, underlying(String)
        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Accès au Calendrier refusé. Autorisez-le dans Réglages Système › Confidentialité et sécurité › Calendriers."
            case .noSource:     return "Aucun calendrier inscriptible n'est disponible sur ce Mac."
            case .underlying(let m): return m
            }
        }
    }

    private let calendarIdKey = "calendarDedicatedCalendarId"
    private let eventIdsKey = "calendarEventIds"

    // MARK: Autorisation

    func requestAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { throw CalendarError.accessDenied }
    }

    // MARK: Calendrier dédié

    /// Le calendrier « GPXManagement » : réutilisé s'il existe (même via iCloud), sinon créé dans la source iCloud (synchro)
    /// ou, à défaut, locale.
    private func dedicatedCalendar() throws -> EKCalendar {
        if let id = UserDefaults.standard.string(forKey: calendarIdKey),
           let cal = store.calendar(withIdentifier: id) { return cal }
        if let existing = store.calendars(for: .event).first(where: { $0.title == "GPXManagement" && $0.allowsContentModifications }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: calendarIdKey)
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = "GPXManagement"
        cal.cgColor = CGColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)
        let source = store.sources.first { $0.sourceType == .calDAV && $0.title.caseInsensitiveCompare("iCloud") == .orderedSame }
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.sources.first
        guard let source else { throw CalendarError.noSource }
        cal.source = source
        do { try store.saveCalendar(cal, commit: true) } catch { throw CalendarError.underlying(error.localizedDescription) }
        UserDefaults.standard.set(cal.calendarIdentifier, forKey: calendarIdKey)
        return cal
    }

    // MARK: Correspondance identité → événement (idempotence)

    private func storedEventId(_ key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: eventIdsKey) as? [String: String])?[key]
    }
    private func setStoredEventId(_ id: String?, for key: String) {
        var d = (UserDefaults.standard.dictionary(forKey: eventIdsKey) as? [String: String]) ?? [:]
        if let id { d[key] = id } else { d.removeValue(forKey: key) }
        UserDefaults.standard.set(d, forKey: eventIdsKey)
    }

    /// Retrouve l'événement déjà créé pour cette identité : d'abord via l'id local, sinon par adoption (marqueur dans
    /// les notes, fenêtre ±2 j autour de la date) pour les événements créés sur une autre machine et synchronisés.
    private func existingEvent(for key: String, around date: Date, in calendar: EKCalendar) -> EKEvent? {
        if let id = storedEventId(key), let e = store.event(withIdentifier: id), e.calendar == calendar { return e }
        let marker = "[\(key)]"
        let pred = store.predicateForEvents(withStart: date.addingTimeInterval(-2 * 86400),
                                            end: date.addingTimeInterval(2 * 86400), calendars: [calendar])
        guard let found = store.events(matching: pred).first(where: { ($0.notes ?? "").contains(marker) }) else { return nil }
        setStoredEventId(found.eventIdentifier, for: key)
        return found
    }

    private func apply(_ ev: CalendarEvent, to ek: EKEvent, in calendar: EKCalendar) {
        ek.calendar = calendar
        ek.title = ev.title
        ek.startDate = ev.startDate
        ek.endDate = ev.endDate
        ek.isAllDay = ev.isAllDay
        ek.location = ev.location
        ek.url = ev.url
        let marker = "[\(ev.identityKey)]"
        let base = ev.notes ?? ""
        ek.notes = base.isEmpty ? marker : "\(base)\n\n\(marker)"
    }

    // MARK: API publique

    /// Vrai si l'identité a un événement vivant dans le calendrier (lecture synchrone légère pour l'UI).
    func isSaved(_ identityKey: String) -> Bool {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let id = storedEventId(identityKey) else { return false }
        return store.event(withIdentifier: id) != nil
    }

    /// Crée ou met à jour l'événement (idempotent sur `identityKey`).
    func save(_ event: CalendarEvent) async throws {
        try await requestAccess()
        let cal = try dedicatedCalendar()
        let ek = existingEvent(for: event.identityKey, around: event.startDate, in: cal) ?? EKEvent(eventStore: store)
        apply(event, to: ek, in: cal)
        do { try store.save(ek, span: .thisEvent, commit: true) } catch { throw CalendarError.underlying(error.localizedDescription) }
        setStoredEventId(ek.eventIdentifier, for: event.identityKey)
    }

    /// Crée ou met à jour plusieurs événements liés (parcours/raid à venir).
    func save(_ events: [CalendarEvent]) async throws {
        for e in events { try await save(e) }
    }

    /// Retire l'événement correspondant à l'identité (no-op s'il n'existe pas).
    func remove(_ identityKey: String, around date: Date) async throws {
        try await requestAccess()
        let cal = try dedicatedCalendar()
        guard let ek = existingEvent(for: identityKey, around: date, in: cal) else { setStoredEventId(nil, for: identityKey); return }
        do { try store.remove(ek, span: .thisEvent, commit: true) } catch { throw CalendarError.underlying(error.localizedDescription) }
        setStoredEventId(nil, for: identityKey)
    }
}
