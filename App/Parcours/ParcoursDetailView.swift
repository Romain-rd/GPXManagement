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

/// Aperçu d'un parcours en étapes (volet central, façon Raid) : carte, profil avec jonctions déplaçables,
/// liste des étapes. Sélectionner une étape ouvre sa fiche dans le volet de droite.
/// Outil actif de l'éditeur de parcours unifié. `.route` (re-tracer) n'est disponible que pour un parcours modifiable.
enum ParcoursTool: Hashable { case select, poi, stageStop, route }

struct ParcoursDetailView: View {
    let activity: ActivitySummary
    let listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    @Bindable var navigation: AppNavigationModel
    /// En fenêtre autonome (pas de 3ᵉ colonne) : l'inspecteur d'étape s'affiche en panneau flottant interne.
    var showsInlineInspector: Bool = false
    @Environment(\.openWindow) private var openWindow

    /// Au-delà : tracé dense (GR importé) → non éditable par ancrages (gel + dégradation). Voir load().
    private static let maxRouteEditablePoints = 1500
    /// Id stable du repère d'aperçu de recherche (déplaçable, non encore dans le tracé).
    private static let searchPreviewId = UUID()

    @State private var tool: ParcoursTool = .select
    @State private var initialToolSet = false
    @State private var showEditableRouteDialog = false
    @AppStorage("parcoursInspectorWidth") private var inspectorWidth: Double = 360
    @State private var routeModel: RouteEditingModel
    @State private var hasStoredWaypoints = false
    @State private var placeSearch = PlaceSearchModel()
    @State private var searchResult: (name: String, coordinate: CLLocationCoordinate2D)?
    @FocusState private var searchFocused: Bool

    init(activity: ActivitySummary, listVM: ActivityListViewModel, repository: CoreDataActivityRepository,
         navigation: AppNavigationModel, showsInlineInspector: Bool = false) {
        self.activity = activity
        self.listVM = listVM
        self.repository = repository
        self.navigation = navigation
        self.showsInlineInspector = showsInlineInspector
        _routeModel = State(initialValue: RouteEditingModel(repository: repository))
    }

    @State private var points: [TrackPoint] = []
    @State private var dists: [Double] = []
    @State private var alts: [Double] = []
    @State private var cumGain: [Double] = []
    @State private var stages: [Stage] = []
    // Waypoints non-stop (POI + ancrages shaping) ; seuls les POI sont édités ici (mode fidèle : pas de re-routage).
    @State private var extraWaypoints: [RouteWaypoint] = []
    @State private var selectedPoiId: UUID?
    @State private var isLoading = true
    @State private var grabbed: Int?
    @State private var dragCoord: CLLocationCoordinate2D?
    @State private var zoomSpanKm: Double?
    @State private var centerKm: Double = 0
    @AppStorage("mapLayerParcours") private var layerRaw = MapLayer.ignScan25.rawValue
    @AppStorage("parcoursMapHeight") private var mapHeight: Double = 240
    @AppStorage("parcoursProfileHeight") private var profileHeight: Double = 150
    @State private var resizeAccum: CGFloat = 0
    @State private var showAddDialog = false
    @State private var renamingStageId: UUID?
    @State private var renameText = ""
    @AppStorage("parcoursAddKm") private var addKmRaw = "10"
    @AppStorage("parcoursAddGainMax") private var addGainRaw = ""

