import SwiftUI
import AppKit
import Charts
import MapKit
import Photos
import QuickLook
import AVFoundation
import UniformTypeIdentifiers
import GPXCore
import GPXRender
import GPXVideo
import GPXMapKit

/// Éditeur d'itinéraire d'un parcours, **inline** dans la section Carte (activé par un toggle) : points de
/// passage déplaçables sur la carte IGN, ajout au clic (insertion ou extension), suppression, routage live.
/// Enregistre en sortant (toggle off / changement d'activité) ou via le bouton.
struct RouteEditorView: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Binding var layer: MapLayer
    @Binding var mapHeight: Double
    var onSaved: () -> Void

    @State private var waypoints: [RouteWaypoint] = []
    // Un tracé routé par paire de points consécutifs (segment i = waypoints[i]→waypoints[i+1]).
    // nil = à (re)calculer ; seuls les segments touchés par une édition sont remis à nil.
    @State private var segments: [[CLLocationCoordinate2D]?] = []
    @State private var selectedWaypointId: UUID?
    @State private var isLoading = true
    @State private var isRouting = false
    @State private var isSaving = false
    @State private var dirty = false
    @State private var routeDone = 0
    @State private var routeTotal = 0
    @State private var mapProxy = MapViewProxy()
    @State private var placeQuery = ""
    @State private var searching = false
    @AppStorage("connectorEngine") private var engineRaw = "mapkit"

    private func coord(_ w: RouteWaypoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude) }
    private var markers: [WaypointMarker] { waypoints.enumerated().map { WaypointMarker(id: $1.id, coordinate: coord($1), index: $0, role: $1.role, name: $1.name) } }
    private var hasPending: Bool { segments.contains(where: { $0 == nil }) }
    private var busy: Bool { isRouting || isSaving }

    // Tracé affiché : concaténation des segments routés (ligne droite en aperçu pour les segments en attente).
    private var displayCoords: [CLLocationCoordinate2D] {
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

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, minHeight: mapHeight)
            } else {
                placeSearchBar
                StageColoredMap(
                    activityId: activity.id, activityType: activity.activityType,
                    coords: displayCoords, waypoints: markers,
                    onWaypointMoved: { id, c in moveWaypoint(id: id, to: c) },
                    onWaypointTapped: { selectedWaypointId = ($0 == selectedWaypointId ? nil : $0) },
                    onMapClick: { addWaypoint(at: $0) },
                    proxy: mapProxy,
                    layer: $layer
                )
                .frame(height: mapHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .top) {
                    Text("Clic = ajouter · glisser = déplacer · sélectionne un point dans la liste pour le supprimer")
                        .font(.caption).padding(6).background(.thinMaterial, in: Capsule()).padding(8)
                }
                .overlay(alignment: .bottom) {
                    if isRouting {
                        VStack(spacing: 4) {
                            Text("Routage \(routeDone)/\(routeTotal)…").font(.caption)
                            ProgressView(value: Double(routeDone), total: Double(max(routeTotal, 1)))
                        }
                        .frame(width: 240).padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                    } else if isSaving {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Calcul de l'altitude…").font(.caption)
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                    }
                }
                DragResizeHandle { d in mapHeight = Swift.min(900, Swift.max(200, mapHeight + Double(d))) }
                controls
                waypointList
            }
        }
        .task { await load() }
        .onDisappear { saveIfNeeded() }
    }

    private var placeSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher un lieu (ville, col, refuge…)", text: $placeQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await searchPlace() } }
            if searching { ProgressView().controlSize(.small) }
        }
    }

    /// Recentre la carte sur le lieu recherché (sans rien ajouter au tracé).
    private func searchPlace() async {
        let q = placeQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let region = mapProxy.mapView?.region { request.region = region }
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return }
        let c = item.placemark.coordinate
        mapProxy.mapView?.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 9000, longitudinalMeters: 9000), animated: true)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("\(waypoints.count) pt").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $engineRaw) {
                Text("À pied").tag("mapkit")
                Text("Sentiers").tag("trail")
                Text("Route (auto/moto)").tag("car")
                Text("Ligne").tag("line")
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .onChange(of: engineRaw) { _, _ in invalidateAll() } // changer de moteur recalcule tout.
            Button { reroute() } label: { Label("Recalculer l'itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond") }
                .controlSize(.small).disabled(busy || waypoints.count < 2 || !hasPending)
            Spacer()
            Button { saveNow() } label: { Label("Enregistrer", systemImage: "checkmark") }
                .controlSize(.small).disabled(waypoints.count < 2 || busy)
        }
    }

    private var waypointList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { i, wp in
                    HStack(spacing: 8) {
                        Button { cycleRole(wp.id) } label: { roleIcon(wp.role) }
                            .buttonStyle(.borderless)
                            .help("Rôle : point de tracé · point d'intérêt · arrêt d'étape (cliquer pour changer)")
                        Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(selectedWaypointId == wp.id ? Color.orange : Color.blue))
                            .contentShape(Circle())
                            .onTapGesture { selectedWaypointId = (selectedWaypointId == wp.id ? nil : wp.id) }
                        TextField(String(format: "%.4f, %.4f", wp.latitude, wp.longitude), text: nameBinding(wp.id))
                            .textFieldStyle(.plain).font(.caption)
                        Spacer(minLength: 4)
                        Button { delete(wp.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(waypoints.count <= 2)
                    }
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background(selectedWaypointId == wp.id ? Color.accentColor.opacity(0.12) : .clear)
                }
            }
        }
        .frame(maxHeight: 130)
    }

    @ViewBuilder
    private func roleIcon(_ role: RouteWaypoint.Role) -> some View {
        switch role {
        case .shaping: Image(systemName: "smallcircle.filled.circle").foregroundStyle(.secondary)
        case .poi: Image(systemName: "mappin.circle.fill").foregroundStyle(.orange)
        case .stageStop: Image(systemName: "flag.circle.fill").foregroundStyle(.green)
        }
    }

    // Fait défiler le rôle d'un point : tracé muet → point d'intérêt → arrêt d'étape.
    private func cycleRole(_ id: UUID) {
        guard let j = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let order: [RouteWaypoint.Role] = [.shaping, .poi, .stageStop]
        let next = order[((order.firstIndex(of: waypoints[j].role) ?? 0) + 1) % order.count]
        waypoints[j].role = next
        dirty = true
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { waypoints.first(where: { $0.id == id })?.name ?? "" },
            set: { v in
                guard let j = waypoints.firstIndex(where: { $0.id == id }) else { return }
                let t = v.trimmingCharacters(in: .whitespaces)
                waypoints[j].name = t.isEmpty ? nil : v
                dirty = true   // le nom est sauvegardé sans re-router.
            }
        )
    }

    // Nomme les POI/arrêts sans nom via OpenStreetMap : cols/sommets proches (Overpass, 1 requête) puis ville (Nominatim).
    // Les points de routage muets (`.shaping`) ne sont pas nommés.
    private func nameWaypoints() async {
        let targets = waypoints.filter { $0.role != .shaping && ($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !targets.isEmpty else { return }
        let coords = targets.map { coord($0) }
        let passes = await OSMNaming.passes(near: coords)
        for wp in targets {
            let c = coord(wp)
            var label = OSMNaming.nearestName(passes, to: c, within: 700)
            if label == nil {
                label = await OSMNaming.place(c)
                try? await Task.sleep(nanoseconds: 1_100_000_000) // Nominatim : 1 requête/s.
            }
            if let label, let j = waypoints.firstIndex(where: { $0.id == wp.id }),
               (waypoints[j].name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                waypoints[j].name = label
                dirty = true
            }
        }
    }

    private func invalidateAll() {
        segments = Array(repeating: nil, count: max(0, waypoints.count - 1))
        dirty = true
    }

    // Remet à nil les segments adjacents à l'index `k` (les seuls touchés par un déplacement).
    private func touch(_ k: Int) {
        if k - 1 >= 0, k - 1 < segments.count { segments[k - 1] = nil }
        if k >= 0, k < segments.count { segments[k] = nil }
    }

    private func moveWaypoint(id: UUID, to c: CLLocationCoordinate2D) {
        guard !busy, let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[i].latitude = c.latitude
        waypoints[i].longitude = c.longitude
        touch(i)
        dirty = true
    }

    private func addWaypoint(at c: CLLocationCoordinate2D) {
        guard !busy else { return }
        let wp = RouteWaypoint(latitude: c.latitude, longitude: c.longitude)
        var p = waypoints.count
        if waypoints.count >= 2 {
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
        // Mise à jour structurelle des segments : on ne recalcule que ce qui est neuf.
        if waypoints.count == 2 { segments = [nil] }
        else if p == 0 { segments.insert(nil, at: 0) }
        else if p >= waypoints.count - 1 { segments.append(nil) }
        else { segments.replaceSubrange((p - 1)...(p - 1), with: [nil, nil]) } // un segment scindé en deux.
        selectedWaypointId = wp.id
        dirty = true
    }

    private func delete(_ id: UUID) {
        guard !busy, let k = waypoints.firstIndex(where: { $0.id == id }), waypoints.count > 2 else { return }
        // Les deux segments autour du point fusionnent en un seul (à recalculer).
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

    private func reroute() {
        guard waypoints.count >= 2, !busy, hasPending else { return }
        isRouting = true
        Task {
            await routeMissing()
            isRouting = false
            dirty = true
            await nameWaypoints()
        }
    }

    // Route uniquement les segments à nil (les bornes modifiées) ; les autres restent en cache.
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

    private func saveNow() {
        guard waypoints.count >= 2, !busy else { return }
        dirty = false
        isSaving = true
        Task {
            if hasPending { isRouting = true; await routeMissing(); isRouting = false } // compléter les segments manquants.
            await nameWaypoints()
            let snapshot = waypoints
            let coords = displayCoords
            let ok = await AppServices.shared.applyRouteWaypoints(activityId: activity.id, waypoints: snapshot, routedCoords: coords)
            isSaving = false
            if ok { onSaved() }
        }
    }
    private func saveIfNeeded() {
        guard dirty, waypoints.count >= 2 else { return }
        saveNow()
    }

    private func load() async {
        waypoints = await AppServices.shared.initialWaypoints(activityId: activity.id)
        // Attribue le tracé existant à chaque segment (par point le plus proche) pour n'avoir à recalculer
        // que les bornes modifiées ensuite.
        if let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data), pts.count >= 2 {
            let track = pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            segments = Self.splitTrack(track, waypoints: waypoints)
        } else {
            segments = Array(repeating: nil, count: max(0, waypoints.count - 1))
        }
        isLoading = false
    }

    // Découpe un tracé continu en sous-tracés par paire de points (index le plus proche, monotone).
    private static func splitTrack(_ track: [CLLocationCoordinate2D], waypoints: [RouteWaypoint]) -> [[CLLocationCoordinate2D]?] {
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
            idx[j] = best
            start = best
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
