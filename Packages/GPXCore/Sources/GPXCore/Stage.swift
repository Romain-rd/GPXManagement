import Foundation

/// Étape d'un parcours : plage de points `[startIndex...endIndex]` d'une trace, avec nom, notes et photo.
/// Persistée comme entité Core Data « Stage » (parent = `activityId`).
public struct Stage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let activityId: UUID
    public var order: Int
    public var name: String
    public var notes: String?
    public var startIndex: Int
    public var endIndex: Int
    /// Point de passage `.stageStop` qui termine cette étape (référence stable, remplace à terme les indices).
    public var stopWaypointId: UUID?
    public var coverImageData: Data?
    /// Point d'arrivée hors-trace (refuge/village à l'écart du tracé), s'il y en a un.
    public var endOffTrackLatitude: Double?
    public var endOffTrackLongitude: Double?
    /// Raccord (route du point `endIndex` du tracé vers le point hors-trace), encodé en `[TrackPoint]` avec altitude.
    public var endConnectorData: Data?
    /// Raccord de **départ** (route du point hors-trace de départ vers `startIndex` du tracé) — calculé indépendamment
    /// (plus court pour rejoindre la trace) ; n'est pas l'inverse du raccord d'arrivée de l'étape précédente.
    public var startConnectorData: Data?
    /// Date planifiée de l'étape (jour de marche), pour un parcours daté.
    public var plannedDate: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), activityId: UUID, order: Int, name: String, notes: String? = nil,
                startIndex: Int, endIndex: Int, stopWaypointId: UUID? = nil, coverImageData: Data? = nil,
                endOffTrackLatitude: Double? = nil, endOffTrackLongitude: Double? = nil, endConnectorData: Data? = nil,
                startConnectorData: Data? = nil, plannedDate: Date? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.activityId = activityId
        self.order = order
        self.name = name
        self.notes = notes
        self.startIndex = Swift.min(startIndex, endIndex)
        self.endIndex = Swift.max(startIndex, endIndex)
        self.stopWaypointId = stopWaypointId
        self.coverImageData = coverImageData
        self.endOffTrackLatitude = endOffTrackLatitude
        self.endOffTrackLongitude = endOffTrackLongitude
        self.endConnectorData = endConnectorData
        self.startConnectorData = startConnectorData
        self.plannedDate = plannedDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Points du raccord d'arrivée (avec altitude), décodés depuis `endConnectorData`.
    public var endConnectorPoints: [TrackPoint] {
        guard let data = endConnectorData else { return [] }
        return (try? TrackPointCodec.decode(data)) ?? []
    }

    /// Points du raccord de départ (point hors-trace → `startIndex` du tracé), décodés depuis `startConnectorData`.
    public var startConnectorPoints: [TrackPoint] {
        guard let data = startConnectorData else { return [] }
        return (try? TrackPointCodec.decode(data)) ?? []
    }

    /// Points couverts, bornés au tableau (robuste si la trace a changé).
    public func slice(of points: [TrackPoint]) -> [TrackPoint] {
        guard !points.isEmpty else { return [] }
        let lo = Swift.max(0, Swift.min(startIndex, points.count - 1))
        let hi = Swift.max(lo, Swift.min(endIndex, points.count - 1))
        return Array(points[lo...hi])
    }

    public func stats(in points: [TrackPoint]) -> ActivityStats {
        ActivityStatsCalculator.compute(points: slice(of: points))
    }

    /// Renseigne `startIndex/endIndex` (champs de travail en mémoire) des étapes à partir des stops `.stageStop`
    /// de `waypoints` : chaque étape (sauf la dernière) finit au stop référencé par `stopWaypointId`. Source de
    /// vérité = les stops (stables même après re-routage) ; les indices ne sont plus persistés.
    public static func assignBoundaries(_ stages: [Stage], from waypoints: [RouteWaypoint], points: [TrackPoint]) -> [Stage] {
        guard !stages.isEmpty, points.count >= 2 else { return stages }
        let lastIndex = points.count - 1
        let stopIndexById = Dictionary(RouteWaypoint.stageBoundaries(waypoints, on: points), uniquingKeysWith: { a, _ in a })
        var result = stages
        var prevEnd = 0
        for k in result.indices {
            let start = (k == 0) ? 0 : prevEnd
            let end: Int
            if k == result.count - 1 {
                end = lastIndex
            } else if let sid = result[k].stopWaypointId, let idx = stopIndexById[sid] {
                end = Swift.max(start + 1, Swift.min(idx, lastIndex))
            } else {
                end = Swift.max(start + 1, Swift.min(result[k].endIndex, lastIndex))
            }
            result[k].startIndex = start
            result[k].endIndex = end
            prevEnd = end
        }
        return result
    }

    /// Crée les étapes à partir des arrêts `.stageStop` des waypoints (source de vérité en mode itinéraire) :
    /// une étape par intervalle entre deux arrêts consécutifs (extrémités du tracé incluses). L'étape se termine
    /// au stop référencé par `stopWaypointId` (la dernière n'en a pas). Conserve les métadonnées des étapes
    /// existantes retrouvées par `stopWaypointId`.
    public static func derive(activityId: UUID, from waypoints: [RouteWaypoint], points: [TrackPoint], existing: [Stage]) -> [Stage] {
        guard points.count >= 2 else { return existing }
        let lastIndex = points.count - 1
        let stops = RouteWaypoint.stageBoundaries(waypoints, on: points)
            .filter { $0.index > 0 && $0.index < lastIndex }
            .sorted { $0.index < $1.index }
        let byStopId = Dictionary(existing.compactMap { s in s.stopWaypointId.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let lastExisting = existing.first { $0.stopWaypointId == nil } ?? existing.last
        var result: [Stage] = []
        var start = 0
        let count = stops.count + 1
        for k in 0..<count {
            let isLast = k == count - 1
            let stopId: UUID? = isLast ? nil : stops[k].stopId
            let end = isLast ? lastIndex : stops[k].index
            let prev = stopId.flatMap { byStopId[$0] } ?? (isLast ? lastExisting : nil)
            result.append(Stage(id: prev?.id ?? UUID(), activityId: activityId, order: k,
                                name: prev?.name ?? "", notes: prev?.notes,
                                startIndex: start, endIndex: Swift.max(start + 1, end),
                                stopWaypointId: stopId, coverImageData: prev?.coverImageData,
                                endOffTrackLatitude: prev?.endOffTrackLatitude,
                                endOffTrackLongitude: prev?.endOffTrackLongitude,
                                endConnectorData: prev?.endConnectorData,
                                startConnectorData: prev?.startConnectorData,
                                plannedDate: prev?.plannedDate))
            start = end
        }
        return result
    }

    /// Reconstruit les waypoints `.stageStop` à partir des bornes (en mémoire) des étapes : un stop par frontière
    /// interne, posé sur `points[endIndex]`, en réutilisant l'id/nom existant. Préserve les autres waypoints
    /// (`.shaping`/`.poi`) et renvoie les étapes avec leur `stopWaypointId` à jour. Tout est ordonné par le tracé.
    public static func syncStops(_ stages: [Stage], into waypoints: [RouteWaypoint], points: [TrackPoint]) -> (waypoints: [RouteWaypoint], stages: [Stage]) {
        guard points.count >= 2 else { return (waypoints, stages) }
        let lastIndex = points.count - 1
        let existingById = Dictionary(waypoints.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let others = waypoints.filter { $0.role != .stageStop }
        var result = stages
        var stops: [RouteWaypoint] = []
        for k in result.indices where k < result.count - 1 {
            let idx = Swift.max(0, Swift.min(result[k].endIndex, lastIndex))
            let p = points[idx]
            let id = result[k].stopWaypointId ?? UUID()
            // Le nom de l'étape devient le nom du point d'arrêt (source unique) ; repli sur l'existant si vide.
            let existing = result[k].stopWaypointId.flatMap { existingById[$0]?.name }
            let stageName = result[k].name.trimmingCharacters(in: .whitespaces)
            let name = stageName.isEmpty ? existing : stageName
            stops.append(RouteWaypoint(id: id, latitude: p.latitude, longitude: p.longitude, name: name, role: .stageStop))
            result[k].stopWaypointId = id
        }
        if !result.isEmpty { result[result.count - 1].stopWaypointId = nil }
        // Ordonne l'ensemble par position sur le tracé (stops + autres waypoints).
        func idx(_ w: RouteWaypoint) -> Int { RouteWaypoint.nearestIndex(latitude: w.latitude, longitude: w.longitude, in: points) }
        let merged = (others.map { ($0, idx($0)) } + stops.map { ($0, idx($0)) }).sorted { $0.1 < $1.1 }.map(\.0)
        return (merged, result)
    }
}
