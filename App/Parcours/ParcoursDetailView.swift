import SwiftUI
import AppKit
import Charts
import MapKit
import Photos
import PhotosUI
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
    var window: WindowModel? = nil
    /// En fenêtre autonome (pas de 3ᵉ colonne) : l'inspecteur d'étape s'affiche en panneau flottant interne.
    var showsInlineInspector: Bool = false
    /// Fenêtre indépendante : fiche d'étape en split view (côte à côte) plutôt qu'en slide-over recouvrant.
    var isStandaloneWindow: Bool = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    /// Au-delà : tracé dense (GR importé) → non éditable par ancrages (gel + dégradation). Voir load().
    private static let maxRouteEditablePoints = 1500
    /// Id stable du repère d'aperçu de recherche (déplaçable, non encore dans le tracé).
    private static let searchPreviewId = UUID()

    @State private var tool: ParcoursTool = .select
    @State private var initialToolSet = false
    @State private var showEditableRouteDialog = false
    @AppStorage("parcoursInspectorWidth") private var inspectorWidth: Double = 360
    @State private var routeModel: RouteEditingModel
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var contentWidth: CGFloat = 0
    @State private var hasStoredWaypoints = false
    @State private var placeSearch = PlaceSearchModel()
    @State private var searchResult: (name: String, coordinate: CLLocationCoordinate2D)?
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool

    init(activity: ActivitySummary, listVM: ActivityListViewModel, repository: CoreDataActivityRepository,
         navigation: AppNavigationModel, window: WindowModel? = nil, showsInlineInspector: Bool = false, isStandaloneWindow: Bool = false) {
        self.activity = activity
        self.listVM = listVM
        self.repository = repository
        self.navigation = navigation
        self.window = window
        self.showsInlineInspector = showsInlineInspector
        self.isStandaloneWindow = isStandaloneWindow
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
    @State private var profileHighlight: CLLocationCoordinate2D?   // survol/drag profil → marqueur mobile sur la carte
    @State private var slopeData = SlopeProfileData()              // profil coloré par pente (reconstruit au chargement)
    @State private var zoomSpanKm: Double?
    @State private var centerKm: Double = 0
    @AppStorage("mapLayerParcours") private var defaultLayerRaw = MapLayer.ignScan25.rawValue   // dernier fond choisi (défaut d'un nouveau parcours)
    @State private var layerRaw = MapLayer.ignScan25.rawValue                                   // fond propre à CE parcours
    private var layerKey: String { "mapLayerParcours-\(activity.id.uuidString)" }
    @AppStorage("parcoursMapHeight") private var mapHeight: Double = 240
    @AppStorage("parcoursProfileHeight") private var profileHeight: Double = 150
    @State private var resizeAccum: CGFloat = 0
    @State private var showAddDialog = false
    @State private var renamingStageId: UUID?
    @State private var renameText = ""
    @AppStorage("parcoursAddKm") private var addKmRaw = "10"
    @AppStorage("parcoursAddGainMax") private var addGainRaw = ""
    @State private var showRecalcDialog = false
    @State private var showReverseConfirm = false
    @State private var showSplitConfirm = false
    @State private var showSplitSheet = false
    @State private var coverData: Data?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var fullscreenMap = false
    @AppStorage("parcShowStages") private var showStages = true
    @AppStorage("parcShowPOI") private var showPOI = true
    @AppStorage("parcShowShaping") private var showShaping = false   // points de tracé masqués par défaut (lisibilité)
    @State private var highlightedWaypointId: UUID?                   // survol liste → marqueur mis en évidence sur la carte
    @AppStorage("parcSecInfo") private var secInfoExpanded = true
    @AppStorage("parcSecMap") private var secMapExpanded = true
    @AppStorage("parcSecProfile") private var secProfileExpanded = true
    @AppStorage("parcSecStages") private var secStagesExpanded = true
    @AppStorage("parcSecNotes") private var secNotesExpanded = true
    @AppStorage("parcoursRecalcKm") private var recalcKmRaw = "20"
    @AppStorage("parcoursRecalcGain") private var recalcGainRaw = ""

    private var layerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer.base(fromRawValue: layerRaw) },
                set: { layerRaw = $0.rawValue; UserDefaults.standard.set($0.rawValue, forKey: layerKey); defaultLayerRaw = $0.rawValue })
    }

    private var coords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
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
        // La date du parcours (liste/tri/années) = date de départ planifiée ; fin = dernière étape.
        let end = stages.last?.plannedDate ?? start
        Task { await listVM.updateStartEndDate(id: activity.id, start: start, end: end) }
    }
    private func clearDates() {
        for k in stages.indices { stages[k].plannedDate = nil }
        persist()
        // Plus de date planifiée → la date du parcours revient à aujourd'hui.
        let today = Calendar.current.startOfDay(for: Date())
        Task { await listVM.updateStartEndDate(id: activity.id, start: today, end: today) }
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

    private var mainContent: some View {
        Group {
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        coverBanner
                        header
                        infoSection
                        mapSection
                        profileCollapsible
                        stagesCollapsible
                        notesSection
                    }
                    .padding()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
            }
        }
    }

    /// Fiche d'étape : split view (côte à côte, redimensionnable) en fenêtre autonome ; slide-over (recouvrant) dans la fenêtre principale.
    @ViewBuilder private var inspectorLayout: some View {
        if isStandaloneWindow, let stageId = navigation.selectedStageId, navigation.showStageInspector {
            HSplitView {
                mainContent.frame(minWidth: 360)
                StageDetailView(activity: activity, stageId: stageId, repository: repository)
                    .frame(minWidth: 340, idealWidth: inspectorWidth)
            }
        } else {
            mainContent.slideOverInspector(width: $inspectorWidth,
                                isPresented: showsInlineInspector && navigation.selectedStageId != nil && navigation.showStageInspector,
                                onClose: { navigation.selectedStageId = nil }) {
                if let stageId = navigation.selectedStageId {
                    StageDetailView(activity: activity, stageId: stageId, repository: repository)
                }
            }
        }
    }

    var body: some View { traceOps(coreBody) }

    /// Découper / inverser un parcours (menu Édition) — avec avertissement de perte des étapes. Isolé du body (type-check).
    @ViewBuilder private func traceOps(_ content: some View) -> some View {
        content
            .onChange(of: window?.reverseToken ?? 0) { _, _ in
                if stages.isEmpty { performReverse() } else { showReverseConfirm = true }
            }
            .onChange(of: window?.splitToken ?? 0) { _, _ in
                if stages.isEmpty { showSplitSheet = true } else { showSplitConfirm = true }
            }
            .alert("Inverser le sens du parcours", isPresented: $showReverseConfirm) {
                Button("Inverser", role: .destructive) { performReverse() }
                Button("Annuler", role: .cancel) {}
            } message: { Text("Le parcours sera retourné et ses \(stages.count) étape(s) supprimées.") }
            .alert("Scinder le parcours", isPresented: $showSplitConfirm) {
                Button("Continuer", role: .destructive) { showSplitSheet = true }
                Button("Annuler", role: .cancel) {}
            } message: { Text("Scinder crée deux parcours et supprime les \(stages.count) étape(s) (les points de passage ne sont pas conservés).") }
            .sheet(isPresented: $showSplitSheet) { SplitTrackSheet(activity: activity, repository: repository) }
    }

    private var coreBody: some View {
        inspectorLayout
        .overlay { parcoursFullscreenOverlay }
        .navigationTitle(activity.title)
        .toolbar {
            ToolbarItem(placement: .automatic) { calendarToolbarButton }
            ToolbarItem(placement: .automatic) {
                Button { showWebSheet = true } label: { Image(systemName: "globe") }
                    .help("Page web du parcours (aperçu / publication)")
            }
        }
        .modifier(ParcoursCalendarSupport(calendarSaved: $calendarSaved, calendarError: $calendarError, activityId: activity.id))
        .sheet(isPresented: $showWebSheet) { routeWebSheet }
        .onChange(of: window?.duplicateToken ?? 0) { _, _ in
            Task { await AppServices.shared.duplicateParcours(parent: activity) }
        }
        .onChange(of: coverPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let resized = Self.downscaledJPEG(data, maxDimension: 1400) {
                    setCover(resized)
                }
                coverPickerItem = nil
            }
        }
        .task(id: activity.id) {
            layerRaw = UserDefaults.standard.string(forKey: layerKey) ?? defaultLayerRaw   // fond propre à ce parcours
            titleDraft = activity.title; notesDraft = activity.notes ?? ""; routeModel.undoManager = undoManager
            coverData = try? await repository.fetchActivityCoverData(id: activity.id)
            await load(); await loadWebState()
        }
        .onChange(of: activity.title) { titleDraft = $1 }
        .onChange(of: activity.notes) { notesDraft = $1 ?? "" }
        .onChange(of: undoManager) { routeModel.undoManager = $1 }
        .onDisappear { commitTitle(); routeModel.saveIfDirty() }   // fermeture/navigation : ne pas perdre les modifications
        .task(id: AppServices.shared.libraryRevision) {
            // Après un enregistrement (manuel ou automatique), recharge profil + étapes depuis le tracé sauvegardé.
            guard initialToolSet, !routeModel.busy else { return }
            await load()
        }
        .alert("Ajouter une étape", isPresented: $showAddDialog) {
            TextField("Distance (km)", text: $addKmRaw)
            TextField("D+ max (m, optionnel)", text: $addGainRaw)
            Button("Ajouter") { addStageWithLimits() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Coupe la dernière étape à la distance indiquée, ou plus tôt si le D+ max est atteint.")
        }
        .alert("Recalculer les étapes", isPresented: $showRecalcDialog) {
            TextField("Distance max (km)", text: $recalcKmRaw)
            TextField("D+ max (m, optionnel)", text: $recalcGainRaw)
            Button("Recalculer", role: .destructive) { recalcByLimits() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Remplace toutes les étapes du parcours : il est redécoupé en étapes ne dépassant pas la distance et/ou le D+ indiqués.")
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

    /// Dates + profil altimétrique (sur le tracé sauvegardé).
    @ViewBuilder private var profileSection: some View {
        if !points.isEmpty {
            dateBar
            zoomBar
            profileChart.frame(height: profileHeight)
            resizeHandle($profileHeight, min: 90, max: 500)
        }
    }

    /// Listes points + étapes : côte à côte si la fenêtre est large (carte/profil restent pleine largeur), empilées sinon.
    @ViewBuilder private var listsSection: some View {
        if activity.isEditableRoute {
            if !routeModel.waypoints.isEmpty { pointsList.frame(maxWidth: 720, alignment: .leading) }
        } else if !points.isEmpty {
            parcoursOutline
            actions
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                TextField("Titre du parcours", text: $titleDraft)
                    .font(.title.bold()).textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                Text(activity.activityType.displayName).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Avatar = pastille du TYPE de parcours (le menu change le type). La photo est une couverture séparée.
    private var avatar: some View {
        Menu {
            activityTypeMenuItems(selected: activity.activityType) { type in
                Task { await listVM.updateType(id: activity.id, type: type) }
            }
        } label: {
            Image(systemName: activity.activityType.symbolName)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 54, height: 54).background(Circle().fill(Color(nsColor: activity.activityType.trackColor)))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 16))
                        .foregroundStyle(.secondary, Color(NSColor.windowBackgroundColor))
                }
        }
        .buttonStyle(.plain).menuIndicator(.hidden).help("Changer le type")
    }

    /// Photo de couverture du parcours (bandeau en haut, comme un raid) — apparaît aussi dans la liste.
    @ViewBuilder private var coverBanner: some View {
        if let data = coverData, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity).frame(height: 200).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    Menu {
                        PhotosPicker("Changer la photo…", selection: $coverPickerItem, matching: .images)
                        Button("Retirer la photo", role: .destructive) { setCover(nil) }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.45))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(8)
                }
        } else {
            PhotosPicker(selection: $coverPickerItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                    Text("Ajouter une photo de couverture")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }

    private func setCover(_ data: Data?) {
        coverData = data
        Task { await listVM.updateCover(id: activity.id, data: data) }
    }

    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat = 0.8) -> Data? {
        guard let img = NSImage(data: data) else { return nil }
        let size = img.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: newSize)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    @State private var webPreviewBusy = false
    @State private var showWebSheet = false
    @State private var webOptions = WebExportOptions()
    @State private var isPublishing = false
    @State private var webPublishedURL: String?
    @State private var webPublishConfig: String?
    @State private var webError: String?
    @State private var isCalendarBusy = false
    @State private var calendarSaved = false
    @State private var calendarError: String?

    private var routeWebSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Page web du parcours").font(.title3.bold())
            Text("Page mobile (carte par étape, profil, photos) façon application, à partager via un lien.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let url = webPublishedURL {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Publié", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.bold())
                    HStack(spacing: 8) {
                        Link(url, destination: URL(string: url) ?? URL(string: "https://www.gpxmanagement.net")!)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copier le lien")
                    }
                    .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Toggle("Inclure les photos (couvertures d'étape)", isOn: $webOptions.includePhotos)
            Toggle("Inclure les notes", isOn: $webOptions.includeNotes)

            if !BunnyStorageService.isConfigured {
                Text("⚠︎ Bunny non configuré (renseigner Secrets.xcconfig).").font(.caption).foregroundStyle(.orange)
            }
            if let e = webError { Text(e).font(.caption).foregroundStyle(.red) }

            HStack {
                Button("Aperçu local") { showWebSheet = false; previewWeb() }
                Spacer()
                if webPublishedURL != nil {
                    Button("Retirer", role: .destructive) { showWebSheet = false; unpublishRoute() }
                }
                Button("Fermer") { showWebSheet = false }
                Button(webPublishedURL == nil ? "Publier" : "Republier") { showWebSheet = false; publishRoute() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!BunnyStorageService.isConfigured || isPublishing)
            }
        }
        .padding(24).frame(width: 560)
    }

    /// Indicateur « Publié sur le web » dans la fiche (même pattern que trace/raid) : republier, ouvrir, copier, supprimer.
    @ViewBuilder private var webPublishedSection: some View {
        if let urlString = webPublishedURL, let url = URL(string: urlString) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundStyle(.tint)
                    Text("Publié sur le web").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { republishRoute() } label: {
                        if isPublishing { ProgressView().controlSize(.small) } else { Label("Republier", systemImage: "arrow.clockwise") }
                    }
                    .disabled(isPublishing || !BunnyStorageService.isConfigured).help("Republier avec les mêmes paramètres")
                    Button { NSWorkspace.shared.open(url) } label: { Label("Ouvrir", systemImage: "arrow.up.right.square") }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urlString, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copier le lien")
                    Button(role: .destructive) { unpublishRoute() } label: { Label("Supprimer", systemImage: "trash") }
                        .disabled(!BunnyStorageService.isConfigured).help("Retire la page publiée du web")
                }
                .controlSize(.small)
                Link(destination: url) {
                    Text(urlString).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.25)))
        }
    }

    @ViewBuilder private var calendarToolbarButton: some View {
        Button { Task { await toggleParcoursCalendar() } } label: {
            if isCalendarBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: calendarSaved ? "calendar.badge.minus" : "calendar.badge.plus") }
        }
        .disabled(isCalendarBusy)
        .help(calendarSaved ? "Retirer les étapes du Calendrier Apple"
                            : "Ajouter les étapes datées au Calendrier Apple (une par jour + un événement couvrant tout le parcours)")
    }

    private func toggleParcoursCalendar() async {
        isCalendarBusy = true
        defer { isCalendarBusy = false }
        let events = await CalendarEvent.route(activity, repository: repository)
        guard !events.isEmpty else {
            calendarError = "Aucune étape datée : renseignez les dates des étapes pour les ajouter au Calendrier."
            return
        }
        do {
            if calendarSaved {
                try await CalendarExportService.shared.remove(events)
                calendarSaved = false
            } else {
                try await CalendarExportService.shared.save(events)
                calendarSaved = true
            }
        } catch {
            calendarError = error.localizedDescription
        }
    }

    private func republishRoute() {
        if let json = webPublishConfig, let d = json.data(using: .utf8), let opts = try? JSONDecoder().decode(WebExportOptions.self, from: d) {
            webOptions = opts
        }
        publishRoute()
    }

    private func performReverse() {
        Task { await AppServices.shared.reverseParcours(activityId: activity.id) }
    }

    private func loadWebState() async {
        webPublishedURL = try? await repository.fetchWebPublishedURL(id: activity.id)
        webPublishConfig = try? await repository.fetchWebPublishConfig(id: activity.id)
    }

    private func routeUUID() -> String? {
        guard let url = webPublishedURL, let u = URL(string: url) else { return nil }
        return u.pathComponents.filter { $0 != "/" && !$0.isEmpty }.last
    }

    private func publishRoute() {
        guard !isPublishing else { return }
        isPublishing = true; webError = nil
        let progress = WebExportProgress.shared
        progress.begin("Génération de la page…")
        let act = activity, repo = repository, layer = MapLayer.base(fromRawValue: layerRaw)
        var opts = webOptions; opts.output = .publishBunny
        let uuid = routeUUID() ?? UUID().uuidString.lowercased()
        let publicBaseURL = "https://www.gpxmanagement.net/routes/\(uuid)/"
        Task { @MainActor in
            defer { isPublishing = false; progress.end() }
            do {
                let multiDay = stages.count > 1 || routeModel.waypoints.contains(where: { $0.role == .stageStop })
                let files: [String: Data]
                if multiDay {
                    files = try await HTMLReportRenderer.renderRoute(activity: act, repository: repo, layer: layer, options: opts, publicBaseURL: publicBaseURL) { f, s in progress.update(f * 0.6, s) }
                } else {
                    // Sortie à la journée : page « activité » (carte + profil dynamique synchronisé), pas la page d'étapes.
                    progress.update(0.2, "Page web…")
                    let output = try await HTMLReportRenderer.render(activity: act, repository: repo, layer: layer, options: opts, photos: [], publicBaseURL: publicBaseURL, hideDynamics: true)
                    if case .folder(let f) = output { files = f } else { files = [:] }
                }
                try await BunnyStorageService.publish(files: files, folder: "routes/\(uuid)") { f, s in progress.update(0.6 + f * 0.4, s) }
                let url = "https://www.gpxmanagement.net/routes/\(uuid)/"
                let configJSON = (try? JSONEncoder().encode(opts)).flatMap { String(data: $0, encoding: .utf8) }
                try await repo.setWebPublished(id: act.id, url: url, configJSON: configJSON)
                webPublishedURL = url; webPublishConfig = configJSON
                AppServices.shared.libraryRevision += 1   // rafraîchit l'icône « publié » dans la liste
                NSWorkspace.shared.open(URL(string: url)!)
            } catch { webError = error.localizedDescription }
        }
    }

    private func unpublishRoute() {
        guard let uuid = routeUUID() else { return }
        let act = activity, repo = repository
        Task { @MainActor in
            do {
                try await BunnyStorageService.unpublish(folder: "routes/\(uuid)")
                try await repo.clearWebPublished(id: act.id)
                webPublishedURL = nil; webPublishConfig = nil
                AppServices.shared.libraryRevision += 1
            } catch { webError = error.localizedDescription }
        }
    }

    /// Test phases 1-3 : génère la page web mono-page dans le dossier Téléchargements et l'ouvre dans le navigateur.
    private func previewWeb() {
        guard !webPreviewBusy else { return }
        webPreviewBusy = true
        let act = activity, repo = repository, layer = MapLayer.base(fromRawValue: layerRaw)
        Task { @MainActor in
            defer { webPreviewBusy = false }
            do {
                let multiDay = stages.count > 1 || routeModel.waypoints.contains(where: { $0.role == .stageStop })
                let files: [String: Data]
                if multiDay {
                    files = try await HTMLReportRenderer.renderRoute(activity: act, repository: repo, layer: layer, options: WebExportOptions())
                } else {
                    let output = try await HTMLReportRenderer.render(activity: act, repository: repo, layer: layer, options: WebExportOptions(), photos: [], hideDynamics: true)
                    if case .folder(let f) = output { files = f } else { files = [:] }
                }
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dir = downloads.appendingPathComponent("GPXManagement-apercu/\(act.id.uuidString)", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                for (rel, data) in files {
                    let url = dir.appendingPathComponent(rel)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                }
                NSWorkspace.shared.open(dir.appendingPathComponent("index.html"))
            } catch {
                NSLog("Aperçu web parcours — échec : \(error)")
            }
        }
    }

    private func commitTitle() {
        let t = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != activity.title else { return }
        Task { await listVM.updateTitle(id: activity.id, title: t) }
    }

    // MARK: Sections repliables (même présentation que l'activité/le raid)

    @ViewBuilder private func sectionChevron(_ expanded: Binding<Bool>) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: {
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0)).frame(width: 14, height: 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, _ icon: String, _ expanded: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            sectionChevron(expanded)
            Label(title, systemImage: icon).font(.headline)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() } }
    }

    @ViewBuilder private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Informations", "info.circle", $secInfoExpanded)
            if secInfoExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    MetricCard(icon: "ruler", value: String(format: "%.1f km", totalKmWithConnectors), label: "Distance", tint: .blue)
                    MetricCard(icon: "arrow.up.forward", value: "+\(totalGainWithConnectors) m", label: "Dénivelé +", tint: .green)
                    MetricCard(icon: "flag.fill", value: "\(stages.count)", label: "Étapes", tint: .orange)
                    if let d = baseDate { MetricCard(icon: "calendar", value: Self.infoDateFormatter.string(from: d), label: "Départ", tint: .purple) }
                }
                webPublishedSection
            }
        }
    }

    /// Note libre du parcours entier (comme pour une activité), distincte des notes par étape.
    @ViewBuilder private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionChevron($secNotesExpanded)
                Label("Notes", systemImage: "note.text").font(.headline)
                Spacer()
                if secNotesExpanded {
                    Button("Enregistrer") { Task { await listVM.updateNotes(id: activity.id, notes: notesDraft) } }
                        .disabled(notesDraft == (activity.notes ?? ""))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { secNotesExpanded.toggle() } }
            if secNotesExpanded {
                TextEditor(text: $notesDraft)
                    .frame(minHeight: 100)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            }
        }
    }

    @ViewBuilder private var mapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                sectionChevron($secMapExpanded)
                Label("Carte", systemImage: "map").font(.headline)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { secMapExpanded.toggle() } }
                Spacer()
                if secMapExpanded, !coords.isEmpty {
                    Button { fullscreenMap = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless).help("Carte en plein écran")
                }
            }
            if secMapExpanded {
                toolPalette
                if activity.isEditableRoute {
                    routeMap.frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                    resizeHandle($mapHeight, min: 200, max: 900)
                } else {
                    overviewMap.frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                    resizeHandle($mapHeight, min: 140, max: 700)
                }
                layersLegend
            }
        }
    }

    /// Carte du parcours en plein écran (overlay couvrant le détail — fenêtre entière en fenêtre autonome).
    @ViewBuilder private var parcoursFullscreenOverlay: some View {
        if fullscreenMap {
            StageColoredMap(activityId: activity.id, activityType: activity.activityType,
                            coords: activity.isEditableRoute ? routeModel.displayCoords : coords,
                            stages: activity.isEditableRoute ? displayStages() : stages,
                            waypoints: visibleMarkers(activity.isEditableRoute ? routeModel.markers : (poiMarkers + boundaryMarkers)),
                            showsLayerPicker: false, layer: layerBinding)
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button { fullscreenMap = false } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3).padding(10)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).padding(16).keyboardShortcut(.cancelAction)
                }
                .overlay(alignment: .bottom) {
                    LayerPicker(layer: layerBinding).padding(.bottom, 12)
                }
                .transition(.opacity)
        }
    }

    @ViewBuilder private var profileCollapsible: some View {
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Profil", "chart.xyaxis.line", $secProfileExpanded)
                if secProfileExpanded { profileSection }
            }
        }
    }

    @ViewBuilder private var stagesCollapsible: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(activity.isEditableRoute ? "Le long du parcours" : (stages.count > 1 ? "Étapes" : "Itinéraire"), "flag.fill", $secStagesExpanded)
            if secStagesExpanded { listsSection }
        }
    }

    private static let infoDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .medium; return f
    }()

    private var toolPalette: some View {
        Group {
            if activity.isEditableRoute {
                // Barre adaptative : une ligne si la largeur suffit, sinon deux lignes (écran étroit).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        toolsGroup; Divider().frame(height: 18); undoRedoButtons; Divider().frame(height: 18); lockButton; Divider().frame(height: 18)
                        searchField; enginePicker; recalcButton; fitButton
                        Spacer(); pointCount; saveButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) { toolsGroup; Divider().frame(height: 18); undoRedoButtons; Divider().frame(height: 18); lockButton; Spacer(); pointCount; saveButton }
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
            toolButton(.select, "hand.point.up.left",
                       "Sélection / déplacement — cliquer un point pour le sélectionner, glisser pour le déplacer. Un clic sur le vide n'ajoute rien.")
            toolButton(.poi, "mappin",
                       "Point d'intérêt — un clic sur la carte ajoute un lieu nommé (col, village, point de vue…) que le parcours traverse, sans couper d'étape.")
            toolButton(.stageStop, "flag.fill",
                       "Fin d'étape — un clic sur la carte pose un arrêt qui coupe le parcours en étapes (distance, D+, date, et couleur du tracé).")
            if activity.isEditableRoute {
                toolButton(.route, "point.topleft.down.to.point.bottomright.curvepath",
                           "Point de tracé — un clic sur la carte ajoute un point muet qui force l'itinéraire à passer par là (ni POI, ni étape).")
                Button { routeModel.closeLoop(); routeModel.reroute() } label: {
                    Image(systemName: "arrow.triangle.capsulepath").frame(width: 30, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(routeModel.waypoints.count < 2 || routeModel.isLoop || routeModel.busy)
                .help("Fermer la boucle — ajoute une arrivée au même endroit que le départ")
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
        routeModel.addWaypoint(at: r.coordinate, role: roleForTool ?? .poi, name: r.name)
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

    private var undoRedoButtons: some View {
        HStack(spacing: 2) {
            Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 24) }
                .help("Annuler (⌘Z)").disabled(!routeModel.canUndo || routeModel.busy)
            Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 24) }
                .help("Rétablir (⇧⌘Z)").disabled(!routeModel.canRedo || routeModel.busy)
        }
        .buttonStyle(.borderless)
    }

    private var recalcButton: some View {
        Button { routeModel.invalidateAll(); routeModel.reroute() } label: { Image(systemName: "arrow.triangle.turn.up.right.diamond") }
            .help("Recalculer tout l'itinéraire (avec le fournisseur courant)").disabled(routeModel.busy || routeModel.waypoints.count < 2)
    }
    private var fitButton: some View {
        Button { routeModel.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .help("Cadrer le parcours").disabled(routeModel.waypoints.isEmpty)
    }
    private var pointCount: some View {
        Text("\(routeModel.waypoints.count) pt").font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    /// État d'enregistrement (auto-save) : en cours / modifié (enregistrer maintenant) / enregistré.
    @ViewBuilder private var saveButton: some View {
        if routeModel.isSaving {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Enregistrement…").font(.caption).foregroundStyle(.secondary) }
        } else if routeModel.dirty {
            Button { routeModel.save(activityId: activity.id) } label: { Label("Enregistrer", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(routeModel.waypoints.count < 2)
                .help("Enregistrer maintenant (sinon automatique après quelques secondes)")
        } else {
            Label("Enregistré", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
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
        case .select: return "Cliquez un point pour le sélectionner, glissez pour le déplacer."
        case .poi: return "Cliquez sur la trace pour poser un point d'intérêt (lieu nommé)."
        case .stageStop: return "Cliquez sur la trace pour poser un arrêt et couper une étape."
        case .route: return "Cliquez pour ajouter un point de tracé (force le passage de l'itinéraire)."
        }
    }

    private var overviewMap: some View {
        StageColoredMap(activityId: activity.id, activityType: activity.activityType, coords: coords, stages: stages,
                        highlight: profileHighlight, waypoints: visibleMarkers(poiMarkers + boundaryMarkers),
                        onWaypointMoved: { id, c in moveMarker(id: id, to: c) },
                        onWaypointTapped: { tapMarker($0) },
                        onMapClick: tool == .poi || tool == .stageStop ? { mapClick(at: $0) } : nil,
                        crosshairSymbol: toolSymbol, layer: layerBinding)
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

    /// Filtre les marqueurs selon les calques actifs (départ/arrivée toujours visibles) et met en évidence
    /// le point survolé dans la liste (surbrillance croisée liste → carte).
    private func visibleMarkers(_ markers: [WaypointMarker]) -> [WaypointMarker] {
        markers.filter { m in
            if m.isDeparture || m.isArrival { return true }
            if m.stageIndex != nil { return showStages }
            switch m.role {
            case .poi: return showPOI
            case .shaping: return showShaping
            case .stageStop: return showStages
            }
        }.map { m in
            guard m.id == highlightedWaypointId, !m.isSelected else { return m }
            return WaypointMarker(id: m.id, coordinate: m.coordinate, index: m.index, role: m.role, name: m.name, label: m.label, isPreview: m.isPreview, isSelected: true, isArrival: m.isArrival, isDeparture: m.isDeparture, stageIndex: m.stageIndex)
        }
    }

    /// Légende-calques : chips pour afficher/masquer chaque catégorie de points (lisibilité de la carte).
    private var layersLegend: some View {
        HStack(spacing: 8) {
            legendChip("Étapes", "J", Color(nsColor: MapTrackPalette.colors[0]), $showStages)
            legendChip("POI", "P", .orange, $showPOI)
            if activity.isEditableRoute { legendChip("Tracé", "T", .gray, $showShaping) }
            Spacer()
        }
    }

    private func legendChip(_ title: String, _ letter: String, _ color: Color, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Text(letter).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 4).fill(color))
                Text(title).font(.caption)
                Image(systemName: on.wrappedValue ? "eye" : "eye.slash").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on.wrappedValue ? color.opacity(0.16) : Color.secondary.opacity(0.08)))
            .foregroundStyle(on.wrappedValue ? .primary : .secondary)
            .opacity(on.wrappedValue ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(on.wrappedValue ? "Masquer \(title)" : "Afficher \(title)")
    }

    /// Icône du type de point en cours de pose, affichée sur la croix de visée (même symboles que la barre d'outils).
    private var toolSymbol: String? {
        switch tool {
        case .select: return nil
        case .poi: return "mappin"
        case .stageStop: return "flag.fill"
        case .route: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    /// Repère d'aperçu déplaçable du résultat de recherche (ajustement de l'emplacement avant la pose).
    private var searchPreviewMarkers: [WaypointMarker] {
        guard let r = searchResult else { return [] }
        return [WaypointMarker(id: Self.searchPreviewId, coordinate: r.coordinate, index: -1, role: .poi, name: r.name, isPreview: true)]
    }

    /// Carte unique d'un parcours modifiable : tracé routé + points de passage typés, clic = ajouter (selon l'outil).
    /// Étapes synthétiques (indices dans displayCoords) pour colorer le tracé par étape sur la carte modifiable.
    private func displayStages() -> [Stage] {
        let wps = routeModel.waypoints
        guard wps.count >= 2 else { return [] }
        var wpPos = [0], acc = 0
        for i in 0..<(wps.count - 1) {
            let n = max((i < routeModel.segments.count ? routeModel.segments[i]?.count : nil) ?? 2, 2)
            acc += n - 1
            wpPos.append(acc)
        }
        var stopIdx = [0]
        for i in 1..<(wps.count - 1) where wps[i].role == .stageStop { stopIdx.append(i) }
        stopIdx.append(wps.count - 1)
        return (1..<stopIdx.count).map { e in
            Stage(activityId: activity.id, order: e - 1, name: "", startIndex: wpPos[stopIdx[e - 1]], endIndex: wpPos[stopIdx[e]])
        }
    }

    private var routeMap: some View {
        StageColoredMap(activityId: activity.id, activityType: activity.activityType,
                        coords: routeModel.displayCoords, stages: displayStages(), highlight: profileHighlight,
                        waypoints: visibleMarkers(routeModel.markers) + searchPreviewMarkers,
                        onWaypointMoved: { id, c in
                            if id == Self.searchPreviewId { searchResult = (searchResult?.name ?? "", c) }
                            else { routeModel.moveWaypoint(id: id, to: c); routeModel.reroute() }
                        },
                        onWaypointTapped: { wpId in
                            // Mutation d'état depuis un callback AppKit (gesture) → async pour garantir le rafraîchissement SwiftUI.
                            DispatchQueue.main.async { selectRow(wpId) }
                        },
                        onMapClick: roleForTool.map { role in { c in routeModel.addWaypoint(at: c, role: role) } },
                        proxy: routeModel.proxy, crosshairSymbol: toolSymbol, layer: layerBinding)
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
                        Text("Un segment a été routé en repli (route approximative). Si transfrontalier, change de fournisseur dans Réglages › Itinéraire ; sinon recalcule.").font(.caption)
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
        Group {
            if !slopeData.isEmpty {
                let y = slopeData.yDomain(fit: true)
                SlopeProfileChart(
                    area: slopeData.area, line: slopeData.line, styleScale: slopeData.styleScale, hover: slopeData.hover,
                    xDomainHi: slopeData.xDomainHi, yDomainLo: y.lo, yDomainHi: y.hi,
                    highlightedCoordinate: $profileHighlight,
                    visibleDomain: visibleDomain,
                    junctions: profileJunctions,
                    onJunctionDrag: { k, km in moveJunction(k, toKm: km) },
                    onJunctionDragEnded: { persist() },
                    tooltip: { s in profileTooltip(s) }
                )
            } else {
                // Repli (pas d'altitude exploitable) : ancien graphe simple.
                Chart {
                    ForEach(plot) { p in AreaMark(x: .value("km", p.km), yStart: .value("base", fallbackYDomain.lowerBound), yEnd: .value("alt", p.alt)).foregroundStyle(.blue.opacity(0.15)) }
                    ForEach(plot) { p in LineMark(x: .value("km", p.km), y: .value("alt", p.alt)).foregroundStyle(.blue) }
                }
                .chartXScale(domain: visibleDomain)
                .chartYScale(domain: fallbackYDomain)
            }
        }
    }

    /// Domaine Y du repli (sans pente) : base = point le plus bas réel (ignore les 0), jamais depuis 0.
    private var fallbackYDomain: ClosedRange<Double> {
        let positive = alts.filter { $0 > 0 }
        let lo = (positive.min() ?? alts.min()) ?? 0
        let hi = alts.max() ?? (lo + 1)
        return lo...max(hi + max((hi - lo) * 0.08, 10), lo + 1)
    }

    /// Positions X (km) des jonctions d'étape, alignées sur l'axe du profil coloré par pente.
    private var profileJunctions: [Double] {
        guard stages.count > 1 else { return [] }
        return stages.dropLast().compactMap { s in slopeData.hover.indices.contains(s.endIndex) ? slopeData.hover[s.endIndex].x : nil }
    }

    /// Déplace la frontière d'étape `k` (glissement de jonction sur le profil) vers la position km donnée.
    private func moveJunction(_ k: Int, toKm km: Double) {
        guard stages.count > 1, stages.indices.contains(k), stages.indices.contains(k + 1) else { return }
        var idx = nearestPointIndex(toMeters: km * 1000)
        let lower = stages[k].startIndex + 1
        let upper = stages[k + 1].endIndex - 1
        guard lower <= upper else { return }
        idx = min(max(idx, lower), upper)
        stages[k].endIndex = idx
        stages[k + 1].startIndex = idx
    }

    private func profileTooltip(_ s: SlopeHoverSample) -> some View {
        let cat = activity.activityType.slopeScale.category(for: s.slope)
        return VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.2f km", s.distanceKm)).font(.caption2.bold())
            tooltipRow("Altitude", "\(Int(s.altitude.rounded())) m", .primary)
            tooltipRow("Pente", String(format: "%+.0f %%", s.slope), cat.color)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .fixedSize()
    }

    private func tooltipRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption2.monospacedDigit().bold()).foregroundStyle(color)
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

    /// Écart hors-trace d'une étape (raccords départ + arrivée), pour l'afficher dans la liste.
    /// Détours hors-trace de l'étape, affichés SÉPARÉMENT (départ et/ou arrivée), pas en cumul.
    private func offTrackExtra(_ s: Stage) -> String? {
        func part(_ label: String, _ pts: [TrackPoint]) -> String? {
            let st = ActivityStatsCalculator.compute(points: pts)
            guard st.distance >= 50 || st.elevationGain >= 1 else { return nil }
            return String(format: "%@ +%.1f km·+%d m", label, st.distance / 1000, Int(st.elevationGain.rounded()))
        }
        let parts = [part("départ", s.startConnectorPoints), part("arrivée", s.endConnectorPoints)].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "↗ détour " + parts.joined(separator: " · ")
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
                Button("Tous les 10 km") { recalcKmRaw = "10"; recalcGainRaw = ""; showRecalcDialog = true }
                Button("Tous les 20 km") { recalcKmRaw = "20"; recalcGainRaw = ""; showRecalcDialog = true }
                Button("Tous les 500 m D+") { recalcKmRaw = ""; recalcGainRaw = "500"; showRecalcDialog = true }
                Button("Tous les 1000 m D+") { recalcKmRaw = ""; recalcGainRaw = "1000"; showRecalcDialog = true }
                Divider()
                Button("Personnalisé…") { showRecalcDialog = true }
            } label: { Label("Recalculer", systemImage: "wand.and.stars") }
            Spacer()
        }
    }

    // MARK: Liste des points (mode modifiable : ordre éditable)

    /// Tous les points dans l'ordre : numéro, rôle (cliquer pour changer), nom, suppression, glisser pour réordonner.
    private struct StageInfo { let stats: String; let date: String?; let stageId: UUID?; let offTrack: String? }
    /// Info d'étape (distance/D+/date) indexée par l'arrêt d'ARRIVÉE — affichée en ligne sur le point dans la liste unique.
    private func stageInfoByStop() -> [UUID: StageInfo] {
        let wps = routeModel.waypoints
        guard wps.count >= 2 else { return [:] }
        var stopPos: [Int] = [0]
        for i in 1..<(wps.count - 1) where wps[i].role == .stageStop { stopPos.append(i) }
        stopPos.append(wps.count - 1)
        let savedByStop = Dictionary(stages.compactMap { s in s.stopWaypointId.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let lastStage = stages.first { $0.stopWaypointId == nil } ?? stages.max(by: { $0.order < $1.order })
        var out: [UUID: StageInfo] = [:]
        for e in 1..<stopPos.count {
            let stop = wps[stopPos[e]]
            // La dernière étape (arrivée) a stopWaypointId = nil → on la rattache au dernier arrêt.
            let saved = e == stopPos.count - 1 ? lastStage : savedByStop[stop.id]
            let dPlus = saved.map { String(format: " · +%d m", stageGain($0)) } ?? ""
            out[stop.id] = StageInfo(stats: String(format: "%.0f km", liveStageKm(stopPos[e - 1], stopPos[e])) + dPlus,
                                     date: saved?.plannedDate.map { Self.stageDateFormatter.string(from: $0) },
                                     stageId: saved?.id, offTrack: saved.flatMap { offTrackExtra($0) })
        }
        return out
    }

    /// Liste UNIQUE « Le long du parcours » (mode modifiable) : chaque point est une ligne éditable (n°, rôle,
    /// nom, suppression, glisser pour réordonner) ; l'info d'étape (← distance · D+ · date) s'affiche en ligne
    /// sur le point d'arrivée et ouvre sa fiche. Plus de doublon points/étapes.
    private var pointsList: some View {
        let info = stageInfoByStop()
        let count = routeModel.waypoints.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Cliquer une ligne situe le point et affiche son étape · cliquer la pastille change son type · glisser pour réordonner")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
            List {
                ForEach(Array(routeModel.waypoints.enumerated()), id: \.element.id) { i, wp in
                    HStack(spacing: 8) {
                        let badge = pointBadge(wp.role, i, count, selected: routeModel.selectedWaypointId == wp.id, stage: routeModel.stageArrivalNumbers[wp.id], label: routeModel.typedLabels[wp.id])
                        if count >= 2 {
                            // Clic gauche sur la pastille = menu du point : type (intérieur) + fixer départ/arrivée.
                            Menu {
                                if i > 0 && i < count - 1 {
                                    Button { routeModel.setRole(.shaping, for: wp.id) } label: { Label("Point de tracé", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                                    Button { routeModel.setRole(.poi, for: wp.id) } label: { Label("Point d'intérêt", systemImage: "mappin") }
                                    Button { routeModel.setRole(.stageStop, for: wp.id) } label: { Label("Fin d'étape (parcours sur plusieurs jours)", systemImage: "flag.fill") }
                                } else {
                                    // Extrémité : POI, ou la (re)désigner départ/arrivée via les actions ci-dessous.
                                    Button { routeModel.setRole(.poi, for: wp.id) } label: { Label("Point d'intérêt", systemImage: "mappin") }
                                }
                                Divider()
                                if !(i == 0 && wp.role == .shaping) { Button { routeModel.makeDeparture(wp.id) } label: { Label("Définir comme départ", systemImage: "flag.2.crossed.fill") } }
                                if !(i == count - 1 && wp.role == .shaping) { Button { routeModel.makeArrival(wp.id) } label: { Label("Définir comme arrivée", systemImage: "flag.checkered") } }
                            } label: { badge }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Type du point · définir comme départ/arrivée")
                        } else {
                            badge
                        }
                        TextField(wp.role == .shaping ? "Point de tracé" : "Nom",
                                  text: Binding(get: { routeModel.name(for: wp.id) }, set: { routeModel.setName($0, for: wp.id) }))
                            .textFieldStyle(.plain).font(.caption).frame(maxWidth: 220, alignment: .leading)
                            .simultaneousGesture(TapGesture().onEnded { selectRow(wp.id) })
                        if let s = info[wp.id] {
                            Button { openStage(s.stageId) } label: {
                                HStack(spacing: 6) {
                                    Text("← \(s.stats)").foregroundStyle(.secondary)
                                    if let off = s.offTrack { Text(off).foregroundStyle(.orange) }
                                    if let d = s.date { Text(d).foregroundStyle(.blue) }
                                    if s.stageId != nil { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                                }.font(.caption)
                            }.buttonStyle(.plain).help("Détails de l'étape")
                        }
                        Spacer(minLength: 4)
                        Button { routeModel.delete(wp.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(count <= 1)
                    }
                    .contentShape(Rectangle())
                    // simultaneousGesture (et non onTapGesture) : laisse passer le glisser-déposer de réordonnancement (.onMove).
                    .simultaneousGesture(TapGesture().onEnded { selectRow(wp.id) })
                    // Changement de rôle : clic droit n'importe où sur la ligne (le clic gauche reste « situer/afficher l'étape »).
                    .contextMenu {
                        if i > 0 && i < count - 1 {
                            Button { routeModel.setRole(.shaping, for: wp.id) } label: { Label("Point de tracé", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                            Button { routeModel.setRole(.poi, for: wp.id) } label: { Label("Point d'intérêt", systemImage: "mappin") }
                            Button { routeModel.setRole(.stageStop, for: wp.id) } label: { Label("Fin d'étape", systemImage: "flag.fill") }
                        }
                    }
                    .onHover { hovering in
                        if hovering { highlightedWaypointId = wp.id }
                        else if highlightedWaypointId == wp.id { highlightedWaypointId = nil }
                    }
                    .listRowBackground(
                        HStack(spacing: 0) {
                            Rectangle().fill(routeModel.selectedWaypointId == wp.id ? Color.accentColor : .clear).frame(width: 3)
                            ((routeModel.selectedWaypointId == wp.id || highlightedWaypointId == wp.id) ? Color.accentColor.opacity(0.18) : Color.clear)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    // Trait UNIQUEMENT après un arrêt interne (= frontière d'étape), pas entre chaque point.
                    .listRowSeparator((wp.role == .stageStop && i > 0 && i < count - 1) ? .visible : .hidden, edges: .bottom)
                    .listRowSeparator(.hidden, edges: .top)
                }
                .onMove { routeModel.moveWaypoints(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .frame(height: min(Double(count) * 30 + 8, 420))
            .onChange(of: routeModel.selectedWaypointId) { _, id in
                if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
            }
            }
        }
    }

    private func pointColor(_ role: RouteWaypoint.Role) -> Color {
        switch role { case .shaping: return .gray; case .poi: return .orange; case .stageStop: return .green }
    }
    /// Pastille identique aux marqueurs de la carte : arrêt d'étape = badge « Jn » dans la couleur de l'étape ;
    /// départ = drapeaux croisés ; POI = épingle ; point de tracé = numéro. Bleu si sélectionné.
    @ViewBuilder private func pointBadge(_ role: RouteWaypoint.Role, _ i: Int, _ count: Int, selected: Bool, stage: Int?, label: String?) -> some View {
        if let n = stage {
            labelBadge("J\(n)", selected ? Color.accentColor : Color(nsColor: MapTrackPalette.color(at: n - 1)))
        } else if role == .poi {
            labelBadge(label ?? "P", selected ? Color.accentColor : .orange)
        } else if i == 0 && count >= 2 && role == .shaping {
            Image(systemName: "flag.2.crossed.fill").font(.system(size: 15)).foregroundStyle(selected ? Color.accentColor : .green).frame(width: 26)
        } else if i == count - 1 && count >= 2 && role == .shaping {
            Image(systemName: "flag.checkered").font(.system(size: 14)).foregroundStyle(selected ? Color.accentColor : .red).frame(width: 26)
        } else if role == .shaping {
            labelBadge(label ?? "T", selected ? Color.accentColor : .gray, small: true)
        } else {
            Image(systemName: "mappin.circle.fill").font(.system(size: 17)).foregroundStyle(selected ? Color.accentColor : .orange).frame(width: 26)
        }
    }

    private func labelBadge(_ text: String, _ color: Color, small: Bool = false) -> some View {
        Text(text).font(.system(size: small ? 9 : 11, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 5).frame(height: small ? 17 : 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 1))
            .frame(width: 30)
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
        var arrival: String?     // nom de l'arrêt d'arrivée de l'étape (liste compacte)
        var live = false
    }

    /// Source de la liste : vivante (routeModel) en modifiable, sauvegardée (stages + POI) en fidèle.
    private var outlineItems: [OutlineItem] { activity.isEditableRoute ? liveOutlineItems : savedOutlineItems }

    /// Mode fidèle : liste sauvegardée, ordonnée le long du tracé (étapes `stages` + POI `extraWaypoints`).
    private var savedOutlineItems: [OutlineItem] {
        guard !stages.isEmpty, !points.isEmpty else { return [] }
        let pois = extraWaypoints.filter { $0.role == .poi }
        func idx(_ w: RouteWaypoint) -> Int { RouteWaypoint.nearestIndex(latitude: w.latitude, longitude: w.longitude, in: points) }
        // Sortie à la journée (1 étape, aucun arrêt) : on n'affiche pas d'en-tête « Étape », juste départ → arrivée.
        let singleDay = stages.count == 1
        var items: [OutlineItem] = [OutlineItem(id: "start", kind: .departure)]
        for (k, s) in stages.enumerated() {
            for w in pois where idx(w) > s.startIndex && idx(w) <= s.endIndex {
                items.append(OutlineItem(id: "poi-\(w.id)", kind: .poi, poiId: w.id))
            }
            if !singleDay {
                items.append(OutlineItem(id: "stage-\(s.id)", kind: .stageHeader, number: k + 1,
                                         stats: String(format: "%.1f km · +%d m", stageKm(s), stageGain(s)),
                                         date: s.plannedDate.map { Self.stageDateFormatter.string(from: $0) },
                                         offTrack: offTrackExtra(s), stageId: s.id))
            }
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
            let arr = (stop.name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            items.append(OutlineItem(id: "lstage-\(stop.id)", kind: .stageHeader, number: e,
                                     stats: String(format: "%.1f km", liveStageKm(from, to)) + dPlus,
                                     date: saved?.plannedDate.map { Self.stageDateFormatter.string(from: $0) },
                                     offTrack: saved.flatMap { offTrackExtra($0) }, stageId: saved?.id, arrival: arr, live: true))
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

    /// Étape qui CONTIENT un waypoint (pas seulement son arrivée) : la première étape dont l'arrivée est à/après lui.
    private func stageContainingWaypoint(_ wpId: UUID) -> UUID? {
        let wps = routeModel.waypoints
        guard let i = wps.firstIndex(where: { $0.id == wpId }) else { return nil }
        let lastIdx = wps.count - 1
        let arrivals: [(idx: Int, id: UUID)] = stages.compactMap { s in
            if let stopId = s.stopWaypointId, let si = wps.firstIndex(where: { $0.id == stopId }) { return (si, s.id) }
            return (lastIdx, s.id)
        }.sorted { $0.idx < $1.idx }
        return arrivals.first(where: { $0.idx >= i })?.id ?? arrivals.last?.id
    }

    /// Clic sur une ligne de la liste : sélectionne le point ; ouvre l'étape si c'est une ligne d'étape (arrivée),
    /// sinon — si une étape est déjà affichée à droite — bascule sur l'étape qui contient ce point.
    private func selectRow(_ wpId: UUID) {
        routeModel.selectedWaypointId = wpId
        highlightedWaypointId = wpId
        if let direct = stageId(forWaypoint: wpId) {
            openStage(direct)
        } else if navigation.selectedStageId != nil, let containing = stageContainingWaypoint(wpId) {
            openStage(containing)
        }
    }

    /// Étape correspondant à un arrêt tapé sur la carte : arrêt interne via `stopWaypointId`, arrivée → dernière étape.
    private func stageId(forWaypoint wpId: UUID) -> UUID? {
        if let s = stages.first(where: { $0.stopWaypointId == wpId }) { return s.id }
        if routeModel.waypoints.last?.id == wpId {
            return (stages.first { $0.stopWaypointId == nil } ?? stages.max(by: { $0.order < $1.order }))?.id
        }
        return nil
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

    /// Redécoupe TOUT le parcours en étapes ne dépassant ni la distance ni le D+ max (coupe au premier atteint).
    private func recalcByLimits() {
        let distMeters = (Double(recalcKmRaw.replacingOccurrences(of: ",", with: ".")) ?? 0) * 1000
        let gainMeters = Double(recalcGainRaw.replacingOccurrences(of: ",", with: ".")) ?? 0
        let n = points.count
        guard n >= 2, distMeters > 0 || gainMeters > 0, dists.count == n, cumGain.count == n else { return }
        navigation.selectedStageId = nil
        var bounds: [(Int, Int)] = []
        var a = 0
        while a < n - 1 {
            var cut = n - 1
            if a + 1 < n - 1 {
                for i in (a + 1)..<(n - 1) {
                    let distHit = distMeters > 0 && (dists[i] - dists[a] >= distMeters)
                    let gainHit = gainMeters > 0 && (cumGain[i] - cumGain[a] >= gainMeters)
                    if distHit || gainHit { cut = i; break }
                }
            }
            bounds.append((a, cut))
            a = cut
        }
        stages = bounds.enumerated().map { i, b in
            Stage(activityId: activity.id, order: i, name: "Étape \(i + 1)", startIndex: b.0, endIndex: b.1)
        }
        persist()
    }
    private func persist() {
        for i in stages.indices { stages[i].order = i }
        let snapshot = stages
        let pts = points
        let pois = extraWaypoints
        Task {
            if activity.isEditableRoute {
                // Modifiable : les points de passage appartiennent à routeModel. NE PAS les reconstruire
                // (saveStagedRoute/syncStops perdrait le départ et l'arrivée) — on ne persiste QUE les étapes.
                try? await repository.replaceStages(activityId: activity.id, with: snapshot)
            } else {
                guard let updated = try? await repository.saveStagedRoute(activityId: activity.id, stages: snapshot, points: pts, pois: pois) else { return }
                await MainActor.run {
                    // Réinjecte les stopWaypointId créés (stabilité des ids), sans écraser une édition en cours.
                    guard updated.count == stages.count else { return }
                    for i in stages.indices { stages[i].stopWaypointId = updated[i].stopWaypointId }
                }
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
            points = decoded; slopeData = SlopeProfileData()
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
        let profile = ElevationProfileBuilder.build(points: pts)
        slopeData = profile.count >= 2
            ? SlopeProfileData.build(profile: profile, slopeScale: activity.activityType.slopeScale)
            : SlopeProfileData()
    }

    // MARK: POI sur la trace (mode fidèle : aimantés au tracé, jamais de re-routage)

    private var poiMarkers: [WaypointMarker] {
        var p = 0
        return extraWaypoints.compactMap { w in
            guard w.role == .poi else { return nil }
            p += 1
            return WaypointMarker(id: w.id, coordinate: CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude), index: 0, role: .poi, name: w.name, label: "P\(p)")
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

/// Regroupe l'état Calendrier (rafraîchissement à l'apparition + alerte d'erreur) en un seul modificateur,
/// pour ne pas alourdir le `body` du détail de parcours (limite de type-checking).
private struct ParcoursCalendarSupport: ViewModifier {
    @Binding var calendarSaved: Bool
    @Binding var calendarError: String?
    let activityId: UUID
    func body(content: Content) -> some View {
        content
            .onAppear { calendarSaved = CalendarExportService.shared.isSaved(CalendarEvent.routeChapeauKey(activityId)) }
            .alert("Calendrier", isPresented: Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })) {
                Button("OK") { calendarError = nil }
            } message: { Text(calendarError ?? "") }
    }
}
