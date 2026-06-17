import SwiftUI
import MapKit
import GPXCore
import GPXMapKit

/// Logique d'édition d'itinéraire d'un parcours (points de passage typés + routage par segment), isolée de l'UI
/// pour être pilotée depuis la carte unique et la barre adaptative de `ParcoursDetailView` (plus de sous-éditeur).
@MainActor
@Observable
final class RouteEditingModel {
    var waypoints: [RouteWaypoint] = []
    // Tracé routé par paire de points consécutifs (segment i = waypoints[i]→waypoints[i+1]).
    // nil = à (re)calculer ; seuls les segments touchés par une édition sont remis à nil.
    var segments: [[CLLocationCoordinate2D]?] = []
    var selectedWaypointId: UUID?
    var isRouting = false
    var isSaving = false
    var dirty = false
    var routeDone = 0
    var routeTotal = 0
    var engineRaw = UserDefaults.standard.string(forKey: "connectorEngine") ?? "mapkit"
    let proxy = MapViewProxy()

    private let repository: CoreDataActivityRepository
    init(repository: CoreDataActivityRepository) { self.repository = repository }

    private func coord(_ w: RouteWaypoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude) }
    var markers: [WaypointMarker] { waypoints.enumerated().map { WaypointMarker(id: $1.id, coordinate: coord($1), index: $0, role: $1.role, name: $1.name, label: $1.role == .shaping ? nil : "\($0 + 1)") } }
    var hasPending: Bool { segments.contains(where: { $0 == nil }) }
    var busy: Bool { isRouting || isSaving }

    /// Tracé affiché : concaténation des segments routés (ligne droite en aperçu pour les segments en attente).
    var displayCoords: [CLLocationCoordinate2D] {
        guard waypoints.count >= 2 else { return waypoints.map(coord) }
        var out: [CLLocationCoordinate2D] = []
        for i in 0..<(waypoints.count - 1) {
            var seg = (i < segments.count ? segments[i] : nil) ?? [coord(waypoints[i]), coord(waypoints[i + 1])]
            if seg.count < 2 { seg = [coord(waypoints[i]), coord(waypoints[i + 1])] }
            if !out.isEmpty { seg.removeFirst() }
            out.append(contentsOf: seg)
        }
        return out
    }

    func name(for id: UUID) -> String { waypoints.first(where: { $0.id == id })?.name ?? "" }
    func setName(_ value: String, for id: UUID) {
        guard let j = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let t = value.trimmingCharacters(in: .whitespaces)
        waypoints[j].name = t.isEmpty ? nil : value
        dirty = true
    }

    /// Fait défiler le rôle d'un point : tracé muet → point d'intérêt → arrêt d'étape.
    func cycleRole(_ id: UUID) {
        guard let j = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let order: [RouteWaypoint.Role] = [.shaping, .poi, .stageStop]
        waypoints[j].role = order[((order.firstIndex(of: waypoints[j].role) ?? 0) + 1) % order.count]
        dirty = true
    }

    func invalidateAll() {
        segments = Array(repeating: nil, count: max(0, waypoints.count - 1))
        dirty = true
    }

    private func touch(_ k: Int) {
        if k - 1 >= 0, k - 1 < segments.count { segments[k - 1] = nil }
        if k >= 0, k < segments.count { segments[k] = nil }
    }

    func moveWaypoint(id: UUID, to c: CLLocationCoordinate2D) {
        guard !busy, let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[i].latitude = c.latitude
        waypoints[i].longitude = c.longitude
        touch(i)
        dirty = true
    }

    /// `append` : ajoute en bout de tracé (ordre = ordre d'ajout). Sinon, insère à la position de détour minimal
    /// (pour poser un POI/arrêt le long d'un tracé existant).
    func addWaypoint(at c: CLLocationCoordinate2D, role: RouteWaypoint.Role = .shaping, append: Bool = false) {
        guard !busy else { return }
        let wp = RouteWaypoint(latitude: c.latitude, longitude: c.longitude, role: role)
        var p = waypoints.count
        if !append, waypoints.count >= 2 {
            // Meilleure position : extension à une extrémité OU insertion sur le segment au détour minimal.
            var bestCost = planar(waypoints[waypoints.count - 1], c)
            let startCost = planar(waypoints[0], c)
            if startCost < bestCost { bestCost = startCost; p = 0 }
            for i in 0..<(waypoints.count - 1) {
                let cost = planar(waypoints[i], c) + planar(waypoints[i + 1], c) - planarWW(waypoints[i], waypoints[i + 1])
                if cost < bestCost { bestCost = cost; p = i + 1 }
            }
        }
        waypoints.insert(wp, at: p)
        if waypoints.count == 2 { segments = [nil] }
        else if p == 0 { segments.insert(nil, at: 0) }
        else if p >= waypoints.count - 1 { segments.append(nil) }
        else { segments.replaceSubrange((p - 1)...(p - 1), with: [nil, nil]) }
        selectedWaypointId = wp.id
        dirty = true
    }

    func delete(_ id: UUID) {
        guard !busy, let k = waypoints.firstIndex(where: { $0.id == id }), waypoints.count > 2 else { return }
        if k == 0 { if !segments.isEmpty { segments.removeFirst() } }
        else if k == waypoints.count - 1 { if !segments.isEmpty { segments.removeLast() } }
        else if k - 1 < segments.count, k < segments.count { segments.replaceSubrange((k - 1)...k, with: [nil]) }
        waypoints.remove(at: k)
        if selectedWaypointId == id { selectedWaypointId = nil }
        dirty = true
    }

    private func planar(_ w: RouteWaypoint, _ c: CLLocationCoordinate2D) -> Double {
        let dx = w.longitude - c.longitude, dy = w.latitude - c.latitude
        return (dx * dx + dy * dy).squareRoot()
    }
    private func planarWW(_ a: RouteWaypoint, _ b: RouteWaypoint) -> Double {
        let dx = a.longitude - b.longitude, dy = a.latitude - b.latitude
        return (dx * dx + dy * dy).squareRoot()
    }

    func reroute() {
        guard waypoints.count >= 2, !busy, hasPending else { return }
        isRouting = true
        Task {
            await routeMissing()
            isRouting = false
            dirty = true
            await nameWaypoints()
        }
    }

    /// Route uniquement les segments à nil (les bornes modifiées) ; les autres restent en cache.
    private func routeMissing() async {
        let engine = ConnectorRouter.Engine(rawValue: engineRaw) ?? .mapkit
        let pending = segments.indices.filter { segments[$0] == nil }
        guard !pending.isEmpty else { return }
        routeTotal = pending.count
        routeDone = 0
        for (n, i) in pending.enumerated() {
            guard i >= 0, i + 1 < waypoints.count else { continue }
            if n > 0, engine == .mapkit || engine == .car { try? await Task.sleep(nanoseconds: 150_000_000) }
            var seg = await ConnectorRouter.route(from: coord(waypoints[i]), to: coord(waypoints[i + 1]), engine: engine)
            if seg.count < 2 { seg = [coord(waypoints[i]), coord(waypoints[i + 1])] }
            if i < segments.count { segments[i] = seg }
            routeDone = n + 1
        }
    }

    /// Nomme les POI/arrêts sans nom via OpenStreetMap (cols/sommets Overpass puis ville Nominatim).
    private func nameWaypoints() async {
        let targets = waypoints.filter { $0.role != .shaping && ($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !targets.isEmpty else { return }
        let passes = await OSMNaming.passes(near: targets.map { coord($0) })
        for wp in targets {
            let c = coord(wp)
            var label = OSMNaming.nearestName(passes, to: c, within: 700)
            if label == nil {
                label = await OSMNaming.place(c)
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }
            if let label, let j = waypoints.firstIndex(where: { $0.id == wp.id }),
               (waypoints[j].name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                waypoints[j].name = label
                dirty = true
            }
        }
    }

    func save(activityId: UUID, onSaved: @escaping () -> Void) {
        guard waypoints.count >= 2, !busy else { return }
        dirty = false
        isSaving = true
        Task {
            if hasPending { isRouting = true; await routeMissing(); isRouting = false }
            await nameWaypoints()
            let ok = await AppServices.shared.applyRouteWaypoints(activityId: activityId, waypoints: waypoints, routedCoords: displayCoords)
            isSaving = false
            if ok { onSaved() }
        }
    }

    func saveIfNeeded(activityId: UUID, onSaved: @escaping () -> Void) {
        guard dirty, waypoints.count >= 2 else { return }
        save(activityId: activityId, onSaved: onSaved)
    }

    func load(activityId: UUID) async {
        waypoints = await AppServices.shared.initialWaypoints(activityId: activityId)
        if let data = try? await repository.fetchTrackData(id: activityId), let pts = try? TrackPointCodec.decode(data), pts.count >= 2 {
            let track = pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            segments = Self.splitTrack(track, waypoints: waypoints)
        } else {
            segments = Array(repeating: nil, count: max(0, waypoints.count - 1))
        }
    }

    /// Recadre la carte sur tout le parcours.
    func fit() {
        guard let mv = proxy.mapView, !displayCoords.isEmpty else { return }
        if displayCoords.count == 1 {
            mv.setRegion(MKCoordinateRegion(center: displayCoords[0], latitudinalMeters: 4000, longitudinalMeters: 4000), animated: true)
        } else {
            var rect = MKMapRect.null
            for c in displayCoords { let p = MKMapPoint(c); rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
            mv.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48), animated: true)
        }
    }

    /// Découpe un tracé continu en sous-tracés par paire de points (index le plus proche, monotone).
    static func splitTrack(_ track: [CLLocationCoordinate2D], waypoints: [RouteWaypoint]) -> [[CLLocationCoordinate2D]?] {
        guard waypoints.count >= 2, track.count >= 2 else { return Array(repeating: nil, count: max(0, waypoints.count - 1)) }
        func d2(_ a: CLLocationCoordinate2D, _ lat: Double, _ lon: Double) -> Double {
            let dx = a.longitude - lon, dy = a.latitude - lat; return dx * dx + dy * dy
        }
        var idx = [Int](repeating: 0, count: waypoints.count)
        var start = 0
        for j in 0..<waypoints.count {
            var best = start, bestD = Double.greatestFiniteMagnitude
            for t in start..<track.count {
                let dd = d2(track[t], waypoints[j].latitude, waypoints[j].longitude)
                if dd < bestD { bestD = dd; best = t }
            }
            idx[j] = best; start = best
        }
        idx[0] = 0; idx[idx.count - 1] = track.count - 1
        for j in 1..<idx.count where idx[j] <= idx[j - 1] { idx[j] = min(idx[j - 1] + 1, track.count - 1) }
        var segs: [[CLLocationCoordinate2D]?] = []
        for j in 0..<(waypoints.count - 1) {
            let a = idx[j], b = max(idx[j + 1], a + 1)
            let slice = Array(track[a...min(b, track.count - 1)])
            segs.append(slice.count >= 2 ? slice : nil)
        }
        return segs
    }
}
