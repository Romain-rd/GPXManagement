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
    /// Au moins un segment routé via le repli (MapKit saturé) → itinéraire potentiellement de moindre qualité.
    var routedWithFallback = false
    var profileRaw = UserDefaults.standard.string(forKey: "routeProfile") ?? "car"
    let proxy = MapViewProxy()

    private(set) var activityId: UUID?
    private var autoSaveTask: Task<Void, Never>?

    private let repository: CoreDataActivityRepository
    init(repository: CoreDataActivityRepository) { self.repository = repository }

    /// Marque une modification et planifie un enregistrement automatique (débounce) après une pause d'édition.
    private func markDirty() {
        dirty = true
        scheduleAutoSave()
    }

    // MARK: Annuler / Rétablir (via l'UndoManager système → menu Édition + ⌘Z, unifié avec l'édition de texte)
    private struct Snapshot { let waypoints: [RouteWaypoint]; let segments: [[CLLocationCoordinate2D]?]; let selected: UUID? }
    weak var undoManager: UndoManager?
    var canUndo: Bool { undoManager?.canUndo ?? false }
    var canRedo: Bool { undoManager?.canRedo ?? false }

    /// À appeler AVANT une modification de géométrie : enregistre l'état courant comme point d'annulation.
    private func snapshot(_ name: String = "Modifier l'itinéraire") {
        let before = Snapshot(waypoints: waypoints, segments: segments, selected: selectedWaypointId)
        undoManager?.registerUndo(withTarget: self) { $0.apply(before, name: name) }
        undoManager?.setActionName(name)
    }

    /// Restaure un état et enregistre l'inverse (rétablir) — schéma récursif standard de l'UndoManager.
    private func apply(_ snap: Snapshot, name: String) {
        let inverse = Snapshot(waypoints: waypoints, segments: segments, selected: selectedWaypointId)
        undoManager?.registerUndo(withTarget: self) { $0.apply(inverse, name: name) }
        undoManager?.setActionName(name)
        waypoints = snap.waypoints; segments = snap.segments; selectedWaypointId = snap.selected
        markDirty()
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.dirty, self.waypoints.count >= 2, let id = self.activityId else { return }
            if self.busy { self.scheduleAutoSave(); return }   // routage/sauvegarde en cours : on réessaie plus tard
            self.save(activityId: id)
        }
    }

    private func coord(_ w: RouteWaypoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude) }
    var markers: [WaypointMarker] {
        let stages = stageArrivalNumbers
        let c = waypoints.count
        var p = 0, t = 0
        return waypoints.enumerated().map { i, w in
            // Départ/arrivée = extrémités « nature tracé » ; une extrémité retypée POI/arrêt s'affiche selon son rôle.
            let isDep = i == 0 && c >= 2 && w.role == .shaping
            let isArr = i == c - 1 && c >= 2 && w.role == .shaping
            var label: String? = nil
            if stages[w.id] == nil, !isDep, !isArr {
                if w.role == .poi { p += 1; label = "P\(p)" }
                else if w.role == .shaping { t += 1; label = "T\(t)" }
            }
            return WaypointMarker(id: w.id, coordinate: coord(w), index: i, role: w.role, name: w.name, label: label, isSelected: w.id == selectedWaypointId, isArrival: isArr, isDeparture: isDep, stageIndex: stages[w.id])
        }
    }

    /// Numéros typés (J/P/T) par waypoint — partagés entre la carte et la liste pour suivre les correspondances.
    var typedLabels: [UUID: String] {
        let stages = stageArrivalNumbers
        let c = waypoints.count
        var out: [UUID: String] = [:]
        var p = 0, t = 0
        for (i, w) in waypoints.enumerated() {
            if let n = stages[w.id] { out[w.id] = "J\(n)"; continue }
            // On ne saute que les VRAIES extrémités (tracé) — une extrémité retypée POI/tracé reçoit son label.
            if (i == 0 || i == c - 1) && w.role == .shaping { continue }
            if w.role == .poi { p += 1; out[w.id] = "P\(p)" }
            else if w.role == .shaping { t += 1; out[w.id] = "T\(t)" }
        }
        return out
    }

    /// Numéro d'étape (Jn) de chaque arrêt d'arrivée — UNIQUEMENT si le parcours a au moins un arrêt interne.
    /// Sans arrêt, c'est un parcours simple (départ → arrivée, sortie à la journée) : aucune étape, donc aucun Jn.
    var stageArrivalNumbers: [UUID: Int] {
        let c = waypoints.count
        let hasStops = waypoints.indices.contains { $0 > 0 && $0 < c - 1 && waypoints[$0].role == .stageStop }
        guard hasStops else { return [:] }
        var out: [UUID: Int] = [:]
        var n = 0
        // L'arrivée (dernier point) ne compte comme fin d'étape que si elle est restée « tracé » ;
        // retypée en POI/point de tracé explicite, elle perd son numéro d'étape (le rôle l'emporte).
        for (i, wp) in waypoints.enumerated() where i > 0 && (wp.role == .stageStop || (i == c - 1 && wp.role == .shaping)) {
            n += 1; out[wp.id] = n
        }
        return out
    }
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
        markDirty()
    }

    /// Fait défiler le rôle d'un point : tracé muet → point d'intérêt → arrêt d'étape.
    func setRole(_ role: RouteWaypoint.Role, for id: UUID) {
        guard let j = waypoints.firstIndex(where: { $0.id == id }), waypoints[j].role != role else { return }
        snapshot("Changer le rôle")
        waypoints[j].role = role
        markDirty()
    }

    func cycleRole(_ id: UUID) {
        guard let j = waypoints.firstIndex(where: { $0.id == id }) else { return }
        snapshot("Changer le rôle")
        let order: [RouteWaypoint.Role] = [.shaping, .poi, .stageStop]
        waypoints[j].role = order[((order.firstIndex(of: waypoints[j].role) ?? 0) + 1) % order.count]
        markDirty()
    }

    func invalidateAll() {
        segments = Array(repeating: nil, count: max(0, waypoints.count - 1))
        markDirty()
    }

    private func touch(_ k: Int) {
        if k - 1 >= 0, k - 1 < segments.count { segments[k - 1] = nil }
        if k >= 0, k < segments.count { segments[k] = nil }
    }

    func moveWaypoint(id: UUID, to c: CLLocationCoordinate2D) {
        guard !busy, let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        snapshot("Déplacer un point")
        // Aimantation boucle : glisser une extrémité tout près de l'autre la colle exactement dessus (arrivée = départ).
        var target = c
        let n = waypoints.count
        if n >= 3, i == 0 || i == n - 1 {
            let other = waypoints[i == 0 ? n - 1 : 0]
            let oc = CLLocationCoordinate2D(latitude: other.latitude, longitude: other.longitude)
            if isWithinSnapDistance(target, oc) { target = oc }
        }
        // Changement de PLACE (> 400 m) → on efface le nom pour qu'il soit re-déduit ; un simple ajustement le conserve.
        let moved = CLLocation(latitude: waypoints[i].latitude, longitude: waypoints[i].longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        waypoints[i].latitude = target.latitude
        waypoints[i].longitude = target.longitude
        if moved > 400 { waypoints[i].name = nil }
        touch(i)
        markDirty()
    }

    /// Proximité à l'écran (indépendante du zoom) entre deux coordonnées ; repli métrique si la carte n'est pas dispo.
    private func isWithinSnapDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        if let mv = proxy.mapView {
            let pa = mv.convert(a, toPointTo: mv), pb = mv.convert(b, toPointTo: mv)
            return hypot(pa.x - pb.x, pa.y - pb.y) < 24
        }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < 40
    }

    /// Ferme le parcours en boucle : ajoute une arrivée aux coordonnées exactes du départ (le retour est routé).
    func closeLoop() {
        guard !busy, waypoints.count >= 2, let first = waypoints.first, let last = waypoints.last else { return }
        let firstC = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
        let lastC = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
        // Déjà bouclé (dernier ≈ départ) → ne rien faire.
        if CLLocation(latitude: lastC.latitude, longitude: lastC.longitude)
            .distance(from: CLLocation(latitude: firstC.latitude, longitude: firstC.longitude)) < 20 { return }
        snapshot("Fermer la boucle")
        let wp = RouteWaypoint(latitude: first.latitude, longitude: first.longitude, role: .shaping)
        waypoints.append(wp)
        segments.append(nil)
        selectedWaypointId = wp.id
        markDirty()
    }

    /// Vrai si le parcours forme déjà une boucle (arrivée ≈ départ) — pour l'état du bouton « Fermer la boucle ».
    var isLoop: Bool {
        guard waypoints.count >= 2, let first = waypoints.first, let last = waypoints.last else { return false }
        return CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) < 20
    }

    /// Insère le point à sa place le long du tracé en projetant `c` sur la polyligne routée (arête la plus proche).
    /// L'extension (en bout / en tête) ne se déclenche que si le clic tombe vraiment au-delà d'une extrémité.
    /// Point de mise en forme : posé SUR le tracé (l'utilisateur le déplace ensuite) ; POI/arrêt : à l'endroit cliqué.
    func addWaypoint(at c: CLLocationCoordinate2D, role: RouteWaypoint.Role = .shaping, name: String? = nil) {
        guard !busy else { return }
        snapshot("Ajouter un point")
        let proj = projectionOnRoute(c)
        let p = proj?.index ?? waypoints.count
        let pos = (role == .shaping ? proj?.snapped : nil) ?? c
        let wp = RouteWaypoint(latitude: pos.latitude, longitude: pos.longitude, name: name, role: role)
        waypoints.insert(wp, at: p)
        if waypoints.count == 2 { segments = [nil] }
        else if p == 0 { segments.insert(nil, at: 0) }
        else if p >= waypoints.count - 1 { segments.append(nil) }
        else { segments.replaceSubrange((p - 1)...(p - 1), with: [nil, nil]) }
        selectedWaypointId = wp.id
        markDirty()
    }

    /// Réordonne les points (glisser dans la liste) ; l'ordre change → on recalcule tout le tracé.
    func moveWaypoints(fromOffsets: IndexSet, toOffset: Int) {
        guard !busy else { return }
        snapshot("Réordonner")
        waypoints.move(fromOffsets: fromOffsets, toOffset: toOffset)
        invalidateAll()
    }

    /// Projette `c` sur la polyligne routée : segment de waypoints le plus proche (projection orthogonale sur ses
    /// arêtes) → index d'insertion + point projeté sur le tracé. L'extension (index 0 / en bout) n'est retenue que
    /// si la projection retombe exactement sur l'extrémité terminale (clic au-delà du départ ou de l'arrivée).
    private func projectionOnRoute(_ c: CLLocationCoordinate2D) -> (index: Int, snapped: CLLocationCoordinate2D)? {
        guard waypoints.count >= 2 else { return nil }
        let kx = cos(c.latitude * .pi / 180)
        let cx = c.longitude * kx, cy = c.latitude
        let lastSeg = waypoints.count - 2
        var bestD = Double.greatestFiniteMagnitude
        var bestSeg = 0
        var bestPoint = c
        var atRouteStart = false, atRouteEnd = false
        for i in 0...lastSeg {
            let seg = (i < segments.count ? segments[i] : nil) ?? [coord(waypoints[i]), coord(waypoints[i + 1])]
            guard seg.count >= 2 else { continue }
            for j in 0..<(seg.count - 1) {
                let ax = seg[j].longitude * kx, ay = seg[j].latitude
                let bx = seg[j + 1].longitude * kx, by = seg[j + 1].latitude
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, ((cx - ax) * dx + (cy - ay) * dy) / len2)) : 0
                let px = ax + t * dx, py = ay + t * dy
                let ex = px - cx, ey = py - cy
                let d = ex * ex + ey * ey
                if d < bestD {
                    bestD = d; bestSeg = i
                    bestPoint = CLLocationCoordinate2D(latitude: py, longitude: px / kx)
                    atRouteStart = (i == 0 && j == 0 && t == 0)
                    atRouteEnd = (i == lastSeg && j == seg.count - 2 && t == 1)
                }
            }
        }
        let index = atRouteStart ? 0 : (atRouteEnd ? waypoints.count : bestSeg + 1)
        return (index, bestPoint)
    }

    func delete(_ id: UUID) {
        // On autorise la suppression de n'importe quel point, y compris le départ/l'arrivée (jusqu'à n'en garder qu'un).
        guard !busy, let k = waypoints.firstIndex(where: { $0.id == id }), waypoints.count > 1 else { return }
        snapshot("Supprimer un point")
        if k == 0 { if !segments.isEmpty { segments.removeFirst() } }
        else if k == waypoints.count - 1 { if !segments.isEmpty { segments.removeLast() } }
        else if k - 1 < segments.count, k < segments.count { segments.replaceSubrange((k - 1)...k, with: [nil]) }
        waypoints.remove(at: k)
        if selectedWaypointId == id { selectedWaypointId = nil }
        markDirty()
    }

    /// Replace un point en tête (départ) ; redevient un simple ancrage `.shaping` (départ = position, pas un rôle).
    func makeDeparture(_ id: UUID) {
        guard !busy, let i = waypoints.firstIndex(where: { $0.id == id }), i != 0 else { return }
        snapshot("Définir le départ")
        var wp = waypoints.remove(at: i); wp.role = .shaping
        waypoints.insert(wp, at: 0)
        selectedWaypointId = wp.id
        invalidateAll()
    }

    /// Replace un point en fin (arrivée) ; redevient un simple ancrage `.shaping`.
    func makeArrival(_ id: UUID) {
        guard !busy, let i = waypoints.firstIndex(where: { $0.id == id }), i != waypoints.count - 1 else { return }
        snapshot("Définir l'arrivée")
        var wp = waypoints.remove(at: i); wp.role = .shaping
        waypoints.append(wp)
        selectedWaypointId = wp.id
        invalidateAll()
    }

    func reroute() {
        guard waypoints.count >= 2, !busy, hasPending else { return }
        isRouting = true
        Task {
            await routeMissing()
            isRouting = false
            markDirty()
            await nameWaypoints()
        }
    }

    /// Route uniquement les segments à nil (les bornes modifiées) ; les autres restent en cache.
    private func routeMissing() async {
        let profile = RouteProfile(rawValue: profileRaw) ?? .car
        let pending = segments.indices.filter { segments[$0] == nil }
        guard !pending.isEmpty else { return }
        routeTotal = pending.count
        routeDone = 0
        routedWithFallback = false
        for (n, i) in pending.enumerated() {
            guard i >= 0, i + 1 < waypoints.count else { continue }
            if n > 0, ConnectorRouter.needsPacing { try? await Task.sleep(nanoseconds: 350_000_000) }
            let r = await ConnectorRouter.route(from: coord(waypoints[i]), to: coord(waypoints[i + 1]), profile: profile)
            var seg = r.coords
            if seg.count < 2 { seg = [coord(waypoints[i]), coord(waypoints[i + 1])] }
            if r.fellBack { routedWithFallback = true }
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
                markDirty()
            }
        }
    }

    func save(activityId: UUID, onSaved: @escaping () -> Void = {}) {
        guard waypoints.count >= 2, !busy else { return }
        self.activityId = activityId
        autoSaveTask?.cancel()
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

    /// Enregistre tout de suite s'il y a des modifications en attente (fermeture de fenêtre, navigation).
    func saveIfDirty() {
        guard dirty, waypoints.count >= 2, let id = activityId else { return }
        autoSaveTask?.cancel()
        save(activityId: id)
    }

    func load(activityId: UUID) async {
        self.activityId = activityId
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