    private var layerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer.base(fromRawValue: layerRaw) }, set: { layerRaw = $0.rawValue })
    }

    private var coords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    private var junctions: [Int] { stages.count > 1 ? stages.dropLast().map { $0.endIndex } : [] }
    private var totalDistance: Double { dists.last ?? 0 }
    private var totalKm: Double { totalDistance / 1000 }

    // Points complets d'une étape (raccord départ + tracé + raccord arrivée) — base unique pour distance et D+,
    // identique au calcul de la fiche, pour que liste et profil affichent la même chose.
    private func stagePoints(_ s: Stage) -> [TrackPoint] {
        guard !points.isEmpty else { return [] }
        let lo = max(0, min(s.startIndex, points.count - 1))
        let hi = max(lo, min(s.endIndex, points.count - 1))
        return s.startConnectorPoints + Array(points[lo...hi]) + s.endConnectorPoints
    }
    private func stageKm(_ s: Stage) -> Double { ActivityStatsCalculator.compute(points: stagePoints(s)).distance / 1000 }
    private func stageGain(_ s: Stage) -> Int { Int(ActivityStatsCalculator.compute(points: stagePoints(s)).elevationGain.rounded()) }
    private var totalKmWithConnectors: Double { stages.reduce(0) { $0 + stageKm($1) } }
    private var totalGainWithConnectors: Int { stages.reduce(0) { $0 + stageGain($1) } }

    private static let stageDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEE d MMM"; return f
    }()
    private var baseDate: Date? { stages.first?.plannedDate }

    /// Date la 1ʳᵉ étape à `d` puis une étape par jour.
    private func setBaseDate(_ d: Date) {
        let start = Calendar.current.startOfDay(for: d)
        for k in stages.indices { stages[k].plannedDate = Calendar.current.date(byAdding: .day, value: k, to: start) }
        persist()
    }
    private func clearDates() {
        for k in stages.indices { stages[k].plannedDate = nil }
        persist()
    }

    /// Supprime une étape en absorbant sa portion dans une étape voisine (la partition reste continue).
    private func deleteStage(at k: Int) {
        guard stages.count > 1, stages.indices.contains(k) else { return }
        if navigation.selectedStageId == stages[k].id { navigation.selectedStageId = nil }
        if k > 0 {
            stages[k - 1].endIndex = stages[k].endIndex
            stages[k - 1].endOffTrackLatitude = stages[k].endOffTrackLatitude
            stages[k - 1].endOffTrackLongitude = stages[k].endOffTrackLongitude
            stages[k - 1].endConnectorData = stages[k].endConnectorData
        } else {
            stages[k + 1].startIndex = stages[k].startIndex
            stages[k + 1].startConnectorData = stages[k].startConnectorData
        }
        stages.remove(at: k)
        if baseDate != nil, let d = stages.first?.plannedDate { setBaseDate(d) } else { persist() }
    }
    private var visibleDomain: ClosedRange<Double> {
        guard let span = zoomSpanKm, span < totalKm else { return 0...max(totalKm, 0.001) }
        let half = span / 2
        let c = min(max(centerKm, half), totalKm - half)
        return (c - half)...(c + half)
    }

    private struct PlotPoint: Identifiable { let id: Int; let km: Double; let alt: Double }
    private var plot: [PlotPoint] {
        guard !points.isEmpty else { return [] }
        let step = max(1, points.count / 700)
        var r: [PlotPoint] = []
        var i = 0
        while i < points.count { r.append(PlotPoint(id: i, km: dists[i] / 1000, alt: alts[i])); i += step }
        let last = points.count - 1
        if r.last?.id != last { r.append(PlotPoint(id: last, km: dists[last] / 1000, alt: alts[last])) }
        return r
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        toolPalette
                        // Parcours modifiable : UNE carte d'itinéraire pour TOUS les outils (✚ ajoute un point de
                        // route, 📍 un POI, 🚩 un arrêt d'étape, 🖐 sélectionne) — pas de bascule de carte.
                        // Parcours fidèle : carte d'annotation (tracé verrouillé).
                        if activity.isEditableRoute {
                            routeMap.frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                            resizeHandle($mapHeight, min: 200, max: 900)
                            if !routeModel.waypoints.isEmpty { pointsList }
                        } else {
                            overviewMap.frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                            resizeHandle($mapHeight, min: 140, max: 700)
                        }
                        // Profil + dates : nécessitent le tracé enrichi (altitude) → sur le tracé sauvegardé.
                        if !points.isEmpty {
                            dateBar
                            zoomBar
                            profileChart.frame(height: profileHeight)
                            resizeHandle($profileHeight, min: 90, max: 500)
                        }
                        // Détail des étapes : EN DIRECT en mode modifiable (dès qu'un itinéraire existe, sans
                        // enregistrer) ; sur le tracé sauvegardé en mode fidèle.
                        if activity.isEditableRoute {
                            if routeModel.waypoints.count >= 2 { parcoursOutline }
                        } else if !points.isEmpty {
                            parcoursOutline
                            actions
                        }
                    }
                    .padding()
                }
            }
        }
        .slideOverInspector(width: $inspectorWidth,
                            isPresented: showsInlineInspector && navigation.selectedStageId != nil && navigation.showStageInspector) {
            if let stageId = navigation.selectedStageId {
                StageDetailView(activity: activity, stageId: stageId, repository: repository)
            }
        }
        .navigationTitle(activity.title)
        .task(id: activity.id) { await load() }
        .task(id: AppServices.shared.libraryRevision) {
            guard !points.isEmpty, grabbed == nil else { return }
            let loaded = ((try? await repository.fetchStagesResolved(activityId: activity.id, points: points)) ?? []).sorted { $0.order < $1.order }
            if !loaded.isEmpty { stages = loaded }
        }
        .alert("Ajouter une étape", isPresented: $showAddDialog) {
            TextField("Distance (km)", text: $addKmRaw)
            TextField("D+ max (m, optionnel)", text: $addGainRaw)
            Button("Ajouter") { addStageWithLimits() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Coupe la dernière étape à la distance indiquée, ou plus tôt si le D+ max est atteint.")
        }
        .alert("Renommer l'étape", isPresented: Binding(get: { renamingStageId != nil }, set: { if !$0 { renamingStageId = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") { applyRename() }
            Button("Annuler", role: .cancel) { renamingStageId = nil }
        }
        .alert(activity.isEditableRoute ? "Verrouiller le tracé ?" : "Rendre le tracé modifiable ?", isPresented: $showEditableRouteDialog) {
            Button(activity.isEditableRoute ? "Verrouiller" : "Rendre modifiable") {
                let newValue = !activity.isEditableRoute
                Task {
                    await listVM.setEditableRoute(id: activity.id, newValue)
                    if newValue {
                        await routeModel.load(activityId: activity.id)
                        tool = .route
                    } else {
                        tool = .select
                        await load()
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(activity.isEditableRoute
                 ? "Le re-routage entre points de passage sera désactivé : le tracé restera fidèle (recommandé pour un GR importé). Les arrêts et POI restent éditables."
                 : "Tu pourras re-router l'itinéraire entre les points de passage. ⚠️ Sur un tracé précis (GR importé), le re-routage peut le dégrader — à n'activer que pour un parcours dessiné.")
        }
    }

    private func applyRename() {
        guard let id = renamingStageId, let k = stages.firstIndex(where: { $0.id == id }) else { return }
        stages[k].name = renameText.trimmingCharacters(in: .whitespaces)
        renamingStageId = nil
        persist()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(activity.title).font(.title2.bold())
            Text(String(format: "%.0f km · +%d m · %d étape(s)", totalKmWithConnectors,
                        totalGainWithConnectors, stages.count))
                .foregroundStyle(.secondary)
        }
    }

    private var toolPalette: some View {
        Group {
            if activity.isEditableRoute {
                // Barre adaptative : une ligne si la largeur suffit, sinon deux lignes (écran étroit).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        toolsGroup; Divider().frame(height: 18); lockButton; Divider().frame(height: 18)
                        searchField; enginePicker; recalcButton; fitButton
                        Spacer(); pointCount; saveButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) { toolsGroup; Divider().frame(height: 18); lockButton; Spacer(); pointCount; saveButton }
                        HStack(spacing: 8) { searchField; enginePicker; recalcButton; fitButton; Spacer() }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    toolsGroup; Divider().frame(height: 18); lockButton
                    Spacer()
                    Text(toolHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var toolsGroup: some View {
        HStack(spacing: 2) {
            toolButton(.select, "hand.point.up.left", "Sélection / déplacement")
            toolButton(.poi, "mappin", "Poser un point d'intérêt (aimanté à la trace)")
            toolButton(.stageStop, "flag.checkered", "Poser une fin d'étape (aimantée à la trace)")
            if activity.isEditableRoute {
                toolButton(.route, "point.topleft.down.to.point.bottomright.curvepath", "Re-tracer l'itinéraire (routage)")
            }
        }
    }

    @ViewBuilder private var lockButton: some View {
        if activity.isEditableRoute {
            Button { showEditableRouteDialog = true } label: { Image(systemName: "lock.open").frame(width: 30, height: 24) }
                .buttonStyle(.borderless).help("Verrouiller le tracé (fidèle)")
        } else {
            // Bloqué seulement si tracé dense ET aucun point de passage stocké (sinon pas de Douglas-Peucker → OK).
            let tooDense = points.count > Self.maxRouteEditablePoints && !hasStoredWaypoints
            Button { showEditableRouteDialog = true } label: { Label("Rendre modifiable", systemImage: "lock").font(.callout) }
                .buttonStyle(.borderless).disabled(tooDense)
                .help(tooDense
                      ? "Tracé trop dense (\(points.count) points) pour l'édition d'itinéraire — l'édition légère d'un GR viendra plus tard. Les arrêts et POI restent éditables."
                      : "Débloquer le re-tracé de l'itinéraire entre points de passage")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher un lieu…", text: $placeSearch.query)
                .textFieldStyle(.plain).frame(minWidth: 110)
                .focused($searchFocused)
                .onChange(of: placeSearch.query) { placeSearch.bias(to: routeModel.proxy.mapView?.region) }
                .onSubmit { if let first = placeSearch.suggestions.first { pick(first) } }
            if !placeSearch.query.isEmpty {
                Button { placeSearch.clear(); searchResult = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .popover(isPresented: Binding(get: { searchFocused && !placeSearch.suggestions.isEmpty },
                                      set: { if !$0 { searchFocused = false } }), arrowEdge: .bottom) {
            suggestionsList
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(placeSearch.suggestions.prefix(8).enumerated()), id: \.offset) { _, s in
                Button { pick(s) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).fontWeight(.medium)
                        if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
            }
        }
        .frame(width: 280).padding(.vertical, 4)
    }

    /// Choix d'une suggestion : pose le résultat sur la carte (repère + recentrage) pour pouvoir y poser un point.
    private func pick(_ completion: MKLocalSearchCompletion) {
        Task {
            guard let r = await placeSearch.resolve(completion) else { return }
            searchResult = r
            placeSearch.suggestions = []
            placeSearch.query = r.name
            searchFocused = false
            routeModel.proxy.mapView?.setRegion(MKCoordinateRegion(center: r.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000), animated: true)
        }
    }

    /// Ajoute le lieu trouvé comme point de passage (rôle selon l'outil actif, POI par défaut).
    private func addSearchResult() {
        guard let r = searchResult else { return }
        routeModel.addWaypoint(at: r.coordinate, role: roleForTool ?? .poi)
        searchResult = nil
        placeSearch.clear()
    }

    private var enginePicker: some View {
        Picker("Profil", selection: Binding(
            get: { routeModel.profileRaw },
            set: { routeModel.profileRaw = $0; UserDefaults.standard.set($0, forKey: "routeProfile"); routeModel.invalidateAll() }
        )) {
            ForEach(RouteProfile.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        .help("Profil de déplacement. Le fournisseur de routage se choisit dans Réglages › Itinéraire.")
    }

    private var recalcButton: some View {
        Button { routeModel.reroute() } label: { Image(systemName: "arrow.triangle.turn.up.right.diamond") }
            .help("Recalculer l'itinéraire").disabled(routeModel.busy || routeModel.waypoints.count < 2 || !routeModel.hasPending)
    }
    private var fitButton: some View {
        Button { routeModel.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .help("Cadrer le parcours").disabled(routeModel.waypoints.isEmpty)
    }
    private var pointCount: some View {
        Text("\(routeModel.waypoints.count) pt").font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    private var saveButton: some View {
        Button { routeModel.save(activityId: activity.id) { Task { await load() } } } label: { Label("Enregistrer", systemImage: "checkmark") }
            .buttonStyle(.borderedProminent).controlSize(.small).disabled(routeModel.waypoints.count < 2 || routeModel.busy)
    }

    private func toolButton(_ t: ParcoursTool, _ icon: String, _ help: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: icon)
                .frame(width: 30, height: 24)
                .background(tool == t ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var toolHint: String {
        switch tool {
        case .select: return "Glissez un POI, un drapeau d'étape ou une jonction."
        case .poi: return "Cliquez sur la trace pour poser un point d'intérêt."
        case .stageStop: return "Cliquez sur la trace pour couper une étape."
        case .route: return "Re-tracé de l'itinéraire."
        }
    }

    private var overviewMap: some View {
        StageColoredMap(activityId: activity.id, activityType: activity.activityType, coords: coords, stages: stages,
                        highlight: dragCoord, waypoints: poiMarkers + boundaryMarkers,
                        onWaypointMoved: { id, c in moveMarker(id: id, to: c) },
                        onWaypointTapped: { tapMarker($0) },
                        onMapClick: tool == .poi || tool == .stageStop ? { mapClick(at: $0) } : nil,
                        layer: layerBinding)
    }

    /// Rôle du point ajouté au clic selon l'outil actif (sélection = pas d'ajout).
    private var roleForTool: RouteWaypoint.Role? {
        switch tool {
        case .route: return .shaping
        case .poi: return .poi
        case .stageStop: return .stageStop
        case .select: return nil
        }
    }

    /// Repère d'aperçu déplaçable du résultat de recherche (ajustement de l'emplacement avant la pose).
    private var searchPreviewMarkers: [WaypointMarker] {
        guard let r = searchResult else { return [] }
        return [WaypointMarker(id: Self.searchPreviewId, coordinate: r.coordinate, index: -1, role: .poi, name: r.name, isPreview: true)]
    }

    /// Carte unique d'un parcours modifiable : tracé routé + points de passage typés, clic = ajouter (selon l'outil).
    private var routeMap: some View {
        StageColoredMap(activityId: activity.id, activityType: activity.activityType,
                        coords: routeModel.displayCoords, waypoints: routeModel.markers + searchPreviewMarkers,
                        onWaypointMoved: { id, c in
                            if id == Self.searchPreviewId { searchResult = (searchResult?.name ?? "", c) }
                            else { routeModel.moveWaypoint(id: id, to: c); routeModel.reroute() }
                        },
                        onWaypointTapped: { routeModel.selectedWaypointId = ($0 == routeModel.selectedWaypointId ? nil : $0) },
                        onMapClick: roleForTool.map { role in { c in routeModel.addWaypoint(at: c, role: role) } },
                        proxy: routeModel.proxy, layer: layerBinding)
            .overlay(alignment: .top) {
                if let r = searchResult {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                        Text(r.name).lineLimit(1)
                        Text("· glisse le repère pour ajuster").foregroundStyle(.secondary)
                        Button("Ajouter ce point") { addSearchResult() }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(routeModel.busy)
                        Button { searchResult = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule()).padding(8)
                } else if routeModel.waypoints.isEmpty {
                    Label("Cliquez sur la carte pour poser le premier point", systemImage: "hand.tap")
                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule()).padding(8)
                }
            }
            .overlay(alignment: .bottom) {
                if routeModel.isRouting {
                    VStack(spacing: 4) {
                        Text("Routage \(routeModel.routeDone)/\(routeModel.routeTotal)…").font(.caption)
                        ProgressView(value: Double(routeModel.routeDone), total: Double(max(routeModel.routeTotal, 1)))
                    }
                    .frame(width: 240).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                } else if routeModel.isSaving {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Calcul de l'altitude…").font(.caption) }
                        .padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                } else if routeModel.routedWithFallback {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("MapKit saturé : un segment a été routé en repli (route approximative).").font(.caption)
                        Button("Recalculer") { routeModel.invalidateAll(); routeModel.reroute() }
                            .controlSize(.small).disabled(routeModel.busy)
                    }
                    .padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                }
            }
    }

    /// Drapeaux des fins d'étape internes (déplaçables sur la carte avec l'outil sélection).
    private var boundaryMarkers: [WaypointMarker] {
        guard stages.count > 1, !points.isEmpty else { return [] }
        return stages.dropLast().enumerated().map { i, s in
            let idx = min(max(s.endIndex, 0), points.count - 1)
            return WaypointMarker(id: s.id, coordinate: CLLocationCoordinate2D(latitude: points[idx].latitude, longitude: points[idx].longitude),
                                  index: i, role: .stageStop, name: s.name)
        }
    }

    private func mapClick(at c: CLLocationCoordinate2D) {
        switch tool {
        case .poi: addPOI(at: c)
        case .stageStop: addStageStop(at: c)
        default: break
        }
    }

    private func moveMarker(id: UUID, to c: CLLocationCoordinate2D) {
        if extraWaypoints.contains(where: { $0.id == id }) { movePOI(id: id, to: c) }
        else { moveBoundary(stageId: id, to: c) }
    }

    private func tapMarker(_ id: UUID) {
        if extraWaypoints.contains(where: { $0.id == id }) { selectedPoiId = (id == selectedPoiId ? nil : id) }
        else { navigation.selectedStageId = id; navigation.showStageInspector = true }
    }

    /// Pose une fin d'étape au point de tracé cliqué : coupe en deux l'étape qui le contient.
    private func addStageStop(at c: CLLocationCoordinate2D) {
        guard !points.isEmpty else { return }
        let idx = RouteWaypoint.nearestIndex(latitude: c.latitude, longitude: c.longitude, in: points)
        guard let k = stages.firstIndex(where: { idx > $0.startIndex && idx < $0.endIndex }) else { return }
        let s = stages[k]
        let first = Stage(id: s.id, activityId: activity.id, order: 0, name: s.name, notes: s.notes, startIndex: s.startIndex, endIndex: idx)
        let second = Stage(activityId: activity.id, order: 0, name: "", startIndex: idx, endIndex: s.endIndex)
        stages.replaceSubrange(k...k, with: [first, second])
        persist()
    }

    /// Déplace une jonction d'étape (fin de l'étape k = début de k+1) au point de tracé le plus proche.
    private func moveBoundary(stageId: UUID, to c: CLLocationCoordinate2D) {
        guard let k = stages.firstIndex(where: { $0.id == stageId }), k < stages.count - 1, !points.isEmpty else { return }
        let idx = RouteWaypoint.nearestIndex(latitude: c.latitude, longitude: c.longitude, in: points)
        let clamped = min(max(idx, stages[k].startIndex + 1), stages[k + 1].endIndex - 1)
        stages[k].endIndex = clamped
        stages[k + 1].startIndex = clamped
        persist()
    }

    private var profileChart: some View {
        Chart {
            ForEach(plot) { p in AreaMark(x: .value("km", p.km), y: .value("alt", p.alt)).foregroundStyle(.blue.opacity(0.15)) }
            ForEach(plot) { p in LineMark(x: .value("km", p.km), y: .value("alt", p.alt)).foregroundStyle(.blue) }
            ForEach(Array(junctions.enumerated()), id: \.element) { _, j in
                RuleMark(x: .value("km", dists[j] / 1000)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXScale(domain: visibleDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in onDrag(start: v.startLocation, current: v.location, proxy: proxy, geo: geo) }
                        .onEnded { _ in grabbed = nil; dragCoord = nil; persist() })
            }
        }
    }

    private func resizeHandle(_ height: Binding<Double>, min lo: Double, max hi: Double) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let dy = v.translation.height
                        height.wrappedValue = Swift.min(hi, Swift.max(lo, height.wrappedValue + Double(dy - resizeAccum)))
                        resizeAccum = dy
                    }
                    .onEnded { _ in resizeAccum = 0 }
            )
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Glisser pour ajuster la hauteur")
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right.text.vertical").foregroundStyle(.secondary).font(.caption)
            Button { zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
            Button { pan(-0.4) } label: { Image(systemName: "chevron.left") }.disabled(zoomSpanKm == nil)
            Button { pan(0.4) } label: { Image(systemName: "chevron.right") }.disabled(zoomSpanKm == nil)
            if zoomSpanKm != nil {
                Button("Tout") { zoomSpanKm = nil }
                Text(String(format: "%.1f–%.1f km", visibleDomain.lowerBound, visibleDomain.upperBound))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func zoomIn() {
        if zoomSpanKm == nil { centerKm = totalKm / 2 }
        zoomSpanKm = max((zoomSpanKm ?? totalKm) / 2, 0.5)
    }
    private func zoomOut() {
        let next = (zoomSpanKm ?? totalKm) * 2
        zoomSpanKm = next >= totalKm ? nil : next
    }
    private func pan(_ fraction: Double) {
        guard let span = zoomSpanKm else { return }
        centerKm = min(max(centerKm + span * fraction, span / 2), totalKm - span / 2)
    }

    private func onDrag(start: CGPoint, current: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard stages.count > 1, let plotFrame = proxy.plotFrame else { return }
        let rect = geo[plotFrame]
        func meters(atX x: CGFloat) -> Double? {
            let xIn = min(max(x - rect.origin.x, 0), rect.width)
            guard let km: Double = proxy.value(atX: xIn, as: Double.self) else { return nil }
            return km * 1000
        }
        if grabbed == nil {
            guard let startM = meters(atX: start.x) else { return }
            var best = 0; var bestDiff = Double.greatestFiniteMagnitude
            for k in 0..<(stages.count - 1) {
                let diff = abs(dists[stages[k].endIndex] - startM)
                if diff < bestDiff { bestDiff = diff; best = k }
            }
            guard bestDiff < totalDistance * 0.06 else { return }
            grabbed = best
        }
        guard let k = grabbed, let targetM = meters(atX: current.x) else { return }
        var idx = nearestPointIndex(toMeters: targetM)
        let lower = stages[k].startIndex + 1
        let upper = stages[k + 1].endIndex - 1
        guard lower <= upper else { return }
        idx = min(max(idx, lower), upper)
        stages[k].endIndex = idx
        stages[k + 1].startIndex = idx
        if coords.indices.contains(idx) { dragCoord = coords[idx] }
    }

    /// Écart hors-trace d'une étape (raccords départ + arrivée), pour l'afficher dans la liste.
    private func offTrackExtra(_ s: Stage) -> String? {
        let dep = ActivityStatsCalculator.compute(points: s.startConnectorPoints)
        let arr = ActivityStatsCalculator.compute(points: s.endConnectorPoints)
        let km = (dep.distance + arr.distance) / 1000
        let gain = Int((dep.elevationGain + arr.elevationGain).rounded())
        guard km > 0.05 || gain > 0 else { return nil }
        return String(format: "↗ hors-trace +%.1f km · +%d m", km, gain)
    }

    @ViewBuilder private var dateBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            if let d = baseDate {
                DatePicker("Départ le", selection: Binding(get: { d }, set: { setBaseDate($0) }), displayedComponents: .date)
                    .fixedSize()
                Button("Retirer les dates", role: .destructive) { clearDates() }.controlSize(.small)
            } else {
                Button("Dater le parcours…") { setBaseDate(Date()) }.controlSize(.small)
                Text("une étape par jour à partir de la date de départ").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var actions: some View {
        HStack {
            Button { showAddDialog = true } label: { Label("Ajouter une étape", systemImage: "plus") }
            Menu {
                Button("Tous les 10 km") { recalcByDistance(10_000) }
                Button("Tous les 20 km") { recalcByDistance(20_000) }
                Button("Tous les 500 m D+") { recalcByGain(500) }
                Button("Tous les 1000 m D+") { recalcByGain(1_000) }
            } label: { Label("Recalculer", systemImage: "wand.and.stars") }
            Spacer()
        }
    }

    // MARK: Liste des points (mode modifiable : ordre éditable)

    /// Tous les points dans l'ordre : numéro, rôle (cliquer pour changer), nom, suppression, glisser pour réordonner.
    private var pointsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Points · glisser pour réordonner, cliquer la pastille pour changer le rôle")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(routeModel.waypoints.enumerated()), id: \.element.id) { i, wp in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(routeModel.selectedWaypointId == wp.id ? Color.accentColor : pointColor(wp.role)))
                        Button { routeModel.cycleRole(wp.id) } label: { pointRoleIcon(wp.role) }
                            .buttonStyle(.borderless).help("Rôle : point de tracé · POI · arrêt d'étape")
                        TextField(wp.role == .shaping ? "Point de tracé" : "Nom",
                                  text: Binding(get: { routeModel.name(for: wp.id) }, set: { routeModel.setName($0, for: wp.id) }))
                            .textFieldStyle(.plain).font(.caption)
                        Spacer(minLength: 4)
                        Button { routeModel.delete(wp.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(routeModel.waypoints.count <= 2)
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                }
                .onMove { routeModel.moveWaypoints(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .frame(height: min(Double(routeModel.waypoints.count) * 30 + 8, 220))
        }
    }

    private func pointColor(_ role: RouteWaypoint.Role) -> Color {
        switch role { case .shaping: return .gray; case .poi: return .orange; case .stageStop: return .green }
    }
    @ViewBuilder private func pointRoleIcon(_ role: RouteWaypoint.Role) -> some View {
        switch role {
        case .shaping: Image(systemName: "smallcircle.filled.circle").foregroundStyle(.secondary)
        case .poi: Image(systemName: "mappin.circle.fill").foregroundStyle(.orange)
        case .stageStop: Image(systemName: "flag.circle.fill").foregroundStyle(.green)
        }
    }

    // MARK: Liste unique « Le long du parcours »

    private struct OutlineItem: Identifiable {
        enum Kind { case departure, poi, stageHeader, stop, arrival }
        let id: String
        let kind: Kind
        var number = 0
        var stats: String?
        var date: String?
        var offTrack: String?
        var stageId: UUID?       // étape sauvegardée (fiche, renommage, suppression)
        var poiId: UUID?         // POI sauvegardé (extraWaypoints)
        var wpId: UUID?          // waypoint vivant (routeModel) en mode modifiable
        var live = false
    }

    /// Source de la liste : vivante (routeModel) en modifiable, sauvegardée (stages + POI) en fidèle.
    private var outlineItems: [OutlineItem] { activity.isEditableRoute ? liveOutlineItems : savedOutlineItems }

    /// Mode fidèle : liste sauvegardée, ordonnée le long du tracé (étapes `stages` + POI `extraWaypoints`).
    private var savedOutlineItems: [OutlineItem] {
        guard !stages.isEmpty, !points.isEmpty else { return [] }
        let pois = extraWaypoints.filter { $0.role == .poi }
        func idx(_ w: RouteWaypoint) -> Int { RouteWaypoint.nearestIndex(latitude: w.latitude, longitude: w.longitude, in: points) }
        var items: [OutlineItem] = [OutlineItem(id: "start", kind: .departure)]
        for (k, s) in stages.enumerated() {
            for w in pois where idx(w) > s.startIndex && idx(w) <= s.endIndex {
                items.append(OutlineItem(id: "poi-\(w.id)", kind: .poi, poiId: w.id))
            }
            items.append(OutlineItem(id: "stage-\(s.id)", kind: .stageHeader, number: k + 1,
                                     stats: String(format: "%.1f km · +%d m", stageKm(s), stageGain(s)),
                                     date: s.plannedDate.map { Self.stageDateFormatter.string(from: $0) },
                                     offTrack: offTrackExtra(s), stageId: s.id))
            items.append(OutlineItem(id: "stop-\(s.id)", kind: k == stages.count - 1 ? .arrival : .stop, stageId: s.id))
        }
        return items
    }

    /// Mode modifiable : liste VIVANTE dérivée de `routeModel.waypoints` (arrêts `.stageStop` + extrémités, POI,
    /// étapes = intervalles entre arrêts). km en direct ; D+/date/notes repris de l'étape sauvegardée (par stopId).
    private var liveOutlineItems: [OutlineItem] {
        let wps = routeModel.waypoints
        guard wps.count >= 2 else { return [] }
        var stopPos: [Int] = [0]
        for i in 1..<(wps.count - 1) where wps[i].role == .stageStop { stopPos.append(i) }
        stopPos.append(wps.count - 1)
        let savedByStop = Dictionary(stages.compactMap { s in s.stopWaypointId.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        var items: [OutlineItem] = [OutlineItem(id: "lstart", kind: .departure, live: true)]
        for e in 1..<stopPos.count {
            let from = stopPos[e - 1], to = stopPos[e]
            for i in (from + 1)..<to where wps[i].role == .poi {
                items.append(OutlineItem(id: "lpoi-\(wps[i].id)", kind: .poi, poiId: wps[i].id, wpId: wps[i].id, live: true))
            }
            let stop = wps[to]
            let saved = savedByStop[stop.id]
            let dPlus = saved.map { String(format: " · +%d m", stageGain($0)) } ?? ""
            items.append(OutlineItem(id: "lstage-\(stop.id)", kind: .stageHeader, number: e,
                                     stats: String(format: "%.1f km", liveStageKm(from, to)) + dPlus,
                                     date: saved?.plannedDate.map { Self.stageDateFormatter.string(from: $0) },
                                     offTrack: saved.flatMap { offTrackExtra($0) }, stageId: saved?.id, live: true))
            items.append(OutlineItem(id: "lstop-\(stop.id)", kind: e == stopPos.count - 1 ? .arrival : .stop,
                                     stageId: saved?.id, wpId: stop.id, live: true))
        }
        return items
    }

    /// Distance (km) d'une étape vivante = somme des segments routés entre les deux arrêts (ligne droite à défaut).
    private func liveStageKm(_ from: Int, _ to: Int) -> Double {
        let wps = routeModel.waypoints
        var m = 0.0
        for i in from..<to {
            let seg = (i < routeModel.segments.count ? routeModel.segments[i] : nil)
            let pts = (seg?.count ?? 0) >= 2 ? seg! :
                [CLLocationCoordinate2D(latitude: wps[i].latitude, longitude: wps[i].longitude),
                 CLLocationCoordinate2D(latitude: wps[i + 1].latitude, longitude: wps[i + 1].longitude)]
            for j in 1..<pts.count {
                m += CLLocation(latitude: pts[j - 1].latitude, longitude: pts[j - 1].longitude)
                    .distance(from: CLLocation(latitude: pts[j].latitude, longitude: pts[j].longitude))
            }
        }
        return m / 1000
    }

    private var parcoursOutline: some View {
        VStack(spacing: 0) {
            ForEach(outlineItems) { item in
                outlineRow(item)
                if item.kind == .stageHeader || item.kind == .arrival { Divider() }
            }
        }
    }

    @ViewBuilder private func outlineRow(_ item: OutlineItem) -> some View {
        switch item.kind {
        case .departure:
            HStack(spacing: 8) {
                Image(systemName: "flag.fill").foregroundStyle(.green)
                Text("Départ").fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 6)
        case .poi:
            if let id = item.poiId {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.orange)
                    if item.live, let wp = item.wpId {
                        TextField("Point d'intérêt", text: Binding(get: { routeModel.name(for: wp) }, set: { routeModel.setName($0, for: wp) }))
                            .textFieldStyle(.plain).font(.caption)
                        Spacer(minLength: 4)
                        Button { routeModel.delete(wp) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(routeModel.busy)
                    } else {
                        TextField("Point d'intérêt", text: poiNameBinding(id), onCommit: { persist() })
                            .textFieldStyle(.plain).font(.caption)
                        Spacer(minLength: 4)
                        Button { deletePOI(id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 3).padding(.leading, 30).padding(.trailing, 6)
                .background((item.live ? routeModel.selectedWaypointId == item.wpId : selectedPoiId == id) ? Color.accentColor.opacity(0.12) : .clear)
            }
        case .stageHeader:
            HStack(spacing: 8) {
                Image(systemName: "\(min(item.number, 50)).circle.fill").foregroundStyle(.secondary)
                Text("Étape \(item.number)").fontWeight(.medium)
                if let stats = item.stats { Text(stats).font(.caption).foregroundStyle(.secondary) }
                if let off = item.offTrack { Text(off).font(.caption).foregroundStyle(.orange) }
                Spacer()
                if let date = item.date { Text(date).font(.caption).foregroundStyle(.blue) }
                if item.stageId != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { openStage(item.stageId) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let id = item.stageId { openWindow(value: StageWindowRef(activityId: activity.id, stageId: id)) }
            })
            .background(navigation.selectedStageId == item.stageId ? Color.accentColor.opacity(0.12) : .clear)
            .contextMenu {
                if !item.live, let id = item.stageId, let k = stages.firstIndex(where: { $0.id == id }) {
                    Button("Renommer l'étape…") { renameText = stages[k].name; renamingStageId = id }
                    Button("Supprimer l'étape", role: .destructive) { deleteStage(at: k) }.disabled(stages.count <= 1)
                }
            }
        case .stop, .arrival:
            HStack(spacing: 8) {
                Image(systemName: item.kind == .arrival ? "flag.checkered" : "flag.fill").foregroundStyle(.green)
                if item.live, let wp = item.wpId {
                    TextField(item.kind == .arrival ? "Arrivée" : "Arrêt",
                              text: Binding(get: { routeModel.name(for: wp) }, set: { routeModel.setName($0, for: wp) }))
                        .textFieldStyle(.plain).fontWeight(.semibold)
                    Spacer()
                    if item.kind == .stop {
                        Button { routeModel.delete(wp) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(routeModel.busy).help("Retirer cet arrêt (fusionne les étapes)")
                    }
                } else if let id = item.stageId, let k = stages.firstIndex(where: { $0.id == id }) {
                    TextField(item.kind == .arrival ? "Arrivée" : "Arrêt",
                              text: Binding(get: { stages[k].name }, set: { stages[k].name = $0 }), onCommit: { persist() })
                        .textFieldStyle(.plain).fontWeight(.semibold)
                    Spacer()
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if item.live { if let wp = item.wpId { routeModel.selectedWaypointId = (routeModel.selectedWaypointId == wp ? nil : wp) } }
                else { openStage(item.stageId) }
            }
        }
    }

    private func openStage(_ id: UUID?) {
        guard let id else { return }
        navigation.selectedStageId = id
        navigation.showStageInspector = true
    }

    // MARK: Édition

    /// Ajoute une étape en coupant la dernière : jusqu'à `km`, ou plus tôt si le `D+ max` est atteint.
    private func addStageWithLimits() {
        guard let last = stages.last else { return }
        let a = last.startIndex, b = last.endIndex
        let targetDist = (Double(addKmRaw.replacingOccurrences(of: ",", with: ".")) ?? 0) * 1000
        let targetGain = Double(addGainRaw.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard targetDist > 0 || targetGain > 0, b > a + 1 else { return }
        var cut = b
        for i in (a + 1)..<b {
            let distHit = targetDist > 0 && (dists[i] - dists[a] >= targetDist)
            let gainHit = targetGain > 0 && (cumGain[i] - cumGain[a] >= targetGain)
            if distHit || gainHit { cut = i; break }
        }
        guard cut > a, cut < b else { return } // le reste tient dans les limites → pas de découpe
        let first = Stage(id: last.id, activityId: activity.id, order: 0, name: last.name, notes: last.notes, startIndex: a, endIndex: cut)
        let second = Stage(activityId: activity.id, order: 0, name: "", startIndex: cut, endIndex: b)
        stages[stages.count - 1] = first
        stages.append(second)
        persist()
    }

    private func merge(at k: Int) {
        guard k > 0, k < stages.count else { return }
        if navigation.selectedStageId == stages[k].id { navigation.selectedStageId = nil }
        stages[k - 1].endIndex = stages[k].endIndex
        stages.remove(at: k)
        persist()
    }

    private func recalcByDistance(_ meters: Double) {
        rebuild(TrackSegmentBuilder.byDistance(points: points, every: meters))
    }
    private func recalcByGain(_ meters: Double) {
        rebuild(TrackSegmentBuilder.byElevationGain(points: points, every: meters))
    }
    private func rebuild(_ segments: [TrackSegment]) {
        guard !segments.isEmpty else { return }
        navigation.selectedStageId = nil
        stages = segments.enumerated().map { i, seg in
            Stage(activityId: activity.id, order: i, name: "Étape \(i + 1)", startIndex: seg.startIndex, endIndex: seg.endIndex)
        }
        persist()
    }

    private func persist() {
        for i in stages.indices { stages[i].order = i }
        let snapshot = stages
        let pts = points
        let pois = extraWaypoints
        Task {
            guard let updated = try? await repository.saveStagedRoute(activityId: activity.id, stages: snapshot, points: pts, pois: pois) else { return }
            await MainActor.run {
                // Réinjecte les stopWaypointId créés (stabilité des ids), sans écraser une édition en cours.
                guard grabbed == nil, updated.count == stages.count else { return }
                for i in stages.indices { stages[i].stopWaypointId = updated[i].stopWaypointId }
            }
        }
    }

    private func nearestPointIndex(toMeters meters: Double) -> Int {
        guard !dists.isEmpty else { return 0 }
        var lo = 0, hi = dists.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if dists[mid] < meters { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(dists[lo - 1] - meters) < abs(dists[lo] - meters) { return lo - 1 }
        return lo
    }

    private func load() async {
        defer { isLoading = false }
        let raw = try? await repository.fetchTrackData(id: activity.id)
        let decoded = raw.flatMap { try? TrackPointCodec.decode($0) } ?? []
        // À la PREMIÈRE ouverture : on charge le routage d'un parcours modifiable et on choisit l'outil
        // (✚ pour un parcours vide à dessiner, sinon sélection). Une seule fois (load() est rappelé au save).
        if !initialToolSet {
            initialToolSet = true
            // Un tracé importé dense (GR, plusieurs milliers de points) n'est PAS éditable par ancrages :
            // en dériver les points de passage (Douglas-Peucker sur tout le tracé) gèle l'app et dégraderait
            // la géométrie précise. On n'autorise l'édition d'itinéraire que si des points de passage sont déjà
            // stockés (parcours dessiné) ou si le tracé est assez court pour une dérivation instantanée.
            let storedWp = RouteWaypointCodec.decode(try? await repository.fetchRouteWaypointsData(id: activity.id))
            let canRouteEdit = !storedWp.isEmpty || decoded.count <= Self.maxRouteEditablePoints
            if activity.isEditableRoute && !canRouteEdit {
                await listVM.setEditableRoute(id: activity.id, false)   // repasse en fidèle (anti-gel)
                tool = .select
            } else {
                tool = (activity.isEditableRoute && decoded.count < 2) ? .route : .select
                if activity.isEditableRoute { await routeModel.load(activityId: activity.id) }
            }
        }
        guard decoded.count > 1 else {
            points = decoded
            return
        }
        let pts = decoded
        var d = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count { d[i] = d[i - 1] + GeoDistance.haversine(pts[i - 1], pts[i]) }
        var a = [Double](repeating: 0, count: pts.count)
        var last = pts.first(where: { $0.altitude != nil })?.altitude ?? 0
        for i in pts.indices { last = pts[i].altitude ?? last; a[i] = last }
        var sm = a
        for i in 1..<sm.count { sm[i] = 0.2 * a[i] + 0.8 * sm[i - 1] }
        var g = [Double](repeating: 0, count: pts.count)
        var anchor = sm[0]
        for i in 1..<pts.count {
            let delta = sm[i] - anchor; g[i] = g[i - 1]
            if delta >= 3 { g[i] += delta; anchor = sm[i] } else if delta <= -3 { anchor = sm[i] }
        }
        var loaded = (try? await repository.fetchStagesResolved(activityId: activity.id, points: pts)) ?? []
        loaded.sort { $0.order < $1.order }
        // Purge : doublons d'id + étapes « fantômes » (indices hors trace ou dégénérés).
        var seen = Set<UUID>()
        let cleaned = loaded.filter { seen.insert($0.id).inserted }
            .filter { $0.startIndex >= 0 && $0.endIndex < pts.count && $0.endIndex > $0.startIndex }
        if cleaned.count != loaded.count {
            let renumbered = cleaned.enumerated().map { i, s -> Stage in var v = s; v.order = i; return v }
            try? await repository.saveStagedRoute(activityId: activity.id, stages: renumbered, points: pts)
            loaded = renumbered
        } else {
            loaded = cleaned
        }
        if loaded.isEmpty { loaded = [Stage(activityId: activity.id, order: 0, name: "Étape 1", startIndex: 0, endIndex: pts.count - 1)] }
        let wps = RouteWaypointCodec.decode((try? await repository.fetchRouteWaypointsData(id: activity.id)) ?? nil)
        hasStoredWaypoints = !wps.isEmpty
        extraWaypoints = wps.filter { $0.role != .stageStop }
        points = pts; dists = d; alts = a; cumGain = g; stages = loaded
    }

    // MARK: POI sur la trace (mode fidèle : aimantés au tracé, jamais de re-routage)

    private var poiMarkers: [WaypointMarker] {
        extraWaypoints.enumerated().compactMap { _, w in
            w.role == .poi ? WaypointMarker(id: w.id, coordinate: CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude), index: 0, role: .poi, name: w.name) : nil
        }
    }

    /// Aimante une coordonnée au point du tracé le plus proche (le POI reste sur la trace).
    private func snapped(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard !points.isEmpty else { return c }
        let i = RouteWaypoint.nearestIndex(latitude: c.latitude, longitude: c.longitude, in: points)
        return CLLocationCoordinate2D(latitude: points[i].latitude, longitude: points[i].longitude)
    }

    private func addPOI(at c: CLLocationCoordinate2D) {
        let s = snapped(c)
        let wp = RouteWaypoint(latitude: s.latitude, longitude: s.longitude, name: nil, role: .poi)
        extraWaypoints.append(wp)
        selectedPoiId = wp.id
        tool = .select
        persist()
    }

    private func movePOI(id: UUID, to c: CLLocationCoordinate2D) {
        guard let j = extraWaypoints.firstIndex(where: { $0.id == id }) else { return }
        let s = snapped(c)
        extraWaypoints[j].latitude = s.latitude
        extraWaypoints[j].longitude = s.longitude
        persist()
    }

    private func deletePOI(_ id: UUID) {
        extraWaypoints.removeAll { $0.id == id }
        if selectedPoiId == id { selectedPoiId = nil }
        persist()
    }

    private func poiNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { extraWaypoints.first(where: { $0.id == id })?.name ?? "" },
            set: { v in
                guard let j = extraWaypoints.firstIndex(where: { $0.id == id }) else { return }
                let t = v.trimmingCharacters(in: .whitespaces)
                extraWaypoints[j].name = t.isEmpty ? nil : v
            }
        )
    }
}
