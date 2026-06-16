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

struct ActivityDetailView: View {
    let activity: ActivitySummary
    @Bindable var listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    let windowModel: WindowModel
    /// Vrai dans la fenêtre détail dédiée (double-clic).
    var isStandaloneWindow: Bool = false
    /// État plein écran de la carte (partagé avec la fenêtre pour vider sa barre d'outils tout en gardant les pastilles).
    @Binding var fullscreenMap: Bool
    @State private var model: ActivityDetailViewModel
    @State private var notesDraft: String = ""
    @State private var shareURL: URL?
    @State private var isShareSheetPresented = false
    @State private var exportError: String?
    @State private var isExportingPDF = false
    @State private var isReprocessing = false
    @State private var elevationAlert: String?
    @State private var sensorSeries: SensorSeries?
    @AppStorage("detailSectionHeartRate") private var secHeartRateExpanded = true
    @State private var profileMode: ProfileMode = .distance
    @State private var profileMetric: ProfileMetric = .altitude
    @State private var highlightedCoordinate: CLLocationCoordinate2D?
    @State private var selectedSegmentId: UUID?
    @State private var selectedSegmentCoords: [CLLocationCoordinate2D] = []
    @State private var selectedSegmentRange: ClosedRange<Double>?
    @State private var photoAssets: [PHAsset] = []
    @State private var photoMapItems: [PhotoMapItem] = []
    @State private var previewURL: URL?
    @State private var hiddenPhotoIDs: Set<String> = []   // ancien état local (par localIdentifier) — source de migration
    @State private var shownPhotoIDs: Set<String> = []     // idem
    @State private var mediaState: [String: MediaPlacement] = [:]   // état synchronisé (par clé stable nom+date)
    @State private var assetIdentity: [String: (key: String, file: String, date: Double?)] = [:]  // localIdentifier → identité stable
    @State private var incoherentPhotoIDs: Set<String> = []   // heure et GPS en désaccord (> seuil), non réglés à la main
    @State private var editingMedia: EditingMedia?
    @State private var positioningMedia: PositioningMedia?
    @State private var photosReload = 0
    @AppStorage("appCreatedAssets") private var appCreatedAssetsJSON = ""
    @AppStorage("photosSelectedByDefault") private var photosSelectedByDefault = true
    // Sections de la fiche repliables (état mémorisé).
    @AppStorage("detailSectionInfo") private var secInfoExpanded = true
    @AppStorage("detailSectionMap") private var secMapExpanded = true
    @AppStorage("detailSectionProfile") private var secProfileExpanded = true
    @AppStorage("detailSectionSegments") private var secSegmentsExpanded = true
    @AppStorage("detailSectionNotes") private var secNotesExpanded = true
    @State private var showCustomDistanceSegment = false
    @State private var customSegmentKm = ""
    @State private var showCustomGainSegment = false
    @State private var customSegmentGain = ""
    @State private var showStagePlanner = false
    @State private var routeEditMode = false
    @State private var isExportingVideo = false
    @State private var videoProgress: Double = 0
    @State private var showVideoOptions = false
    @State private var showSplitSheet = false
    @State private var showSimplifySheet = false
    @State private var showCleanSheet = false
    @State private var videoPublish = false
    @State private var showWebExportOptions = false
    @State private var isExportingWeb = false
    @State private var isUnpublishingWeb = false
    @State private var webOptions = WebExportOptions()
    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool
    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = "ign_scan25"
    @AppStorage("slopeOverlayEnabled") private var slopeOverlayEnabled: Bool = false
    @AppStorage("slopeOverlayOpacity") private var slopeOverlayOpacity: Double = 0.6
    @AppStorage("trackColorMode") private var trackColorModeRaw: String = TrackColorMode.uniform.rawValue
    @AppStorage("detailMapHeight") private var mapHeight: Double = 340
    @State private var dragAccumulator: Double = 0
    @State private var fsProfileHeight: Double = 220 // hauteur du volet profil en plein écran (local à la fenêtre)
    @State private var showFsProfile = true
    @AppStorage("videoQuality") private var videoQualityRaw = VideoQuality.hd720.rawValue
    @AppStorage("videoFormat") private var videoFormatRaw = VideoFormat.landscape.rawValue
    @AppStorage("videoUserTemplates") private var userTemplatesJSON = ""
    @AppStorage("videoSelectedTemplate") private var selectedTemplateID = "builtin.sidebyside"
    @AppStorage("videoTransition") private var videoTransitionRaw = MediaTransition.fade.rawValue
    @AppStorage("videoHeartRate") private var videoHeartRateOn = true
    @AppStorage("videoIntro") private var videoIntroOn = true
    @AppStorage("videoOutro") private var videoOutroOn = true
    @AppStorage("videoMapLayer") private var videoMapLayerRaw = "ign_scan25"
    @State private var currentLayout = VideoLayout.defaultLayout(for: .landscape)
    @State private var tracePreview: [CGPoint] = []
    @State private var showTemplateNameAlert = false
    @State private var templateNameInput = ""
    @State private var savingNewTemplate = false
    @AppStorage("photosOnMapEnabled") private var photosOnMapEnabled = true
    @AppStorage("pauseThresholdMinutes") private var pauseThresholdMinutes: Double = 5
    @AppStorage("pauseRadiusMeters") private var pauseRadiusMeters: Double = 40

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    init(activity: ActivitySummary, listVM: ActivityListViewModel, repository: CoreDataActivityRepository,
         windowModel: WindowModel, isStandaloneWindow: Bool = false, fullscreenMap: Binding<Bool>) {
        self.activity = activity
        self.listVM = listVM
        self.repository = repository
        self.windowModel = windowModel
        self.isStandaloneWindow = isStandaloneWindow
        self._fullscreenMap = fullscreenMap
        self._model = State(initialValue: ActivityDetailViewModel(repository: repository))
    }

    private var rootContent: some View {
        Group {
            if fullscreenMap {
                // Seul l'overlay plein écran est rendu (le contenu détail dessous n'est pas dans l'arbre → pas de re-render pendant le drag).
                fullscreenMapOverlay
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        Divider()
                        infoSection
                        filmLinkSection
                        if model.hasTrack {
                            mapSection
                            profileSection
                            segmentsSection
                        } else {
                            noTrackNotice
                            sensorSection
                        }
                        photosSection
                        notesSection
                    }
                    .padding(20)
                }
            }
        }
    }

    private var contentWithEvents: some View {
        rootContent
        // Titre vidé en plein écran pour ne pas chevaucher les contrôles (barre de titre transparente).
        .navigationTitle(fullscreenMap ? "" : activity.title)
        // Fenêtre autonome : barre de titre transparente en plein écran (pastilles flottantes conservées) ;
        // la fenêtre principale gère la même chose côté ContentView.
        .toolbarBackground(isStandaloneWindow && fullscreenMap ? .hidden : .automatic, for: .windowToolbar)
        .task(id: "\(activity.id)-\(activity.activityType.rawValue)-\(pauseThresholdMinutes)-\(pauseRadiusMeters)") { await model.loadDerivedMetrics(for: activity, pauseMinSeconds: pauseThresholdMinutes * 60, pauseRadiusMeters: pauseRadiusMeters) }
        .onAppear {
            notesDraft = activity.notes ?? ""
            titleDraft = activity.title
            hiddenPhotoIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenPhotosKey) ?? [])
            shownPhotoIDs = Set(UserDefaults.standard.stringArray(forKey: Self.shownPhotosKey) ?? [])
            Task { await model.loadPublishState(activityId: activity.id) }
            Task { await loadMediaState() }
            Task { await loadSensorSeries() }
        }
        .onChange(of: activity.id) { _, _ in
            notesDraft = activity.notes ?? ""
            titleDraft = activity.title
            assetIdentity = [:]
            sensorSeries = nil
            model.resetPublishState()
            Task { await model.loadPublishState(activityId: activity.id) }
            Task { await loadMediaState() }
            Task { await loadSensorSeries() }
        }
        .onChange(of: activity.title) { _, newTitle in
            if !titleFocused { titleDraft = newTitle }
        }
        // Équivalents menu « Activité » des boutons de la barre d'outils (déclenchés par token).
        .onChange(of: windowModel.repairToken) { _, _ in
            Task {
                isReprocessing = true
                defer { isReprocessing = false }
                await AppServices.shared.reprocessActivity(id: activity.id)
                await loadSensorSeries()
            }
        }
        .onChange(of: windowModel.elevationToken) { _, _ in
            Task { await generateElevationFromMenu() }
        }
        .onChange(of: windowModel.splitToken) { _, _ in
            if model.hasTrack { showSplitSheet = true }
        }
        .onChange(of: windowModel.simplifyToken) { _, _ in
            if model.hasTrack { showSimplifySheet = true }
        }
        .onChange(of: windowModel.cleanToken) { _, _ in
            if model.hasTrack { showCleanSheet = true }
        }
        .onChange(of: windowModel.reverseToken) { _, _ in
            if model.hasTrack { Task { await AppServices.shared.reverseActivity(parent: activity) } }
        }
        .onChange(of: windowModel.duplicateToken) { _, _ in
            Task { await AppServices.shared.duplicateActivity(parent: activity) }
        }
        .onChange(of: windowModel.editRouteToken) { _, _ in
            if activity.isCourse, model.hasTrack { secMapExpanded = true; routeEditMode = true }
            else { AppServices.shared.importError = "« Modifier l'itinéraire » est réservé aux parcours." }
        }
        .onChange(of: windowModel.webExportToken) { _, _ in
            if model.hasTrack { showWebExportOptions = true }
        }
        .onChange(of: windowModel.videoToken) { _, _ in
            if model.hasTrack { showVideoOptions = true }
        }
        .onChange(of: windowModel.shareToken) { _, _ in
            if model.hasTrack { Task { await prepareShare() } }
        }
    }

    var body: some View {
        contentWithEvents
        .toolbar {
            ToolbarItemGroup {
                if !fullscreenMap {
                Button {
                    Task { await listVM.autoRename(id: activity.id) }
                } label: {
                    if listVM.renamingIds.contains(activity.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Nommer d'après le parcours", systemImage: "mappin.and.ellipse")
                    }
                }
                .disabled(listVM.renamingIds.contains(activity.id) || !model.hasTrack)
                .help("Renomme l'activité avec lieu de départ → point de passage → arrivée")

                Button {
                    Task {
                        isReprocessing = true
                        defer { isReprocessing = false }
                        await AppServices.shared.reprocessActivity(id: activity.id)
                        await loadSensorSeries()
                    }
                } label: {
                    if isReprocessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Réparer", systemImage: "wrench.and.screwdriver")
                    }
                }
                .disabled(isReprocessing)
                .help("Ré-analyse le fichier source et rafraîchit les statistiques (distance, dénivelé, fréquence cardiaque…)")

                Button {
                    Task { await exportGPX() }
                } label: {
                    Label("Exporter en GPX", systemImage: "arrow.down.doc")
                }
                .disabled(!model.hasTrack)
                .help("Exporte la trace au format GPX (compatible avec les apps tierces)")
                Button {
                    Task { await exportPDF() }
                } label: {
                    if isExportingPDF {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Exporter en PDF", systemImage: "doc.richtext")
                    }
                }
                .disabled(isExportingPDF || !model.hasTrack)
                .help("Génère un rapport PDF imprimable : carte, profil, statistiques et notes")
                Button {
                    showWebExportOptions = true
                } label: {
                    if isExportingWeb {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Exporter en page web", systemImage: "globe")
                    }
                }
                .disabled(isExportingWeb || !model.hasTrack)
                .help("Génère une page web de présentation (même contenu que le détail), prête pour un CDN")
                Button {
                    showVideoOptions = true
                } label: {
                    if isExportingVideo {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Créer une vidéo", systemImage: "film")
                    }
                }
                .disabled(isExportingVideo || !model.hasTrack)
                .help("Crée un film du parcours (point animé) avec les photos/vidéos sélectionnées")

                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("Partager", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasTrack)
                .help("Partage l'activité via le menu de partage macOS (Mail, Messages, AirDrop…)")
                } else if isStandaloneWindow {
                    // Plein écran (fenêtre autonome) : sortie dans la toolbar (reçoit le clic, au-dessus de la carte).
                    Button { fullscreenMap = false } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .keyboardShortcut(.cancelAction).help("Quitter le plein écran (Échap)")
                }
            }
        }
        .overlay {
            if isExportingVideo {
                VStack(spacing: 10) {
                    ProgressView(value: videoProgress)
                        .frame(width: 220)
                    Text("Génération de la vidéo… \(Int(videoProgress * 100)) %")
                        .font(.callout)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                .shadow(radius: 8)
            }
        }
        .sheet(isPresented: $showVideoOptions) { videoOptionsSheet }
        .sheet(isPresented: $showWebExportOptions) { webExportOptionsSheet }
        .quickLookPreview($previewURL)
        .background(ShareSheetPresenter(isPresented: $isShareSheetPresented, url: shareURL))
        .alert("Export", isPresented: hasExportErrorBinding) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("Profil altimétrique", isPresented: hasElevationAlertBinding) {
            Button("OK") { elevationAlert = nil }
        } message: {
            Text(elevationAlert ?? "")
        }
        .sheet(isPresented: $showSplitSheet) {
            SplitTrackSheet(activity: activity, repository: repository)
        }
        .sheet(isPresented: $showSimplifySheet) {
            SimplifyTrackSheet(activity: activity, repository: repository)
        }
        .sheet(isPresented: $showCleanSheet) {
            CleanTrackSheet(activity: activity, repository: repository)
        }
    }

    private var hasElevationAlertBinding: Binding<Bool> {
        Binding(get: { elevationAlert != nil }, set: { if !$0 { elevationAlert = nil } })
    }

    private var header: some View {
        HStack(spacing: 14) {
            Menu {
                activityTypeMenuItems(selected: activity.activityType) { type in
                    Task { await listVM.updateType(id: activity.id, type: type) }
                }
            } label: {
                Image(systemName: activity.activityType.symbolName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color(nsColor: activity.activityType.trackColor)))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary, Color(NSColor.windowBackgroundColor))
                    }
            }
            .buttonStyle(.plain)
            .help("Changer le type d'activité")
            VStack(alignment: .leading, spacing: 3) {
                TextField("Titre", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
                    .help("Renommer le tracé")
                HStack(spacing: 8) {
                    Text("\(activity.activityType.displayName) · \(Self.formatDate(activity.startDate))")
                        .foregroundStyle(.secondary)
                    if activity.isCourse {
                        Label("Parcours", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.18)))
                            .foregroundStyle(.tint)
                    }
                }
                if !activity.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(activity.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
            }
            Spacer()
            Menu {
                Button {
                    Task { await listVM.setIsCourse(id: activity.id, isCourse: false) }
                } label: {
                    Label("Activité réelle", systemImage: activity.isCourse ? "circle" : "checkmark")
                }
                Button {
                    Task { await listVM.setIsCourse(id: activity.id, isCourse: true) }
                } label: {
                    Label("Parcours (préparation)", systemImage: activity.isCourse ? "checkmark" : "circle")
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Classer comme activité réelle ou parcours")
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { titleDraft = activity.title; return }
        guard trimmed != activity.title else { return }
        Task { await listVM.updateTitle(id: activity.id, title: trimmed) }
    }

    @ViewBuilder
    private var filmLinkSection: some View {
        if let urlString = model.filmPublishedURL, let url = URL(string: urlString) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "film").foregroundStyle(.tint)
                    Text("Film publié").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        videoPublish = true
                        showVideoOptions = true
                    } label: {
                        Label("Recréer", systemImage: "arrow.clockwise")
                    }
                    .disabled(isExportingVideo || !BunnyStorageService.isConfigured)
                    .help("Recréer et republier le film")
                    Button { NSWorkspace.shared.open(url) } label: { Label("Ouvrir", systemImage: "arrow.up.right.square") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(urlString, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copier le lien")
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

    @ViewBuilder
    private var publishedLinkSection: some View {
        if let urlString = model.publishedURL, let url = URL(string: urlString) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundStyle(.tint)
                    Text("Publié sur le web").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await republishWeb() }
                    } label: {
                        if isExportingWeb {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Republier", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isExportingWeb || !BunnyStorageService.isConfigured)
                    .help("Republier avec les mêmes paramètres")
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Ouvrir", systemImage: "arrow.up.right.square")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(urlString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copier le lien")
                    Button(role: .destructive) {
                        Task { await unpublishWeb() }
                    } label: {
                        if isUnpublishingWeb {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                    .disabled(isUnpublishingWeb || !BunnyStorageService.isConfigured)
                    .help("Retire la page publiée du web")
                }
                .controlSize(.small)
                Link(destination: url) {
                    Text(urlString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.25)))
        }
    }

    /// Chevron de pliage réutilisé par les en-têtes de section.
    @ViewBuilder
    private func sectionChevron(_ expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadSensorSeries() async {
        let data = try? await repository.fetchSensorData(id: activity.id)
        sensorSeries = SensorSeriesCodec.decode(data)
    }

    private func generateElevationFromMenu() async {
        switch await AppServices.shared.generateElevationProfile(id: activity.id) {
        case .enriched:
            await loadSensorSeries()
        case .noCoverage:
            elevationAlert = "Aucune altitude trouvée pour cette trace (hors couverture des données disponibles)."
        case .failed(let m):
            elevationAlert = "Échec : \(m)"
        }
    }

    /// Séance sans GPS mais avec FC : on affiche la courbe (sinon ces mesures resteraient invisibles).
    @ViewBuilder
    private var sensorSection: some View {
        if let series = sensorSeries, series.hasHeartRate {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    sectionChevron($secHeartRateExpanded)
                    Label("Fréquence cardiaque", systemImage: "heart.fill").font(.headline).foregroundStyle(.red)
                    Spacer()
                    if secHeartRateExpanded, let st = series.heartRateStats {
                        Text("moy \(Int(st.avg.rounded())) · max \(Int(st.max.rounded())) bpm")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if secHeartRateExpanded { SensorChartView(series: series) }
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                sectionChevron($secInfoExpanded)
                Label("Informations", systemImage: "info.circle").font(.headline)
                Spacer()
            }
            if secInfoExpanded {
                metricsGrid
                publishedLinkSection
            }
        }
    }

    private var metricsGrid: some View {
        // Affichage adapté au type et aux données : on masque les métriques sans objet (distance/vitesse
        // pour l'escalade, la muscu…) ou sans valeur (dénivelé/vitesse à 0).
        let movement = activity.activityType.tracksDistanceAndSpeed
        return LazyVGrid(columns: columns, spacing: 12) {
            if movement && activity.distance > 0 {
                MetricCard(icon: "ruler", value: distanceText(activity.distance), label: "Distance", tint: .blue)
            }
            if activity.elevationGain > 0 {
                MetricCard(icon: "arrow.up.forward", value: "\(Int(activity.elevationGain.rounded())) m", label: "Dénivelé +", tint: .green)
            }
            if activity.elevationLoss > 0 {
                MetricCard(icon: "arrow.down.forward", value: "\(Int(activity.elevationLoss.rounded())) m", label: "Dénivelé −", tint: .orange)
            }
            MetricCard(icon: "clock", value: Self.duration(activity.duration), label: "Durée totale", tint: .purple)
            // En mouvement = montée + descente + plat (même partition que la pause) → les temps s'additionnent au total.
            if let mv = model.movingTime {
                MetricCard(icon: "stopwatch", value: Self.duration(mv), label: "En mouvement", tint: .purple)
            } else if movement && activity.movingDuration > 0 {
                MetricCard(icon: "stopwatch", value: Self.duration(activity.movingDuration), label: "En mouvement", tint: .purple)
            }
            if let pause = model.pausedTime {
                MetricCard(icon: "pause.circle", value: Self.duration(pause), label: "En pause", tint: .gray)
            }
            if let up = model.ascentTime {
                MetricCard(icon: "arrow.up.forward.circle", value: Self.duration(up), label: "Temps en montée", tint: .green)
            }
            if let down = model.descentTime {
                MetricCard(icon: "arrow.down.forward.circle", value: Self.duration(down), label: "Temps en descente", tint: .blue)
            }
            if let flat = model.flatTime {
                MetricCard(icon: "arrow.right.circle", value: Self.duration(flat), label: "Temps à plat", tint: .teal)
            }
            if movement && activity.avgSpeed > 0 {
                MetricCard(icon: "speedometer", value: speedText(activity.avgSpeed), label: "Vitesse moy.", tint: .teal)
            }
            if movement && activity.maxSpeed > 0 {
                MetricCard(icon: "gauge.with.dots.needle.67percent", value: speedText(activity.maxSpeed), label: "Vitesse max", tint: .teal)
            }
            if let hr = activity.avgHeartRate {
                MetricCard(icon: "heart", value: "\(Int(hr.rounded())) bpm", label: "FC moyenne", tint: .red)
            }
            if let hr = activity.maxHeartRate {
                MetricCard(icon: "heart.fill", value: "\(Int(hr.rounded())) bpm", label: "FC max", tint: .red)
            }
            if activity.activityType == .climbing, let n = model.climbCount {
                MetricCard(icon: "figure.climbing", value: "\(n)", label: "Montées", tint: .brown)
            }
            // Séance sans tracé GPS : on n'a pas de carte/profil, on expose donc les repères horaires
            // et l'appareil source pour donner du contexte.
            if !model.hasTrack {
                MetricCard(icon: "clock.badge.checkmark", value: Self.timeOnly(activity.startDate), label: "Début", tint: .indigo)
                MetricCard(icon: "clock.badge.xmark", value: Self.timeOnly(activity.endDate), label: "Fin", tint: .indigo)
                if let device = deviceLabel {
                    MetricCard(icon: "applewatch", value: device, label: "Appareil", tint: .gray)
                }
            }
        }
    }

    /// Nom lisible de l'appareil/app source (ex. « Watch6,18 », « Strava »), si connu.
    private var deviceLabel: String? {
        if let app = activity.sourceApp, !app.isEmpty { return app }
        let name = activity.source.displayName
        return name.isEmpty ? nil : name
    }

    /// Bandeau affiché à la place de la carte/profil pour une séance sans tracé GPS.
    private var noTrackNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pas de tracé GPS")
                    .font(.callout.weight(.semibold))
                Text("Cette séance a été enregistrée sans position (activité sur place). Les mesures disponibles sont affichées ci-dessus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionChevron($secProfileExpanded)
                Label(profileMetric == .speed ? "Profil de vitesse" : "Profil altimétrique",
                      systemImage: profileMetric == .speed ? "speedometer" : "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                // Escalade : pas de vitesse ni de distance pertinentes (sur place) → profil altitude/temps, sans sélecteurs.
                if !isClimbing && secProfileExpanded {
                    Picker("", selection: $profileMetric) {
                        ForEach(ProfileMetric.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $profileMode) {
                        ForEach(ProfileMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if secProfileExpanded {
            ElevationProfileTabView(
                activityId: activity.id, activityType: activity.activityType, repository: repository,
                storedGain: activity.elevationGain, storedLoss: activity.elevationLoss,
                mode: $profileMode, metric: $profileMetric, highlightedCoordinate: $highlightedCoordinate,
                highlightedDistanceRange: selectedSegmentRange,
                onSelectRange: activity.activityType.tracksDistanceAndSpeed ? { start, end in
                    Task {
                        let created = await model.createSegment(fromMeters: start, toMeters: end, activityId: activity.id)
                        setSelectedSegment(created?.id)
                    }
                } : nil
            )
            .frame(height: 280)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
            }
        }
        .onChange(of: activity.id, initial: true) {
            if isClimbing { profileMetric = .altitude; profileMode = .time }
            else { profileMetric = activity.activityType == .sailing ? .speed : .altitude }
        }
    }

    private var isClimbing: Bool { activity.activityType == .climbing }

    /// Segments : portions nommées de la trace avec leurs statistiques propres (découpe auto, renommage inline).
    @ViewBuilder
    private var segmentsSection: some View {
        if activity.activityType.tracksDistanceAndSpeed {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionChevron($secSegmentsExpanded)
                    Label("Segments", systemImage: "scissors")
                        .font(.headline)
                    Spacer()
                    if secSegmentsExpanded {
                    if !model.segments.isEmpty {
                        Button("Tout supprimer", role: .destructive) {
                            setSelectedSegment(nil)
                            Task { await model.deleteAllSegments(activityId: activity.id) }
                        }
                        .controlSize(.small)
                    }
                    Menu {
                        Section("Par distance") {
                            Button("Tous les 1 km") { splitSegments(every: 1_000) }
                            Button("Tous les 5 km") { splitSegments(every: 5_000) }
                            Button("Tous les 10 km") { splitSegments(every: 10_000) }
                            Button("Distance personnalisée…") { customSegmentKm = ""; showCustomDistanceSegment = true }
                        }
                        Section("Par dénivelé +") {
                            Button("Tous les 250 m D+") { splitSegmentsByGain(every: 250) }
                            Button("Tous les 500 m D+") { splitSegmentsByGain(every: 500) }
                            Button("Tous les 1000 m D+") { splitSegmentsByGain(every: 1_000) }
                            Button("Dénivelé personnalisé…") { customSegmentGain = ""; showCustomGainSegment = true }
                        }
                        Section("Par temps") {
                            Button("Toutes les 30 min") { splitSegmentsByDuration(every: 1_800) }
                            Button("Toutes les heures") { splitSegmentsByDuration(every: 3_600) }
                            Button("Toutes les 2 heures") { splitSegmentsByDuration(every: 7_200) }
                        }
                        Section("Par phase") {
                            Button("Montées, descentes, pauses") { splitSegmentsByPhase() }
                        }
                    } label: {
                        Label("Découper", systemImage: "scissors")
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .help("Découpe la trace en segments réguliers (remplace les segments existants)")

                    Button {
                        showStagePlanner = true
                    } label: {
                        Label("Planifier des étapes…", systemImage: "flag.checkered")
                    }
                    .controlSize(.small)
                    .help("Mode étapes : segments continus avec jonctions déplaçables, pour planifier un parcours en plusieurs jours")
                    }
                }
                if secSegmentsExpanded {
                    if model.segments.isEmpty {
                        Text("Glissez horizontalement sur le profil pour créer un segment, ou utilisez le menu Découper.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        segmentsTable
                    }
                }
            }
            .task(id: activity.id) { await model.loadSegments(activityId: activity.id) }
            .onChange(of: activity.id) { _, _ in setSelectedSegment(nil) }
            .alert("Découper par distance", isPresented: $showCustomDistanceSegment) {
                TextField("Kilomètres", text: $customSegmentKm)
                Button("Découper") {
                    if let km = Double(customSegmentKm.replacingOccurrences(of: ",", with: ".")), km > 0 {
                        splitSegments(every: km * 1_000)
                    }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Longueur de chaque segment, en kilomètres.")
            }
            .alert("Découper par dénivelé positif", isPresented: $showCustomGainSegment) {
                TextField("Mètres D+", text: $customSegmentGain)
                Button("Découper") {
                    if let m = Double(customSegmentGain.replacingOccurrences(of: ",", with: ".")), m > 0 {
                        splitSegmentsByGain(every: m)
                    }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Dénivelé positif cumulé par segment, en mètres.")
            }
            .sheet(isPresented: $showStagePlanner) {
                StagePlannerSheet(activity: activity, repository: repository) {
                    Task { await model.loadSegments(activityId: activity.id) }
                }
            }
        }
    }

    private var segmentsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Nom").frame(maxWidth: .infinity, alignment: .leading)
                Text("Distance").frame(width: 80, alignment: .trailing)
                Text("D+").frame(width: 70, alignment: .trailing)
                Text("D−").frame(width: 70, alignment: .trailing)
                Text("Durée").frame(width: 85, alignment: .trailing)
                Text("Vitesse moy.").frame(width: 95, alignment: .trailing)
                Color.clear.frame(width: 58, height: 1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ForEach(model.segments) { segment in
                segmentRow(segment)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    /// Ligne du tableau : clic = sélection persistante → segment surligné sur la carte et le profil
    /// (re-clic pour désélectionner). Le clic sur le champ Nom reste réservé au renommage.
    private func segmentRow(_ segment: TrackSegment) -> some View {
        let stats = model.segmentStats[segment.id] ?? .zero
        let isSelected = selectedSegmentId == segment.id
        return HStack(spacing: 0) {
            TextField("Nom", text: segmentNameBinding(segment.id))
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.persistSegments(activityId: activity.id) } }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Renommer le segment (Entrée pour valider)")
            Text(distanceText(stats.distance)).frame(width: 80, alignment: .trailing)
            Text("\(Int(stats.elevationGain.rounded())) m").frame(width: 70, alignment: .trailing)
            Text("\(Int(stats.elevationLoss.rounded())) m").frame(width: 70, alignment: .trailing)
            Text(Self.duration(stats.duration)).frame(width: 85, alignment: .trailing)
            // Pendant une pause, le jitter GPS fabrique une « vitesse en mouvement » absurde → pas de vitesse affichée.
            Text(segment.phase == .pause ? "—" : speedText(stats.avgSpeed)).frame(width: 95, alignment: .trailing)
            Button {
                setSelectedSegment(segment.id)
                fullscreenMap = true
            } label: {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, alignment: .trailing)
            .help("Voir ce segment sur la carte en plein écran (Échap pour revenir)")
            Button {
                if selectedSegmentId == segment.id { setSelectedSegment(nil) }
                Task { await model.deleteSegment(id: segment.id, activityId: activity.id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 30, alignment: .trailing)
            .help("Supprimer ce segment")
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { setSelectedSegment(isSelected ? nil : segment.id) }
        .help(isSelected ? "Cliquer pour désélectionner" : "Cliquer pour surligner ce segment sur la carte et le profil")
    }

    private func setSelectedSegment(_ id: UUID?) {
        selectedSegmentId = id
        selectedSegmentCoords = id.map { model.segmentCoordinates(id: $0) } ?? []
        selectedSegmentRange = id.flatMap { model.segmentDistanceRange(id: $0) }
    }

    private func segmentNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.segments.first(where: { $0.id == id })?.name ?? "" },
            set: { model.setSegmentName(id: id, name: $0) }
        )
    }

    private func splitSegments(every meters: Double) {
        setSelectedSegment(nil)
        Task { await model.splitSegments(every: meters, activityId: activity.id) }
    }

    private func splitSegmentsByDuration(every seconds: TimeInterval) {
        setSelectedSegment(nil)
        Task { await model.splitSegmentsByDuration(every: seconds, activityId: activity.id) }
    }

    /// Mêmes seuils de pause que le profil et les métriques (préférences Général).
    private func splitSegmentsByPhase() {
        setSelectedSegment(nil)
        Task { await model.splitSegmentsByPhase(pauseMinSeconds: pauseThresholdMinutes * 60, pauseRadiusMeters: pauseRadiusMeters, activityId: activity.id) }
    }

    private func splitSegmentsByGain(every meters: Double) {
        setSelectedSegment(nil)
        Task { await model.splitSegmentsByElevationGain(every: meters, activityId: activity.id) }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionChevron($secMapExpanded)
                Label("Carte", systemImage: "map")
                    .font(.headline)
                Spacer()
                if secMapExpanded {
                    if activity.isCourse {
                        Button(routeEditMode ? "Terminer" : "Modifier l'itinéraire") { routeEditMode.toggle() }
                            .controlSize(.small)
                    }
                    if !routeEditMode {
                        TrackColorControl(mode: Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue }))
                            .controlSize(.small)
                        if mapLayerBinding.wrappedValue.isIGN {
                            SlopeOverlayControl(enabled: $slopeOverlayEnabled, opacity: $slopeOverlayOpacity)
                                .controlSize(.small)
                        }
                    }
                    LayerPicker(layer: mapLayerBinding)
                        .controlSize(.small)
                }
            }
            if secMapExpanded {
                if routeEditMode {
                    RouteEditorView(activity: activity, repository: repository, layer: mapLayerBinding, mapHeight: mapHeight) {
                        Task { await listVM.reload() }
                    }
                    mapResizeHandle
                } else {
                    ActivityMapCard(
                        activityId: activity.id,
                        activityType: activity.activityType,
                        repository: repository,
                        layer: mapLayerBinding,
                        highlight: highlightedCoordinate,
                        highlightRange: selectedSegmentCoords,
                        photos: mapPhotos,
                        slopeOverlayOpacity: slopeOverlayEnabled ? slopeOverlayOpacity : 0,
                        trackColorMode: trackColorMode,
                        onFullscreen: { fullscreenMap = true },
                        onSelectPhoto: openPhoto
                    )
                    .frame(height: mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    mapResizeHandle
                }
            }
        }
    }

    /// Poignée de redimensionnement de la hauteur de la carte (glisser vertical), persistée.
    private var mapResizeHandle: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let dy = Double(value.translation.height)
                        mapHeight = min(900, max(180, mapHeight + dy - dragAccumulator))
                        dragAccumulator = dy
                    }
                    .onEnded { _ in dragAccumulator = 0 }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("Glisser pour ajuster la hauteur de la carte")
    }

    /// Plein écran : carte (remplit) au-dessus, profil en volet bas à hauteur réglable — pile verticale,
    /// la carte ne passe pas sous le profil (VStack plutôt que VSplitView qui donne une taille nulle à la carte Metal).
    private var fullscreenMapOverlay: some View {
        VStack(spacing: 0) {
            fsMapPane
            if showFsProfile {
                ProfileResizeHandle { delta in
                    fsProfileHeight = min(560, max(140, fsProfileHeight + Double(delta)))
                }
                fsProfilePane
                    .frame(height: fsProfileHeight)
            }
        }
        // Carte bord-à-bord façon Plan.app : elle passe sous la barre de titre rendue transparente
        // (cf. .toolbarBackground(.hidden) côté fenêtre), les pastilles flottent par-dessus.
        .ignoresSafeArea()
    }

    private var fsMapPane: some View {
        ActivityMapCard(
            activityId: activity.id,
            activityType: activity.activityType,
            repository: repository,
            layer: mapLayerBinding,
            highlight: highlightedCoordinate,
            highlightRange: selectedSegmentCoords,
            photos: mapPhotos,
            slopeOverlayOpacity: slopeOverlayEnabled ? slopeOverlayOpacity : 0,
            trackColorMode: trackColorMode,
            onSelectPhoto: openPhoto
        )
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { fsTopScrim }
        .overlay(alignment: .bottom) { fsControlBar }
    }

    /// Léger dégradé en haut pour garder pastilles + bouton Quitter lisibles sur fond IGN clair.
    private var fsTopScrim: some View {
        LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 96)
            .allowsHitTesting(false)
    }

    /// Contrôles du plein écran, en barre horizontale centrée en bas de la carte.
    private var fsControlBar: some View {
        MapControlCluster(
            layer: mapLayerBinding,
            trackColorMode: Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue }),
            slopeEnabled: $slopeOverlayEnabled,
            slopeOpacity: $slopeOverlayOpacity,
            axis: .horizontal
        ) {
            Button { showFsProfile.toggle() } label: {
                Image(systemName: showFsProfile ? "rectangle.bottomthird.inset.filled" : "rectangle")
                    .padding(7).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).help(showFsProfile ? "Masquer le profil" : "Afficher le profil")
        }
        .padding(.bottom, 12)
    }

    /// Profil plein écran : volet bas (hauteur réglable par la poignée), navigable (survol → marqueur carte).
    private var fsProfilePane: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if !isClimbing {
                    Picker("", selection: $profileMetric) { ForEach(ProfileMetric.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Picker("", selection: $profileMode) { ForEach(ProfileMode.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            ElevationProfileTabView(activityId: activity.id, activityType: activity.activityType, repository: repository, storedGain: activity.elevationGain, storedLoss: activity.elevationLoss, mode: $profileMode, metric: $profileMetric, highlightedCoordinate: $highlightedCoordinate, highlightedDistanceRange: selectedSegmentRange)
                .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private var mapLayerBinding: Binding<MapLayer> {
        Binding(
            get: { MapLayer.base(fromRawValue: defaultLayerRaw) },
            set: { defaultLayerRaw = $0.rawValue }
        )
    }

    private var trackColorMode: TrackColorMode { TrackColorMode(rawValue: trackColorModeRaw) ?? .uniform }

    private static let hiddenPhotosKey = "photosHiddenOnMap"
    private static let shownPhotosKey = "photosShownExplicit"

    /// État de sélection d'une photo : explicite (montrée/cachée) sinon valeur par défaut (préférence).
    /// Source de vérité : `mediaState` (synchronisé) ; repli sur l'ancien état local en attendant la migration.
    private func isPhotoShown(_ id: String) -> Bool {
        if let onMap = placement(for: id)?.onMap { return onMap }
        if shownPhotoIDs.contains(id) { return true }
        if hiddenPhotoIDs.contains(id) { return false }
        return photosSelectedByDefault
    }

    private func placement(for localID: String) -> MediaPlacement? {
        guard let identity = assetIdentity[localID] else { return nil }
        return mediaState[identity.key]
    }

    private func loadMediaState() async {
        let data = try? await repository.fetchMediaState(id: activity.id)
        mediaState = MediaStateCodec.decode(data)
    }

    private func persistMediaState() {
        let data = MediaStateCodec.encode(mediaState)
        let id = activity.id
        Task { try? await repository.updateMediaState(id: id, data: data) }
    }

    /// Calcule l'identité stable (clé nom+date) des assets chargés, puis migre l'ancien état local par localIdentifier.
    private func rebuildAssetIdentity(_ assets: [PHAsset]) {
        var map: [String: (key: String, file: String, date: Double?)] = [:]
        for asset in assets { map[asset.localIdentifier] = PhotoLibraryService.identity(for: asset) }
        assetIdentity = map
        migrateLegacySelection()
    }

    /// Bascule l'ancienne sélection (par localIdentifier, locale à ce Mac) vers `mediaState` (par clé stable, synchronisé).
    /// Ne touche qu'aux entrées encore indécises : `mediaState` (éventuellement venu d'un autre Mac) prime.
    private func migrateLegacySelection() {
        var changed = false
        for (localID, identity) in assetIdentity {
            var p = mediaState[identity.key] ?? MediaPlacement(file: identity.file, date: identity.date)
            var touched = false
            if p.onMap == nil {
                if shownPhotoIDs.contains(localID) { p.onMap = true; touched = true }
                else if hiddenPhotoIDs.contains(localID) { p.onMap = false; touched = true }
            }
            if !p.appCreated, appCreatedAssets.contains(localID) { p.appCreated = true; touched = true }
            if touched, !p.isDefault { mediaState[identity.key] = p; changed = true }
        }
        if changed { persistMediaState() }
    }

    private var mapPhotos: [PhotoMapItem] {
        guard photosOnMapEnabled else { return [] }
        return photoMapItems.filter { isPhotoShown($0.id) }
    }

    private var photosSection: some View {
        ActivityPhotosSection(
            activityId: activity.id,
            repository: repository,
            start: activity.startDate,
            end: activity.endDate,
            assets: $photoAssets,
            showOnMap: $photosOnMapEnabled,
            reloadToken: photosReload,
            isShownOnMap: { isPhotoShown($0) },
            isAppCreated: { isAppCreated($0) },
            isIncoherent: { incoherentPhotoIDs.contains($0) },
            isManuallyPlaced: { placement(for: $0)?.posMeters != nil },
            onToggleMap: togglePhotoOnMap,
            onSelect: previewPhoto,
            onEdit: editMedia,
            onAdjustPosition: adjustPosition,
            onDelete: deleteMedia
        )
        .onChange(of: photoAssets) { _, newAssets in
            rebuildAssetIdentity(newAssets)
            Task { await buildPhotoMapItems(newAssets) }
        }
        .sheet(item: $editingMedia) { media in
            if media.asset.mediaType == .video {
                VideoEditor(
                    asset: media.asset,
                    onCancel: { editingMedia = nil },
                    onExported: { url in saveEditedVideo(from: media.asset, url: url) }
                )
            } else {
                PhotoCropEditor(
                    asset: media.asset,
                    onCancel: { editingMedia = nil },
                    onSave: { jpeg in saveCroppedPhoto(from: media.asset, jpeg: jpeg) }
                )
            }
        }
        .sheet(item: $positioningMedia) { media in
            MediaPositionEditor(
                asset: media.asset,
                activityId: activity.id,
                activityType: activity.activityType,
                repository: repository,
                initialManualMeters: media.manualMeters,
                onSave: { meters in setManualMeters(media.asset, meters); positioningMedia = nil },
                onCancel: { positioningMedia = nil }
            )
        }
    }

    private func adjustPosition(_ asset: PHAsset) {
        positioningMedia = PositioningMedia(id: asset.localIdentifier, asset: asset,
                                            manualMeters: placement(for: asset.localIdentifier)?.posMeters)
    }

    /// Enregistre (ou efface) la position manuelle d'un média dans `mediaState`, puis recalcule la carte.
    private func setManualMeters(_ asset: PHAsset, _ meters: Double?) {
        guard let identity = assetIdentity[asset.localIdentifier] else { return }
        var p = mediaState[identity.key] ?? MediaPlacement(file: identity.file, date: identity.date)
        p.posMeters = meters
        if p.isDefault { mediaState[identity.key] = nil } else { mediaState[identity.key] = p }
        persistMediaState()
        Task { await buildPhotoMapItems(photoAssets) }
    }

    private func togglePhotoOnMap(_ id: String) {
        guard let identity = assetIdentity[id] else { return }
        let newOnMap = !isPhotoShown(id)
        var p = mediaState[identity.key] ?? MediaPlacement(file: identity.file, date: identity.date)
        p.onMap = newOnMap
        mediaState[identity.key] = p
        persistMediaState()
    }

    // MARK: - Édition des médias

    // Ancien marquage local (par localIdentifier) — conservé en lecture seule comme repli de migration.
    private var appCreatedAssets: Set<String> {
        guard let d = appCreatedAssetsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(arr)
    }

    /// Média créé par l'app (donc supprimable) : lu dans `mediaState`, repli sur l'ancien marquage local.
    private func isAppCreated(_ localID: String) -> Bool {
        if let appCreated = placement(for: localID)?.appCreated { return appCreated }
        return appCreatedAssets.contains(localID)
    }

    /// Marque un asset (par son identité stable) comme créé par l'app, dans l'état synchronisé.
    private func markAppCreated(localID: String) {
        guard let asset = PhotoLibraryService.asset(withLocalIdentifier: localID) else { return }
        let identity = PhotoLibraryService.identity(for: asset)
        var p = mediaState[identity.key] ?? MediaPlacement(file: identity.file, date: identity.date)
        p.appCreated = true
        mediaState[identity.key] = p
        persistMediaState()
    }

    private func editMedia(_ asset: PHAsset) {
        editingMedia = EditingMedia(id: asset.localIdentifier, asset: asset)
    }
    private func saveCroppedPhoto(from asset: PHAsset, jpeg: Data) {
        editingMedia = nil
        Task {
            if let id = await PhotoLibraryService.createImageAsset(jpeg: jpeg, creationDate: asset.creationDate, location: asset.location) {
                markAppCreated(localID: id)
            }
            photosReload += 1
        }
    }
    private func saveEditedVideo(from asset: PHAsset, url: URL) {
        editingMedia = nil
        Task {
            if let id = await PhotoLibraryService.createVideoAsset(fileURL: url, creationDate: asset.creationDate, location: asset.location) {
                markAppCreated(localID: id)
            }
            try? FileManager.default.removeItem(at: url)
            photosReload += 1
        }
    }

    private func deleteMedia(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let key = assetIdentity[id]?.key
        Task {
            if await PhotoLibraryService.deleteAssets([id]) {
                if let key { mediaState[key] = nil; persistMediaState() }
                photosReload += 1
            }
        }
    }

    private func previewPhoto(_ asset: PHAsset) {
        Task { previewURL = await PhotoLibraryService.exportForPreview(asset) }
    }

    private var videoFormat: VideoFormat { VideoFormat(rawValue: videoFormatRaw) ?? .landscape }
    private var videoTransitionBinding: Binding<MediaTransition> {
        Binding(get: { MediaTransition(rawValue: videoTransitionRaw) ?? .fade }, set: { videoTransitionRaw = $0.rawValue })
    }
    private var videoMapLayerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer(rawValue: videoMapLayerRaw) ?? .ignScan25 }, set: { videoMapLayerRaw = $0.rawValue })
    }
    private var videoQualityBinding: Binding<VideoQuality> {
        Binding(get: { VideoQuality(rawValue: videoQualityRaw) ?? .hd720 }, set: { videoQualityRaw = $0.rawValue })
    }
    private var videoFormatBinding: Binding<VideoFormat> {
        Binding(get: { videoFormat }, set: { newFormat in
            videoFormatRaw = newFormat.rawValue
            currentLayout = VideoLayout.defaultLayout(for: newFormat)
        })
    }
    private var profileOnBinding: Binding<Bool> {
        Binding(get: { currentLayout.profile != nil }, set: { on in
            if on {
                if currentLayout.profile == nil {
                    currentLayout.profile = VideoLayout.defaultLayout(for: videoFormat).profile ?? LayoutZone(x: 0.6, y: 0.74, w: 0.38, h: 0.22)
                }
            } else {
                currentLayout.profile = nil
            }
        })
    }

    // MARK: - Modèles (templates)

    private var userTemplates: [VideoTemplate] {
        guard let d = userTemplatesJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([VideoTemplate].self, from: d) else { return [] }
        return arr
    }
    private func setUserTemplates(_ arr: [VideoTemplate]) {
        if let d = try? JSONEncoder().encode(arr), let s = String(data: d, encoding: .utf8) { userTemplatesJSON = s }
    }
    private var allTemplates: [VideoTemplate] { VideoTemplate.builtins + userTemplates }
    private var selectedTemplate: VideoTemplate? { allTemplates.first { $0.id == selectedTemplateID } }
    private var currentMatchesTemplate: Bool {
        guard let t = selectedTemplate else { return false }
        return t.quality.rawValue == videoQualityRaw && t.format.rawValue == videoFormatRaw && t.layout == currentLayout
            && t.transition.rawValue == videoTransitionRaw && t.showHeartRate == videoHeartRateOn
            && t.showIntro == videoIntroOn && t.showOutro == videoOutroOn && t.mapLayerRaw == videoMapLayerRaw
    }
    private func currentTemplate(id: String, name: String, builtin: Bool) -> VideoTemplate {
        VideoTemplate(id: id, name: name, quality: VideoQuality(rawValue: videoQualityRaw) ?? .hd720,
                      format: videoFormat, layout: currentLayout, builtin: builtin,
                      transition: MediaTransition(rawValue: videoTransitionRaw) ?? .fade,
                      showHeartRate: videoHeartRateOn, showIntro: videoIntroOn, showOutro: videoOutroOn,
                      mapLayerRaw: videoMapLayerRaw)
    }
    private func applyTemplate(_ t: VideoTemplate) {
        videoQualityRaw = t.quality.rawValue
        videoFormatRaw = t.format.rawValue
        currentLayout = t.layout
        videoTransitionRaw = t.transition.rawValue
        videoHeartRateOn = t.showHeartRate
        videoIntroOn = t.showIntro
        videoOutroOn = t.showOutro
        videoMapLayerRaw = t.mapLayerRaw
        selectedTemplateID = t.id
    }
    private func saveAsNewTemplate(name: String) {
        let t = currentTemplate(id: "user.\(UUID().uuidString)", name: name, builtin: false)
        setUserTemplates(userTemplates + [t])
        selectedTemplateID = t.id
    }
    private func updateSelectedTemplate() {
        guard let sel = selectedTemplate, !sel.builtin else { return }
        let t = currentTemplate(id: sel.id, name: sel.name, builtin: false)
        setUserTemplates(userTemplates.map { $0.id == t.id ? t : $0 })
    }
    private func renameSelectedTemplate(_ name: String) {
        guard var t = selectedTemplate, !t.builtin else { return }
        t.name = name
        setUserTemplates(userTemplates.map { $0.id == t.id ? t : $0 })
    }
    private func deleteSelectedTemplate() {
        guard let t = selectedTemplate, !t.builtin else { return }
        setUserTemplates(userTemplates.filter { $0.id != t.id })
        applyTemplate(VideoTemplate.builtins[0])
    }

    private func persistCurrentLayout() {
        let data = try? JSONEncoder().encode(currentLayout)
        Task { try? await repository.updateVideoLayoutData(id: activity.id, data: data) }
    }


    private func loadTracePreview() async {
        guard let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data), points.count >= 2 else { tracePreview = []; return }
        let mps = points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let minX = mps.map(\.x).min()!, maxX = mps.map(\.x).max()!
        let minY = mps.map(\.y).min()!, maxY = mps.map(\.y).max()!
        let sc = Swift.max(1, Swift.max(maxX - minX, maxY - minY)) // échelle unique → forme conservée
        let step = Swift.max(1, mps.count / 400)
        tracePreview = stride(from: 0, to: mps.count, by: step).map { i in
            CGPoint(x: (mps[i].x - minX) / sc, y: (mps[i].y - minY) / sc) // origine haut-gauche
        }
    }

    private var videoOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Créer la vidéo du parcours").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("MODÈLE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                templateBar
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.15)))
            Divider()
            HStack(spacing: 16) {
                Picker("Qualité", selection: videoQualityBinding) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                }.fixedSize()
                Picker("Format", selection: videoFormatBinding) {
                    ForEach(VideoFormat.allCases) { Text($0.label).tag($0) }
                }.fixedSize()
                Picker("Animation", selection: videoTransitionBinding) {
                    ForEach(MediaTransition.allCases) { Text($0.label).tag($0) }
                }.fixedSize()
                Spacer()
            }
            HStack(spacing: 18) {
                Toggle("Profil altimétrique", isOn: profileOnBinding)
                Toggle("Fréquence cardiaque", isOn: $videoHeartRateOn)
                    .disabled(currentLayout.profile == nil)
                Toggle("Carton de début", isOn: $videoIntroOn)
                Toggle("Carton de fin", isOn: $videoOutroOn)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Fond de carte").font(.callout)
                LayerPicker(layer: videoMapLayerBinding)
                Spacer()
                Text("Destination").font(.callout)
                Picker("", selection: $videoPublish) {
                    Text("Fichier").tag(false)
                    Text("GPXManagement.net").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if videoPublish && !BunnyStorageService.isConfigured {
                Text("⚠︎ Bunny non configuré (renseigner Secrets.xcconfig).").font(.caption2).foregroundStyle(.orange)
            }
            Text("Glissez les zones pour les déplacer, la poignée (coin) pour les redimensionner. Carton titre+date au début, résumé à la fin.")
                .font(.caption).foregroundStyle(.secondary)
            VideoLayoutEditor(aspect: videoFormat.aspect, layout: $currentLayout, tracePoints: tracePreview)
            HStack {
                Button("Réinitialiser") { currentLayout = VideoLayout.defaultLayout(for: videoFormat) }
                Spacer()
                Button("Annuler") { showVideoOptions = false }
                Button(videoPublish ? "Créer et publier" : "Créer la vidéo") {
                    showVideoOptions = false
                    persistCurrentLayout()
                    exportVideo(publish: videoPublish)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(videoPublish && !BunnyStorageService.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task {
            if let t = selectedTemplate { applyTemplate(t) } else { applyTemplate(VideoTemplate.builtins[0]) }
            await loadTracePreview()
            if let data = try? await repository.fetchVideoLayoutData(id: activity.id),
               let layout = try? JSONDecoder().decode(VideoLayout.self, from: data) {
                currentLayout = layout
            }
        }
        .alert(savingNewTemplate ? "Nouveau modèle" : "Renommer le modèle", isPresented: $showTemplateNameAlert) {
            TextField("Nom du modèle", text: $templateNameInput)
            Button(savingNewTemplate ? "Enregistrer" : "Renommer") {
                let name = templateNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if savingNewTemplate { saveAsNewTemplate(name: name) } else { renameSelectedTemplate(name) }
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var templateBar: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Prédéfinis") {
                    ForEach(VideoTemplate.builtins) { t in
                        Button { applyTemplate(t) } label: { CheckmarkLabel(t.name, selected: t.id == selectedTemplateID) }
                    }
                }
                if !userTemplates.isEmpty {
                    Section("Mes modèles") {
                        ForEach(userTemplates) { t in
                            Button { applyTemplate(t) } label: { CheckmarkLabel(t.name, selected: t.id == selectedTemplateID) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                    Text(selectedTemplate?.name ?? "Modèle")
                    if !currentMatchesTemplate { Text("• modifié").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .fixedSize()

            Spacer()

            Button("Enregistrer sous…") {
                savingNewTemplate = true
                templateNameInput = (selectedTemplate?.name).map { "\($0) copie" } ?? "Mon modèle"
                showTemplateNameAlert = true
            }
            if let t = selectedTemplate, !t.builtin {
                Button("Mettre à jour") { updateSelectedTemplate() }
                    .disabled(currentMatchesTemplate)
                Menu {
                    Button("Renommer…") { savingNewTemplate = false; templateNameInput = t.name; showTemplateNameAlert = true }
                    Button("Supprimer", role: .destructive) { deleteSelectedTemplate() }
                } label: { Image(systemName: "ellipsis.circle") }
                .fixedSize()
            }
        }
    }

    private func videoSummaryLines() -> [(label: String, value: String)] {
        var lines: [(String, String)] = [
            ("Distance", distanceText(activity.distance)),
            ("Durée", Self.duration(activity.duration)),
            // Mêmes temps que l'app et l'export web : partition pause/montée/descente/à plat
            // (timeBreakdown, chargée par le view model), pas la stat movingDuration stockée.
            ("En mouvement", Self.duration(model.movingTime ?? activity.movingDuration))
        ]
        if let pause = model.pausedTime { lines.append(("En pause", Self.duration(pause))) }
        if let up = model.ascentTime { lines.append(("Temps en montée", Self.duration(up))) }
        if let down = model.descentTime { lines.append(("Temps en descente", Self.duration(down))) }
        if let flat = model.flatTime { lines.append(("Temps à plat", Self.duration(flat))) }
        lines.append(contentsOf: [
            ("Dénivelé +", "\(Int(activity.elevationGain.rounded())) m"),
            ("Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m"),
            ("Vitesse moy.", speedText(activity.avgSpeed)),
            ("Vitesse max", speedText(activity.maxSpeed))
        ])
        if let hr = activity.avgHeartRate { lines.append(("FC moyenne", "\(Int(hr.rounded())) bpm")) }
        if let hr = activity.maxHeartRate { lines.append(("FC max", "\(Int(hr.rounded())) bpm")) }
        return lines
    }

    private func exportVideo(publish: Bool) {
        let quality = VideoQuality(rawValue: videoQualityRaw) ?? .hd720
        let dims = videoFormat.dimensions(base: quality.base)
        let layout = currentLayout

        let url: URL
        if publish {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("film-\(UUID().uuidString).mp4")
        } else {
            let panel = NSSavePanel()
            panel.title = "Enregistrer la vidéo du parcours"
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = activity.title.replacingOccurrences(of: "/", with: "-") + ".mp4"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        Task {
            isExportingVideo = true
            videoProgress = 0
            defer { isExportingVideo = false }

            guard let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
                  let points = try? TrackPointCodec.decode(data) else {
                exportError = "Cette activité n'a pas de tracé exploitable."
                return
            }

            // Titre relu depuis Core Data : prend le renommage le plus récent, même si la fenêtre porte un résumé en cache.
            let currentTitle = (try? await repository.fetchTitle(id: activity.id)) ?? activity.title
            let config = VideoConfig(
                width: dims.width,
                height: dims.height,
                layout: layout,
                transition: MediaTransition(rawValue: videoTransitionRaw) ?? .fade,
                showHeartRate: videoHeartRateOn && layout.profile != nil,
                showIntro: videoIntroOn,
                showOutro: videoOutroOn,
                mapLayer: MapLayer(rawValue: videoMapLayerRaw) ?? .ignScan25,
                title: currentTitle,
                dateText: Self.formatDate(activity.startDate),
                summary: videoSummaryLines()
            )

            // Médias sélectionnés (épingle active) et géolocalisés.
            var media: [TrackVideoMedia] = []
            for asset in photoAssets where isPhotoShown(asset.localIdentifier) {
                let manual = placement(for: asset.localIdentifier)?.posMeters
                guard let coord = PhotoLibraryService.resolvedCoordinate(for: asset, in: points, manualMeters: manual) else { continue }
                let thumb = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 160, height: 160))
                if asset.mediaType == .video {
                    if let av = await PhotoLibraryService.avAsset(for: asset) {
                        media.append(.video(asset: av, thumbnail: thumb, coordinate: coord, date: asset.creationDate, manualMeters: manual))
                    }
                } else if let image = await PhotoLibraryService.fullImage(for: asset) {
                    media.append(.photo(image: image, thumbnail: thumb, coordinate: coord, date: asset.creationDate, manualMeters: manual))
                }
            }

            do {
                try await TrackVideoExporter.export(points: points, media: media, config: config, to: url) { fraction in
                    Task { @MainActor in videoProgress = publish ? fraction * 0.5 : fraction }
                }
                if publish {
                    await publishVideo(localURL: url, title: currentTitle)
                    try? FileManager.default.removeItem(at: url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// Upload le film sur Bunny Storage + une page wrapper `<video>`, puis ouvre/copie l'URL publique.
    private func publishVideo(localURL: URL, title: String) async {
        guard let data = try? Data(contentsOf: localURL) else { exportError = "Vidéo introuvable après le rendu."; return }
        let folder = "films/\(activity.id.uuidString.lowercased())"
        let html = Self.videoPageHTML(title: title, dateText: Self.formatDate(activity.startDate))
        let files: [String: Data] = ["film.mp4": data, "index.html": Data(html.utf8)]
        do {
            try await BunnyStorageService.publish(files: files, folder: folder) { f, s in
                Task { @MainActor in videoProgress = 0.5 + f * 0.5 }
            }
            let urlStr = "https://www.gpxmanagement.net/\(folder)/"
            try? await repository.setFilmPublished(id: activity.id, url: urlStr)
            model.filmPublishedURL = urlStr
            if let u = URL(string: urlStr) {
                NSWorkspace.shared.open(u)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlStr, forType: .string)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Page HTML minimale hébergeant le film (lecteur natif).
    private static func videoPageHTML(title: String, dateText: String) -> String {
        let safe = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safe)</title>
        <style>
          :root { color-scheme: dark; }
          body { margin:0; background:#0b0b0c; color:#eee; font:15px -apple-system,system-ui,sans-serif; display:flex; flex-direction:column; min-height:100vh; }
          header { padding:14px 18px; }
          h1 { font-size:18px; margin:0; }
          .date { color:#9a9a9e; font-size:13px; margin-top:2px; }
          main { flex:1; display:flex; align-items:center; justify-content:center; padding:12px; }
          video { max-width:100%; max-height:84vh; border-radius:10px; box-shadow:0 10px 40px rgba(0,0,0,0.5); background:#000; }
          footer { padding:10px 18px; color:#6a6a6e; font-size:12px; }
        </style></head>
        <body>
          <header><h1>\(safe)</h1><div class="date">\(safe.isEmpty ? "" : dateText)</div></header>
          <main><video src="film.mp4" controls playsinline preload="metadata"></video></main>
          <footer>GPXManagement</footer>
        </body></html>
        """
    }

    /// Construit les vignettes à placer sur la carte (coordonnée GPS + miniature) depuis les photos trouvées.
    private func buildPhotoMapItems(_ assets: [PHAsset]) async {
        var points: [TrackPoint] = []
        if let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
           let decoded = try? TrackPointCodec.decode(data) {
            points = decoded
        }
        let resolver = MediaTrackResolver(points: points)
        var items: [PhotoMapItem] = []
        var incoherent: Set<String> = []
        for asset in assets {
            let manual = placement(for: asset.localIdentifier)?.posMeters
            // Incohérence : heure et GPS désignent des points éloignés (> 150 m) et l'utilisateur n'a pas tranché.
            if manual == nil, let c = asset.location?.coordinate,
               let gap = resolver.timeGpsDiscrepancy(captureDate: asset.creationDate, gpsLatitude: c.latitude, gpsLongitude: c.longitude),
               gap > 150 {
                incoherent.insert(asset.localIdentifier)
            }
            guard let coord = PhotoLibraryService.resolvedCoordinate(for: asset, using: resolver, manualMeters: manual) else { continue }
            let thumb = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 120, height: 120))
            items.append(PhotoMapItem(id: asset.localIdentifier, coordinate: coord, image: thumb, isVideo: asset.mediaType == .video))
        }
        incoherentPhotoIDs = incoherent
        photoMapItems = items
    }

    private func openPhoto(id: String) {
        if let asset = photoAssets.first(where: { $0.localIdentifier == id }) {
            previewPhoto(asset)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionChevron($secNotesExpanded)
                Label("Notes", systemImage: "note.text").font(.headline)
                Spacer()
                if secNotesExpanded {
                    Button("Enregistrer") {
                        Task { await listVM.updateNotes(id: activity.id, notes: notesDraft) }
                    }
                    .disabled(notesDraft == (activity.notes ?? ""))
                }
            }
            if secNotesExpanded {
            TextEditor(text: $notesDraft)
                .frame(minHeight: 100)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            Label {
                Text(sourceLineText)
            } icon: {
                Image(systemName: activity.source.symbolName)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("Fichier source : \(activity.sourceFileFormat.rawValue.uppercased()) · \(activity.sourceFileName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var sourceLineText: String {
        let category = activity.source.displayName
        if let raw = activity.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != category {
            return "Source : \(category) · \(raw)"
        }
        return "Source : \(category)"
    }

    private var hasExportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private func exportGPX() async {
        do {
            _ = try await ExportService.exportGPX(activity: activity, repository: repository)
        } catch ExportError.userCancelled {
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var webExportOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporter en page web").font(.title3.bold())
            Text("Génère une page de présentation reprenant le contenu du détail (carte, profil, statistiques, photos, notes), prête à déposer sur un CDN.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Carte").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("", selection: $webOptions.map) {
                            ForEach(WebExportOptions.MapRendering.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(maxWidth: .infinity)
                        if webOptions.map == .interactive {
                            Text("Carte Leaflet + tuiles IGN, chargées en ligne (nécessite une connexion).").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("Profil").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("", selection: $webOptions.profile) {
                            ForEach(WebExportOptions.ProfileRendering.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(maxWidth: .infinity)
                        if webOptions.profile == .interactive {
                            Text("Survol synchronisé avec la carte (si interactive), bascule distance/temps.").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("Destination").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("", selection: $webOptions.output) {
                            ForEach(WebExportOptions.Output.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(maxWidth: .infinity)
                        if webOptions.output == .publishBunny {
                            if BunnyStorageService.isConfigured {
                                Text(model.publishedURL == nil
                                     ? "Publie la page sur gpxmanagement.net et enregistre le lien."
                                     : "Re-publie sur le lien existant (écrase le contenu).")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                Text("⚠︎ Bunny non configuré (renseigner Secrets.xcconfig).")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Photos").gridColumnAlignment(.trailing)
                    Toggle("Inclure les photos du parcours", isOn: $webOptions.includePhotos)
                }
                GridRow {
                    Text("Notes").gridColumnAlignment(.trailing)
                    Toggle("Inclure les notes", isOn: $webOptions.includeNotes)
                }
            }

            HStack {
                Spacer()
                Button("Annuler") { showWebExportOptions = false }
                Button(webOptions.output == .publishBunny ? "Publier" : "Générer la page") {
                    showWebExportOptions = false
                    Task { await exportWeb() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(webOptions.output == .publishBunny && !BunnyStorageService.isConfigured)
            }
        }
        .padding(24)
        .frame(width: 660)
    }

    private func exportWeb() async {
        isExportingWeb = true
        let progress = WebExportProgress.shared
        progress.begin("Génération de la page…")
        defer { isExportingWeb = false; progress.end() }
        let layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25
        // Seules les photos sélectionnées (affichées sur la carte) sont exportées.
        let photos = webOptions.includePhotos ? photoAssets.filter { isPhotoShown($0.localIdentifier) } : []
        let safeName = activity.title.replacingOccurrences(of: "/", with: "-")
        do {
            let output = try await HTMLReportRenderer.render(activity: activity, repository: repository, layer: layer, options: webOptions, photos: photos)
            progress.update(0.6, "Préparation des fichiers…")
            switch output {
            case .folder(let files):
                if webOptions.output == .publishBunny {
                    try await publishToBunny(files: files) { f, s in progress.update(0.6 + f * 0.4, s) }
                } else {
                    let panel = NSSavePanel()
                    panel.title = "Exporter le dossier de la page web"
                    panel.nameFieldStringValue = safeName
                    guard panel.runModal() == .OK, let dir = panel.url else { return }
                    try? FileManager.default.removeItem(at: dir)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (rel, data) in files {
                        let fileURL = dir.appendingPathComponent(rel)
                        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: fileURL, options: .atomic)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func publishToBunny(files: [String: Data], onProgress: ((Double, String) -> Void)? = nil) async throws {
        let uuid = model.existingPublishUUID() ?? UUID().uuidString.lowercased()
        try await BunnyStorageService.publish(files: files, folder: "traces/\(uuid)", onProgress: onProgress)
        let url = "https://www.gpxmanagement.net/traces/\(uuid)/"
        let configJSON = (try? JSONEncoder().encode(webOptions)).flatMap { String(data: $0, encoding: .utf8) }
        try await repository.setWebPublished(id: activity.id, url: url, configJSON: configJSON)
        model.publishedURL = url
        model.publishConfigJSON = configJSON
    }


    /// Retire la publication web : supprime le dossier Bunny + efface le lien stocké.
    private func unpublishWeb() async {
        guard let uuid = model.existingPublishUUID() else { return }
        isUnpublishingWeb = true
        defer { isUnpublishingWeb = false }
        do {
            try await BunnyStorageService.unpublish(folder: "traces/\(uuid)")
            try await repository.clearWebPublished(id: activity.id)
            model.publishedURL = nil
            model.publishConfigJSON = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Republie avec les paramètres de la publication d'origine (même UUID via le lien stocké).
    private func republishWeb() async {
        if let json = model.publishConfigJSON, let data = json.data(using: .utf8),
           var opts = try? JSONDecoder().decode(WebExportOptions.self, from: data) {
            opts.output = .publishBunny
            webOptions = opts
        } else {
            webOptions.output = .publishBunny
        }
        await exportWeb()
    }


    private func exportPDF() async {
        isExportingPDF = true
        defer { isExportingPDF = false }
        let layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25
        do {
            let data = try await PDFReportRenderer.render(activity: activity, repository: repository, layer: layer)
            let panel = NSSavePanel()
            panel.title = "Exporter en PDF"
            panel.nameFieldStringValue = "\(activity.title.replacingOccurrences(of: "/", with: "-")).pdf"
            panel.allowedContentTypes = [.pdf]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func prepareShare() async {
        do {
            shareURL = try await ExportService.prepareShareGPX(activity: activity, repository: repository)
            isShareSheetPresented = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: d)
    }

    private static func timeOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// Distance dans l'unité de l'activité (milles nautiques pour la voile, sinon km/m).
    private func distanceText(_ m: Double) -> String {
        if activity.activityType.usesNauticalUnits { return String(format: "%.2f NM", m / 1852) }
        return m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m"
    }

    /// Vitesse dans l'unité de l'activité (nœuds pour la voile, sinon km/h).
    private func speedText(_ mps: Double) -> String {
        let kmh = mps * 3.6
        if activity.activityType.usesNauticalUnits { return String(format: "%.1f nœuds", kmh / 1.852) }
        return String(format: "%.1f km/h", kmh)
    }

    private static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m"
    }

    private static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, sec)
    }

    private static func speed(_ mps: Double) -> String {
        String(format: "%.1f km/h", mps * 3.6)
    }
}

/// Poignée de redimensionnement isolée : suit le curseur pendant le drag (état local, pas de re-render
/// du parent), et ne communique la variation de hauteur qu'au lâcher.

/// Découpe une trace en deux : carte + slider de position + marqueur, puis crée deux activités dérivées.
struct SplitTrackSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var cumulative: [Double] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var fraction: Double = 0.5

    private var totalDistance: Double { cumulative.last ?? 0 }

    private var splitIndex: Int {
        guard points.count > 2, totalDistance > 0 else { return max(1, points.count / 2) }
        let target = fraction * totalDistance
        let idx = cumulative.firstIndex(where: { $0 >= target }) ?? (points.count - 1)
        return min(max(idx, 1), points.count - 2)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Découper la trace").font(.headline)
                Spacer()
            }
            .padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 4 {
                ContentUnavailableView("Trace trop courte", systemImage: "scissors",
                                       description: Text("Pas assez de points pour découper cette trace."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: coordinates).stroke(.blue, lineWidth: 3)
                    if coordinates.indices.contains(splitIndex) {
                        Annotation("Découpe", coordinate: coordinates[splitIndex]) {
                            Image(systemName: "scissors.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .background(Circle().fill(.white))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
            }
        }
        .frame(width: 660, height: 580)
        .task { await load() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Slider(value: $fraction, in: 0...1)
            HStack {
                let km = (splitIndex < cumulative.count ? cumulative[splitIndex] : 0) / 1000
                Text(String(format: "À %.2f km — point %d sur %d", km, splitIndex + 1, points.count))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Annuler") { dismiss() }
                Spacer()
                Button {
                    Task {
                        isWorking = true
                        let ok = await AppServices.shared.splitActivity(parent: activity, at: splitIndex)
                        isWorking = false
                        if ok { dismiss() }
                    }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Découper en deux", systemImage: "scissors")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding()
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id),
              let pts = try? TrackPointCodec.decode(data) else { return }
        var cum = [Double]()
        cum.reserveCapacity(pts.count)
        var total = 0.0
        for (i, p) in pts.enumerated() {
            if i > 0 { total += Self.haversine(pts[i - 1], p) }
            cum.append(total)
        }
        points = pts
        cumulative = cum
    }

    private static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

/// Simplifie une trace (Douglas-Peucker) : aperçu trace originale (gris) / simplifiée (bleu) + compteur.
struct SimplifyTrackSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var tolerance: Double = 10

    private var simplified: [TrackPoint] { TrackOperations.simplify(points: points, tolerance: tolerance) }
    private var originalCoords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    private var simplifiedCoords: [CLLocationCoordinate2D] { simplified.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    private var reduction: Int { points.isEmpty ? 0 : Int((1 - Double(simplified.count) / Double(points.count)) * 100) }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Simplifier la trace").font(.headline); Spacer() }.padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 4 {
                ContentUnavailableView("Trace trop courte", systemImage: "scribble",
                                       description: Text("Pas assez de points pour simplifier.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: originalCoords).stroke(.gray.opacity(0.5), lineWidth: 5)
                    MapPolyline(coordinates: simplifiedCoords).stroke(.blue, lineWidth: 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    HStack {
                        Text("Tolérance").foregroundStyle(.secondary)
                        Slider(value: $tolerance, in: 0...50)
                        Text(String(format: "%.0f m", tolerance)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Points : \(points.count) → \(simplified.count) (réduction \(reduction) %)")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        Button("Annuler") { dismiss() }
                        Spacer()
                        Button {
                            Task { isWorking = true; let ok = await AppServices.shared.simplifyActivity(parent: activity, tolerance: tolerance); isWorking = false; if ok { dismiss() } }
                        } label: {
                            if isWorking { ProgressView().controlSize(.small) } else { Label("Appliquer", systemImage: "scribble") }
                        }
                        .buttonStyle(.borderedProminent).disabled(isWorking)
                    }
                }
                .padding()
            }
        }
        .frame(width: 660, height: 580)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) else { return }
        points = pts
    }
}

/// Fusionne ≥ 2 traces : aperçu + ordre de raccordement + sens par trace (départ vert / arrivée rouge).
struct MergeTracksSheet: View {
    let activities: [ActivitySummary]
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id: UUID
        let summary: ActivitySummary
        let points: [TrackPoint]
        var reversed: Bool = false
        var coords: [CLLocationCoordinate2D] {
            let c = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return reversed ? c.reversed() : c
        }
        var orientedPoints: [TrackPoint] { reversed ? TrackOperations.reverse(points: points) : points }
    }

    @State private var items: [Item] = []
    @State private var isLoading = true
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Fusionner \(activities.count) traces").font(.headline); Spacer() }.padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    ForEach(items) { item in
                        MapPolyline(coordinates: item.coords).stroke(.blue, lineWidth: 2)
                        if let start = item.coords.first {
                            Annotation("", coordinate: start) { marker(.green) }
                        }
                        if let end = item.coords.last {
                            Annotation("", coordinate: end) { marker(.red) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                trackList
            }
        }
        .frame(width: 680, height: 660)
        .task { await load() }
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 11, height: 11).overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private var trackList: some View {
        VStack(spacing: 8) {
            Text("Ordre de raccordement — vert = départ, rouge = arrivée")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.summary.title).lineLimit(1)
                                Text(item.reversed ? "sens inversé" : "sens d'origine")
                                    .font(.caption2).foregroundStyle(item.reversed ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Button { items[idx].reversed.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }
                                .help("Inverser le sens de cette trace")
                            Button { move(idx, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(idx == 0)
                            Button { move(idx, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(idx == items.count - 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxHeight: 150)
            Divider()
            HStack {
                Button("Annuler") { dismiss() }
                Spacer()
                Button {
                    Task {
                        isWorking = true
                        let points = items.flatMap { $0.orientedPoints }
                        let ok = await AppServices.shared.saveMergedActivity(points: points, parents: items.map { $0.summary })
                        isWorking = false
                        if ok { dismiss() }
                    }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Label("Fusionner", systemImage: "arrow.triangle.merge") }
                }
                .buttonStyle(.borderedProminent).disabled(isWorking || items.count < 2)
            }
        }
        .padding()
    }

    private func move(_ idx: Int, by offset: Int) {
        let target = idx + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(idx, target)
    }

    private func load() async {
        defer { isLoading = false }
        let sorted = activities.sorted { $0.startDate < $1.startDate }
        var result: [Item] = []
        for a in sorted {
            if let data = try? await repository.fetchTrackData(id: a.id), let pts = try? TrackPointCodec.decode(data) {
                result.append(Item(id: a.id, summary: a, points: pts))
            }
        }
        items = result
    }
}

/// Nettoie les points aberrants : points retirés en rouge sur la carte + slider seuil de vitesse + compteur.
struct CleanTrackSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var maxSpeedKmh: Double = 200

    private var maxSpeedMps: Double { maxSpeedKmh / 3.6 }
    private var result: TrackOperations.CleanResult { TrackOperations.cleanOutliers(points: points, maxSpeed: maxSpeedMps) }
    private var coords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Nettoyer les points aberrants").font(.headline); Spacer() }.padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 3 {
                ContentUnavailableView("Trace trop courte", systemImage: "sparkles",
                                       description: Text("Pas assez de points.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 2)
                    ForEach(result.removedIndices, id: \.self) { idx in
                        if coords.indices.contains(idx) {
                            Annotation("", coordinate: coords[idx]) {
                                Circle().fill(.red).frame(width: 9, height: 9).overlay(Circle().stroke(.white, lineWidth: 1))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    HStack {
                        Text("Vitesse max").foregroundStyle(.secondary)
                        Slider(value: $maxSpeedKmh, in: 50...400)
                        Text(String(format: "%.0f km/h", maxSpeedKmh)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    HStack {
                        Text("\(result.removedIndices.count) point(s) seront retirés")
                            .font(.callout).foregroundStyle(result.removedIndices.isEmpty ? Color.secondary : Color.red)
                        Spacer()
                    }
                    HStack {
                        Button("Annuler") { dismiss() }
                        Spacer()
                        Button {
                            Task { isWorking = true; let ok = await AppServices.shared.cleanActivity(parent: activity, maxSpeed: maxSpeedMps); isWorking = false; if ok { dismiss() } }
                        } label: {
                            if isWorking { ProgressView().controlSize(.small) } else { Label("Appliquer", systemImage: "sparkles") }
                        }
                        .buttonStyle(.borderedProminent).disabled(isWorking || result.removedIndices.isEmpty)
                    }
                }
                .padding()
            }
        }
        .frame(width: 660, height: 580)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) else { return }
        points = pts
    }
}

/// Planification d'étapes : partition continue de la trace en étapes, jonctions déplaçables sur le profil
/// (aimant sur les points), ajout/fusion, stats par étape. Enregistre des segments « Étape k » contigus.
struct StagePlannerSheet: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var points: [TrackPoint] = []
    @State private var dists: [Double] = []       // distance cumulée par point (m)
    @State private var alts: [Double] = []        // altitude par point (report si absente)
    @State private var cumGain: [Double] = []     // D+ cumulé par point (EMA + hystérésis, comme les stats)
    @State private var junctions: [Int] = []      // indices de coupe intérieurs, triés
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var grabbed: Int?

    private var boundaries: [Int] { points.isEmpty ? [] : [0] + junctions + [points.count - 1] }
    private var stageCount: Int { max(0, boundaries.count - 1) }
    private var totalDistance: Double { dists.last ?? 0 }
    private var coords: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }

    private struct PlotPoint: Identifiable { let id: Int; let km: Double; let alt: Double }
    private var plot: [PlotPoint] {
        guard !points.isEmpty else { return [] }
        let step = max(1, points.count / 800)
        var result: [PlotPoint] = []
        var i = 0
        while i < points.count { result.append(PlotPoint(id: i, km: dists[i] / 1000, alt: alts[i])); i += step }
        let last = points.count - 1
        if result.last?.id != last { result.append(PlotPoint(id: last, km: dists[last] / 1000, alt: alts[last])) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Planifier les étapes").font(.headline)
                Spacer()
                Text("\(stageCount) étape(s)").foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if points.count < 3 {
                ContentUnavailableView("Trace trop courte", systemImage: "flag.checkered",
                                       description: Text("Pas assez de points pour planifier des étapes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mapView.frame(height: 240)
                profileView.frame(height: 180).padding(.horizontal)
                controls
            }
        }
        .frame(width: 740, height: 760)
        .task { await load() }
    }

    private var mapView: some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 2)
            if let s = coords.first { Annotation("", coordinate: s) { dot(.green) } }
            if let e = coords.last { Annotation("", coordinate: e) { dot(.red) } }
            ForEach(Array(junctions.enumerated()), id: \.element) { k, j in
                if coords.indices.contains(j) {
                    Annotation("", coordinate: coords[j]) {
                        Text("\(k + 1)")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Circle().fill(.orange)).overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                }
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 11, height: 11).overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private var profileView: some View {
        Chart {
            ForEach(plot) { p in
                AreaMark(x: .value("km", p.km), y: .value("alt", p.alt))
                    .foregroundStyle(.blue.opacity(0.15))
            }
            ForEach(plot) { p in
                LineMark(x: .value("km", p.km), y: .value("alt", p.alt))
                    .foregroundStyle(.blue)
            }
            ForEach(Array(junctions.enumerated()), id: \.element) { _, j in
                RuleMark(x: .value("km", dists[j] / 1000))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in onDrag(start: v.startLocation, current: v.location, proxy: proxy, geo: geo) }
                            .onEnded { _ in grabbed = nil }
                    )
            }
        }
    }

    private func onDrag(start: CGPoint, current: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard !junctions.isEmpty, let plotFrame = proxy.plotFrame else { return }
        let rect = geo[plotFrame]
        func meters(atX x: CGFloat) -> Double? {
            let xIn = min(max(x - rect.origin.x, 0), rect.width)
            guard let km: Double = proxy.value(atX: xIn, as: Double.self) else { return nil }
            return km * 1000
        }
        if grabbed == nil {
            guard let startM = meters(atX: start.x) else { return }
            var best = 0; var bestDiff = Double.greatestFiniteMagnitude
            for (k, j) in junctions.enumerated() {
                let diff = abs(dists[j] - startM)
                if diff < bestDiff { bestDiff = diff; best = k }
            }
            guard bestDiff < totalDistance * 0.06 else { return }   // ne saisit que si proche d'une jonction
            grabbed = best
        }
        guard let k = grabbed, let targetM = meters(atX: current.x) else { return }
        var idx = nearestPointIndex(toMeters: targetM)
        let lower = (k == 0 ? 0 : junctions[k - 1]) + 1
        let upper = (k == junctions.count - 1 ? points.count - 1 : junctions[k + 1]) - 1
        guard lower <= upper else { return }
        idx = min(max(idx, lower), upper)
        junctions[k] = idx
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(0..<stageCount, id: \.self) { k in
                        let a = boundaries[k], b = boundaries[k + 1]
                        HStack(spacing: 10) {
                            Text("Étape \(k + 1)").frame(width: 70, alignment: .leading)
                            Text(String(format: "%.1f km", (dists[b] - dists[a]) / 1000)).foregroundStyle(.secondary)
                            Text(String(format: "+%d m", Int((cumGain[b] - cumGain[a]).rounded()))).foregroundStyle(.secondary)
                            Spacer()
                            if k > 0 {
                                Button { junctions.remove(at: k - 1) } label: { Image(systemName: "arrow.triangle.merge") }
                                    .buttonStyle(.borderless).help("Fusionner avec l'étape précédente")
                            }
                        }
                        .font(.callout)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 150)
            HStack {
                Button { addStage() } label: { Label("Ajouter une étape", systemImage: "plus") }
                Button("Réinitialiser") { junctions = [] }
                Spacer()
                Button("Annuler") { dismiss() }
                Button {
                    Task {
                        isWorking = true
                        await save()
                        isWorking = false
                        onSaved()
                        dismiss()
                    }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Label("Enregistrer", systemImage: "checkmark") }
                }
                .buttonStyle(.borderedProminent).disabled(isWorking)
            }
        }
        .padding()
    }

    private func addStage() {
        guard stageCount >= 1 else { return }
        var bestLen = -1.0
        var bestMid: Int?
        for k in 0..<stageCount {
            let a = boundaries[k], b = boundaries[k + 1]
            let len = dists[b] - dists[a]
            if len > bestLen {
                bestLen = len
                bestMid = nearestPointIndex(toMeters: (dists[a] + dists[b]) / 2)
            }
        }
        if let m = bestMid, m > 0, m < points.count - 1, !junctions.contains(m) {
            junctions.append(m); junctions.sort()
        }
    }

    private func nearestPointIndex(toMeters meters: Double) -> Int {
        guard !dists.isEmpty else { return 0 }
        var lo = 0, hi = dists.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if dists[mid] < meters { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(dists[lo - 1] - meters) < abs(dists[lo] - meters) { return lo - 1 }
        return lo
    }

    private func save() async {
        let segments = (0..<stageCount).map { k in
            TrackSegment(name: "Étape \(k + 1)", startIndex: boundaries[k], endIndex: boundaries[k + 1])
        }
        try? await repository.updateSegmentsData(id: activity.id, data: TrackSegment.encode(segments))
    }

    private func load() async {
        defer { isLoading = false }
        guard let data = try? await repository.fetchTrackData(id: activity.id),
              let pts = try? TrackPointCodec.decode(data), pts.count > 1 else { return }
        // Distances cumulées.
        var d = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count { d[i] = d[i - 1] + Self.haversine(pts[i - 1], pts[i]) }
        // Altitudes alignées (report de la dernière connue).
        var a = [Double](repeating: 0, count: pts.count)
        var last = pts.first(where: { $0.altitude != nil })?.altitude ?? 0
        for i in pts.indices { last = pts[i].altitude ?? last; a[i] = last }
        // D+ cumulé (EMA α=0,2 + hystérésis 3 m, comme les statistiques).
        var sm = a
        let alpha = 0.2
        for i in 1..<sm.count { sm[i] = alpha * a[i] + (1 - alpha) * sm[i - 1] }
        var g = [Double](repeating: 0, count: pts.count)
        var anchor = sm[0]
        for i in 1..<pts.count {
            let delta = sm[i] - anchor
            g[i] = g[i - 1]
            if delta >= 3 { g[i] += delta; anchor = sm[i] } else if delta <= -3 { anchor = sm[i] }
        }
        // Étapes existantes (segments contigus) → jonctions de départ.
        var seeded: [Int] = []
        let existing = TrackSegment.decode((try? await repository.fetchSegmentsData(id: activity.id)) ?? nil)
        let sorted = existing.sorted { $0.startIndex < $1.startIndex }
        if sorted.count >= 2, zip(sorted, sorted.dropFirst()).allSatisfy({ $0.endIndex == $1.startIndex }) {
            seeded = sorted.dropLast().map { $0.endIndex }.filter { $0 > 0 && $0 < pts.count - 1 }
        }
        points = pts; dists = d; alts = a; cumGain = g; junctions = seeded
    }

    static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

// MARK: - Parcours en étapes

/// Aperçu d'un parcours en étapes (volet central, façon Raid) : carte, profil avec jonctions déplaçables,
/// liste des étapes. Sélectionner une étape ouvre sa fiche dans le volet de droite.
struct ParcoursDetailView: View {
    let activity: ActivitySummary
    let listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    @Bindable var navigation: AppNavigationModel

    @State private var points: [TrackPoint] = []
    @State private var dists: [Double] = []
    @State private var alts: [Double] = []
    @State private var cumGain: [Double] = []
    @State private var stages: [Stage] = []
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
                        dateBar
                        overviewMap.frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                        resizeHandle($mapHeight, min: 140, max: 700)
                        zoomBar
                        profileChart.frame(height: profileHeight)
                        resizeHandle($profileHeight, min: 90, max: 500)
                        stagesList
                        actions
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(activity.title)
        .task(id: activity.id) { await load() }
        .task(id: AppServices.shared.libraryRevision) {
            guard !points.isEmpty, grabbed == nil else { return }
            let loaded = ((try? await repository.fetchStages(activityId: activity.id)) ?? []).sorted { $0.order < $1.order }
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

    private var overviewMap: some View {
        StageColoredMap(activityId: activity.id, activityType: activity.activityType, coords: coords, stages: stages, highlight: dragCoord, layer: layerBinding)
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

    private var stagesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { k, stage in
                HStack(spacing: 10) {
                    Text("\(k + 1)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stage.name.isEmpty ? "Étape \(k + 1)" : stage.name).fontWeight(.medium)
                        HStack(spacing: 6) {
                            if let pd = stage.plannedDate {
                                Text(Self.stageDateFormatter.string(from: pd)).foregroundStyle(.blue)
                                Text("·")
                            }
                            Text(String(format: "%.1f km · +%d m", stageKm(stage), stageGain(stage)))
                            if let extra = offTrackExtra(stage) {
                                Text(extra).foregroundStyle(.orange)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if k > 0 {
                        Button { merge(at: k) } label: { Image(systemName: "arrow.triangle.merge") }
                            .buttonStyle(.borderless).help("Fusionner avec l'étape précédente")
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture { navigation.selectedStageId = stage.id }
                .background(navigation.selectedStageId == stage.id ? Color.accentColor.opacity(0.12) : .clear)
                .contextMenu {
                    Button("Renommer l'étape…") {
                        renameText = stage.name
                        renamingStageId = stage.id
                    }
                    Button("Supprimer l'étape", role: .destructive) { deleteStage(at: k) }
                        .disabled(stages.count <= 1)
                }
                Divider()
            }
        }
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
        Task { try? await repository.replaceStages(activityId: activity.id, with: snapshot) }
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
        guard let data = try? await repository.fetchTrackData(id: activity.id),
              let pts = try? TrackPointCodec.decode(data), pts.count > 1 else { return }
        var d = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count { d[i] = d[i - 1] + StagePlannerSheet.haversine(pts[i - 1], pts[i]) }
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
        var loaded = (try? await repository.fetchStages(activityId: activity.id)) ?? []
        loaded.sort { $0.order < $1.order }
        // Purge : doublons d'id + étapes « fantômes » (indices hors trace ou dégénérés).
        var seen = Set<UUID>()
        let cleaned = loaded.filter { seen.insert($0.id).inserted }
            .filter { $0.startIndex >= 0 && $0.endIndex < pts.count && $0.endIndex > $0.startIndex }
        if cleaned.count != loaded.count {
            let renumbered = cleaned.enumerated().map { i, s -> Stage in var v = s; v.order = i; return v }
            try? await repository.replaceStages(activityId: activity.id, with: renumbered)
            loaded = renumbered
        } else {
            loaded = cleaned
        }
        if loaded.isEmpty { loaded = [Stage(activityId: activity.id, order: 0, name: "Étape 1", startIndex: 0, endIndex: pts.count - 1)] }
        points = pts; dists = d; alts = a; cumGain = g; stages = loaded
    }
}

/// Fiche d'une étape (volet de droite) : carte zoomée, profil, stats, nom et notes éditables.
struct StageDetailView: View {
    let activity: ActivitySummary
    let stageId: UUID
    let repository: CoreDataActivityRepository

    private enum Handle { case start, end }

    @State private var fullPoints: [TrackPoint] = []
    @State private var dists: [Double] = []
    @State private var allStages: [Stage] = []
    @State private var stageIndex: Int = -1
    @State private var w0 = 0
    @State private var w1 = 0
    @State private var grabbed: Handle?
    @State private var dragCoord: CLLocationCoordinate2D?
    @State private var nameDraft = ""
    @State private var notesDraft = ""
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isRouting = false
    @State private var placingOnMap = false
    @AppStorage("mapLayerStage") private var layerRaw = MapLayer.ignScan25.rawValue
    @AppStorage("stageMapHeight") private var mapHeight: Double = 300
    @AppStorage("connectorEngine") private var engineRaw = "mapkit"

    private var layerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer.base(fromRawValue: layerRaw) }, set: { layerRaw = $0.rawValue })
    }

    private var stage: Stage? { allStages.indices.contains(stageIndex) ? allStages[stageIndex] : nil }
    private var slicePoints: [TrackPoint] { stage?.slice(of: fullPoints) ?? [] }
    private var isFirst: Bool { stageIndex == 0 }
    private var isLast: Bool { stageIndex == allStages.count - 1 }

    // Raccords hors-trace : arrivée (cette étape) et départ (= arrivée de l'étape précédente, inversée).
    private var arrivalConnector: [TrackPoint] { stage?.endConnectorPoints ?? [] }
    private var departureConnector: [TrackPoint] {
        if let pts = stage?.startConnectorPoints, !pts.isEmpty { return pts }
        // Repli (anciennes données sans raccord de départ dédié) : ligne directe du point hors-trace précédent
        // vers le point de tracé de cette étape (le plus court). « Recalculer » produit le vrai raccord routé.
        guard stageIndex > 0, let s = stage,
              let lat = allStages[stageIndex - 1].endOffTrackLatitude,
              let lon = allStages[stageIndex - 1].endOffTrackLongitude,
              fullPoints.indices.contains(s.startIndex) else { return [] }
        return [TrackPoint(latitude: lat, longitude: lon), fullPoints[s.startIndex]]
    }
    private var combinedStagePoints: [TrackPoint] { departureConnector + slicePoints + arrivalConnector }
    private var stats: ActivityStats { ActivityStatsCalculator.compute(points: combinedStagePoints) }

    private func coords(_ pts: [TrackPoint]) -> [CLLocationCoordinate2D] {
        pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
    private var offTrackMarker: CLLocationCoordinate2D? {
        guard let s = stage, let lat = s.endOffTrackLatitude, let lon = s.endOffTrackLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    private var arrivalKm: Double { ActivityStatsCalculator.compute(points: arrivalConnector).distance / 1000 }
    private var arrivalGain: Int { Int(ActivityStatsCalculator.compute(points: arrivalConnector).elevationGain.rounded()) }
    private var departureKm: Double { ActivityStatsCalculator.compute(points: departureConnector).distance / 1000 }
    private var departureGain: Int { Int(ActivityStatsCalculator.compute(points: departureConnector).elevationGain.rounded()) }

    /// Raccord de départ du **lendemain** (étape suivante) depuis le point hors-trace de cette étape — pour décider.
    private var nextDepartureConnector: [TrackPoint] {
        guard offTrackMarker != nil, stageIndex + 1 < allStages.count else { return [] }
        let pts = allStages[stageIndex + 1].startConnectorPoints
        return pts.isEmpty ? arrivalConnector.reversed() : pts
    }
    private var nextDepartureKm: Double { ActivityStatsCalculator.compute(points: nextDepartureConnector).distance / 1000 }
    private var nextDepartureGain: Int { Int(ActivityStatsCalculator.compute(points: nextDepartureConnector).elevationGain.rounded()) }

    /// Fenêtre « loupe » : étape + quelques km de contexte avant/après (borné aux étapes voisines).
    private var windowCoords: [CLLocationCoordinate2D] {
        guard w1 > w0, fullPoints.indices.contains(w0), fullPoints.indices.contains(w1) else { return [] }
        return fullPoints[w0...w1].map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
    /// Étape ramenée aux indices locaux de la fenêtre, pour colorer la portion « étape » sur la carte.
    private var windowStages: [Stage] {
        guard let s = stage, w1 > w0 else { return [] }
        return [Stage(activityId: activity.id, order: 0, name: "", startIndex: s.startIndex - w0, endIndex: s.endIndex - w0)]
    }
    private var windowDomain: ClosedRange<Double> {
        guard w1 > w0 else { return 0...1 }
        var lo = dists[w0] / 1000, hi = dists[w1] / 1000
        for p in connectorPlot { lo = Swift.min(lo, p.km); hi = Swift.max(hi, p.km) }
        return lo...max(lo + 0.01, hi)
    }

    /// Profils des raccords hors-trace, placés sur l'axe km du tracé : le départ se termine au point de
    /// rejointe (startIndex) et déborde à gauche ; l'arrivée part de endIndex et déborde à droite.
    private func cumulativeDistances(_ pts: [TrackPoint]) -> [Double] {
        var c = [Double](repeating: 0, count: pts.count)
        for i in 1..<Swift.max(pts.count, 1) { c[i] = c[i - 1] + StagePlannerSheet.haversine(pts[i - 1], pts[i]) }
        return c
    }
    private var connectorPlot: [PlotPoint] {
        guard let s = stage, !dists.isEmpty else { return [] }
        var r: [PlotPoint] = []
        var uid = 1_000_000
        let dep = departureConnector
        if dep.count >= 2 {
            let cum = cumulativeDistances(dep); let total = cum.last ?? 0
            let baseKm = dists[s.startIndex] / 1000
            for (i, p) in dep.enumerated() {
                r.append(PlotPoint(id: uid, km: baseKm - (total - cum[i]) / 1000, alt: p.altitude ?? 0, region: "depart")); uid += 1
            }
        }
        let arr = arrivalConnector
        if arr.count >= 2 {
            let cum = cumulativeDistances(arr)
            let baseKm = dists[s.endIndex] / 1000
            for (i, p) in arr.enumerated() {
                r.append(PlotPoint(id: uid, km: baseKm + cum[i] / 1000, alt: p.altitude ?? 0, region: "arrivee")); uid += 1
            }
        }
        return r
    }

    private struct PlotPoint: Identifiable { let id: Int; let km: Double; let alt: Double; let region: String }
    /// Points du profil loupe, en 3 séries contiguës (avant / étape / après) partageant leurs points frontières
    /// → aires et lignes bien séparées (gris pour le contexte, bleu pour l'étape).
    private var windowPlot: [PlotPoint] {
        guard w1 > w0, let s = stage else { return [] }
        let a = max(w0, min(s.startIndex, w1)), b = max(a, min(s.endIndex, w1))
        let step = max(1, (w1 - w0) / 600)
        var r: [PlotPoint] = []
        var uid = 0
        func emit(_ lo: Int, _ hi: Int, _ region: String) {
            guard hi >= lo else { return }
            var lastAlt = fullPoints[lo].altitude ?? 0
            var i = lo
            while true {
                lastAlt = fullPoints[i].altitude ?? lastAlt
                r.append(PlotPoint(id: uid, km: dists[i] / 1000, alt: lastAlt, region: region)); uid += 1
                if i == hi { break }
                i = min(i + step, hi)
            }
        }
        if a > w0 { emit(w0, a, "avant") }   // inclut le point a (frontière commune avec l'étape)
        emit(a, b, "etape")
        if b < w1 { emit(b, w1, "apres") }   // inclut le point b
        return r
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stage == nil {
                ContentUnavailableView("Étape introuvable", systemImage: "flag.slash")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Text("Étape \(stageIndex + 1)").font(.title2.bold()).foregroundStyle(.secondary)
                            TextField("Nom de l'étape", text: $nameDraft)
                                .font(.title2.bold()).textFieldStyle(.plain)
                                .onSubmit { persist() }
                        }
                        if let pd = stage?.plannedDate {
                            Text(Self.ficheDateFormatter.string(from: pd)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        StageColoredMap(activityId: activity.id, activityType: activity.activityType,
                                        coords: windowCoords, stages: windowStages,
                                        connectors: [coords(departureConnector), coords(arrivalConnector), coords(nextDepartureConnector)].filter { $0.count >= 2 },
                                        highlight: dragCoord ?? offTrackMarker,
                                        onMapClick: placingOnMap ? { setArrival(to: $0); placingOnMap = false } : nil,
                                        layer: layerBinding)
                            .frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .top) {
                                if placingOnMap {
                                    Text("Cliquez sur la carte pour poser l'arrivée hors-trace")
                                        .font(.caption).padding(6)
                                        .background(.orange, in: Capsule()).foregroundStyle(.white)
                                        .padding(8)
                                }
                            }
                        DragResizeHandle { d in mapHeight = min(700, max(160, mapHeight + Double(d))) }
                        statsRow
                        departureBanner
                        loupeProfile.frame(height: 170)
                        Text("Glissez les poignées orange (début / fin) pour ajuster l'étape. La portion grise = avant/après.")
                            .font(.caption).foregroundStyle(.secondary)
                        arrivalSection
                        Text("Notes").font(.headline)
                        TextEditor(text: $notesDraft)
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    }
                    .padding()
                }
                .onDisappear { persist() }
            }
        }
        .task(id: stageId) { await load() }
    }

    private var loupeProfile: some View {
        Chart {
            ForEach(windowPlot) { p in
                AreaMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(p.region == "etape" ? Color.blue.opacity(0.22) : Color.gray.opacity(0.18))
            }
            ForEach(windowPlot) { p in
                LineMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(p.region == "etape" ? Color.blue : Color.gray)
            }
            ForEach(connectorPlot) { p in
                AreaMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(.orange.opacity(0.22))
            }
            ForEach(connectorPlot) { p in
                LineMark(x: .value("km", p.km), y: .value("alt", p.alt), series: .value("r", p.region))
                    .foregroundStyle(.orange)
            }
            if let s = stage {
                if !isFirst { RuleMark(x: .value("km", dists[s.startIndex] / 1000)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 3)) }
                if !isLast { RuleMark(x: .value("km", dists[s.endIndex] / 1000)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 3)) }
            }
        }
        .chartXScale(domain: windowDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in onDrag(start: v.startLocation, current: v.location, proxy: proxy, geo: geo) }
                        .onEnded { _ in if grabbed != nil { grabbed = nil; dragCoord = nil; persist() } })
            }
        }
    }

    private func onDrag(start: CGPoint, current: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let s = stage, let plotFrame = proxy.plotFrame else { return }
        let rect = geo[plotFrame]
        func meters(atX x: CGFloat) -> Double? {
            let xIn = min(max(x - rect.origin.x, 0), rect.width)
            guard let km: Double = proxy.value(atX: xIn, as: Double.self) else { return nil }
            return km * 1000
        }
        if grabbed == nil {
            guard let startM = meters(atX: start.x), w1 > w0 else { return }
            let span = max(1, dists[w1] - dists[w0])
            let dStart = isFirst ? Double.greatestFiniteMagnitude : abs(dists[s.startIndex] - startM)
            let dEnd = isLast ? Double.greatestFiniteMagnitude : abs(dists[s.endIndex] - startM)
            guard min(dStart, dEnd) < span * 0.12 else { return }
            grabbed = dStart <= dEnd ? .start : .end
        }
        guard let targetM = meters(atX: current.x) else { return }
        let idx = nearestIndex(toMeters: targetM)
        switch grabbed {
        case .start where !isFirst:
            let clamped = min(max(idx, allStages[stageIndex - 1].startIndex + 1), allStages[stageIndex].endIndex - 1)
            allStages[stageIndex].startIndex = clamped
            allStages[stageIndex - 1].endIndex = clamped
            if fullPoints.indices.contains(clamped) { dragCoord = CLLocationCoordinate2D(latitude: fullPoints[clamped].latitude, longitude: fullPoints[clamped].longitude) }
        case .end where !isLast:
            let clamped = min(max(idx, allStages[stageIndex].startIndex + 1), allStages[stageIndex + 1].endIndex - 1)
            allStages[stageIndex].endIndex = clamped
            allStages[stageIndex + 1].startIndex = clamped
            if fullPoints.indices.contains(clamped) { dragCoord = CLLocationCoordinate2D(latitude: fullPoints[clamped].latitude, longitude: fullPoints[clamped].longitude) }
        default:
            break
        }
    }

    private func nearestIndex(toMeters meters: Double) -> Int {
        guard !dists.isEmpty else { return 0 }
        var lo = 0, hi = dists.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if dists[mid] < meters { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(dists[lo - 1] - meters) < abs(dists[lo] - meters) { return lo - 1 }
        return lo
    }

    private var statsRow: some View {
        HStack(spacing: 22) {
            stat("Distance", String(format: "%.1f km", stats.distance / 1000))
            stat("D+", String(format: "+%d m", Int(stats.elevationGain.rounded())))
            stat("D−", String(format: "−%d m", Int(stats.elevationLoss.rounded())))
            if stats.movingDuration > 0 { stat("Durée", Self.clock(stats.movingDuration)) }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded()); return String(format: "%dh%02d", m / 60, m % 60)
    }

    private static let ficheDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .full; return f
    }()

    @ViewBuilder private var departureBanner: some View {
        if !departureConnector.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Départ hors-trace", systemImage: "arrow.up.forward").font(.headline)
                    Spacer()
                    if isRouting { ProgressView().controlSize(.small) }
                    Button("Recalculer") { recomputeDeparture() }.controlSize(.small)
                }
                Text(String(format: "Raccord de départ : +%.1f km · +%d m D+ — plus court chemin pour rejoindre la trace depuis l'arrivée de l'étape précédente.", departureKm, departureGain))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.10)))
        }
    }

    private func recomputeDeparture() {
        guard stageIndex > 0,
              let lat = allStages[stageIndex - 1].endOffTrackLatitude,
              let lon = allStages[stageIndex - 1].endOffTrackLongitude else { return }
        let p = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let leave = allStages[stageIndex - 1].endIndex
        isRouting = true
        Task {
            let rejoin = nearestTrackIndex(to: p, in: leave...max(leave, allStages[stageIndex].endIndex - 1))
            let rejoinCoord = CLLocationCoordinate2D(latitude: fullPoints[rejoin].latitude, longitude: fullPoints[rejoin].longitude)
            let departure = await AppServices.shared.buildConnector(from: p, to: rejoinCoord)
            allStages[stageIndex].startIndex = rejoin
            allStages[stageIndex].startConnectorData = try? TrackPointCodec.encode(departure)
            isRouting = false
            persist()
        }
    }

    private var arrivalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Arrivée hors-trace").font(.headline)
                Spacer()
                if isRouting { ProgressView().controlSize(.small) }
                if offTrackMarker != nil {
                    Button("Retirer", role: .destructive) { clearArrival() }.controlSize(.small)
                }
            }
            if offTrackMarker == nil {
                Text("Placez l'arrivée hors du tracé (ex. refuge) : le raccord est calculé et compté dans l'étape.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Arrivée du jour : +%.1f km · +%d m D+", arrivalKm, arrivalGain))
                    if stageIndex + 1 < allStages.count {
                        Text(String(format: "Départ du lendemain : +%.1f km · +%d m D+", nextDepartureKm, nextDepartureGain))
                        Text(String(format: "Coût total du détour : +%.1f km · +%d m D+", arrivalKm + nextDepartureKm, arrivalGain + nextDepartureGain))
                            .fontWeight(.semibold)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Rechercher un lieu (refuge, village…)", text: $searchText)
                    .textFieldStyle(.roundedBorder).onSubmit { runSearch() }
                Button("Rechercher") { runSearch() }
                Button(placingOnMap ? "Annuler" : "Choisir sur la carte") { placingOnMap.toggle() }
            }
            HStack(spacing: 8) {
                Text("Itinéraire").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $engineRaw) {
                    Text("À pied (MapKit)").tag("mapkit")
                    Text("Sentiers (BRouter)").tag("trail")
                    Text("Route (auto/moto)").tag("car")
                    Text("Ligne directe").tag("line")
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            }
            ForEach(searchResults, id: \.self) { item in
                Button { setArrival(to: item.placemark.coordinate) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle").foregroundStyle(.orange)
                        Text(item.name ?? "Lieu").lineLimit(1)
                        Spacer()
                        if let t = item.placemark.title { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let s = stage, fullPoints.indices.contains(s.endIndex) {
            let c = CLLocationCoordinate2D(latitude: fullPoints[s.endIndex].latitude, longitude: fullPoints[s.endIndex].longitude)
            request.region = MKCoordinateRegion(center: c, latitudinalMeters: 40000, longitudinalMeters: 40000)
        }
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            searchResults = response?.mapItems ?? []
        }
    }

    private func setArrival(to point: CLLocationCoordinate2D) {
        guard let s = stage, !fullPoints.isEmpty else { return }
        searchResults = []
        searchText = ""
        placingOnMap = false
        isRouting = true
        let boundary = s.endIndex // jonction d'origine entre cette étape et la suivante
        let hasNext = stageIndex + 1 < allStages.count
        let nextEnd = hasNext ? allStages[stageIndex + 1].endIndex : 0
        Task {
            // Arrivée : on quitte la trace au point le plus proche de P **dans cette étape** (le plus court).
            let leave = nearestTrackIndex(to: point, in: (s.startIndex + 1)...boundary)
            let leaveCoord = CLLocationCoordinate2D(latitude: fullPoints[leave].latitude, longitude: fullPoints[leave].longitude)
            let arrival = await AppServices.shared.buildConnector(from: leaveCoord, to: point)
            allStages[stageIndex].endIndex = leave
            allStages[stageIndex].endOffTrackLatitude = point.latitude
            allStages[stageIndex].endOffTrackLongitude = point.longitude
            allStages[stageIndex].endConnectorData = try? TrackPointCodec.encode(arrival)
            // Départ du lendemain : on rejoint la trace au point le plus proche de P **dans l'étape suivante** (le plus court).
            if hasNext, boundary <= nextEnd - 1 {
                let rejoin = nearestTrackIndex(to: point, in: boundary...(nextEnd - 1))
                let rejoinCoord = CLLocationCoordinate2D(latitude: fullPoints[rejoin].latitude, longitude: fullPoints[rejoin].longitude)
                let departure = await AppServices.shared.buildConnector(from: point, to: rejoinCoord)
                allStages[stageIndex + 1].startIndex = rejoin
                allStages[stageIndex + 1].startConnectorData = try? TrackPointCodec.encode(departure)
            }
            isRouting = false
            persist()
        }
    }

    private func clearArrival() {
        guard stageIndex >= 0, let s = stage else { return }
        allStages[stageIndex].endOffTrackLatitude = nil
        allStages[stageIndex].endOffTrackLongitude = nil
        allStages[stageIndex].endConnectorData = nil
        if stageIndex + 1 < allStages.count {
            allStages[stageIndex + 1].startConnectorData = nil
            allStages[stageIndex + 1].startIndex = s.endIndex // re-contigu avec la fin de cette étape
        }
        persist()
    }

    private func nearestTrackIndex(to p: CLLocationCoordinate2D, in range: ClosedRange<Int>) -> Int {
        var best = range.lowerBound
        var bestDist = Double.greatestFiniteMagnitude
        for i in range where fullPoints.indices.contains(i) {
            let dLat = fullPoints[i].latitude - p.latitude
            let dLon = fullPoints[i].longitude - p.longitude
            let d = dLat * dLat + dLon * dLon
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Sauvegarde ciblée : la fiche ne met à jour QUE ses propres étapes (courante + voisines modifiées),
    /// sans réécrire toute la liste — évite d'écraser les changements de structure faits dans l'aperçu (suppression…).
    private func persist() {
        guard stageIndex >= 0 else { return }
        let trimmed = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        allStages[stageIndex].name = nameDraft
        allStages[stageIndex].notes = trimmed.isEmpty ? nil : trimmed
        let indices = [stageIndex - 1, stageIndex, stageIndex + 1].filter { allStages.indices.contains($0) }
        let toSave = indices.map { allStages[$0] }
        Task {
            for s in toSave { try? await repository.updateStage(s) }
            AppServices.shared.libraryRevision += 1
        }
    }

    private func load() async {
        defer { isLoading = false }
        let stages = ((try? await repository.fetchStages(activityId: activity.id)) ?? []).sorted { $0.order < $1.order }
        guard let idx = stages.firstIndex(where: { $0.id == stageId }) else { allStages = []; stageIndex = -1; return }
        var d: [Double] = []
        if let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) {
            fullPoints = pts
            d = [Double](repeating: 0, count: pts.count)
            for i in 1..<max(pts.count, 1) { d[i] = d[i - 1] + StagePlannerSheet.haversine(pts[i - 1], pts[i]) }
        }
        dists = d
        allStages = stages
        stageIndex = idx
        nameDraft = stages[idx].name
        notesDraft = stages[idx].notes ?? ""
        // Fenêtre loupe : ~3 km de contexte de part et d'autre, borné aux étapes voisines.
        if !d.isEmpty {
            let s = stages[idx]
            let contextM = 3000.0
            let prevStart = idx > 0 ? stages[idx - 1].startIndex : 0
            let nextEnd = idx < stages.count - 1 ? stages[idx + 1].endIndex : d.count - 1
            w0 = max(prevStart, indexAtMeters(d[s.startIndex] - contextM, in: d))
            w1 = min(nextEnd, indexAtMeters(d[s.endIndex] + contextM, in: d))
        }
    }

    private func indexAtMeters(_ meters: Double, in d: [Double]) -> Int {
        guard !d.isEmpty else { return 0 }
        var lo = 0, hi = d.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if d[mid] < meters { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

/// Poignée de redimensionnement vertical, centrée et continue (positif = agrandir l'élément du dessus).
struct DragResizeHandle: View {
    let onDelta: (CGFloat) -> Void
    @State private var accum: CGFloat = 0
    var body: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in onDelta(v.translation.height - accum); accum = v.translation.height }
                    .onEnded { _ in accum = 0 }
            )
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Glisser pour ajuster la hauteur de la carte")
    }
}

/// Carte IGN réelle (même outillage que le détail : sélecteur de fonds) montrant une trace, avec coloration
/// par étape si `stages` est fourni (sinon tracé uniforme). Réutilisée par la fiche d'étape et l'aperçu.
struct StageColoredMap: View {
    let activityId: UUID
    let activityType: ActivityType
    let coords: [CLLocationCoordinate2D]
    var stages: [Stage] = []
    var connectors: [[CLLocationCoordinate2D]] = []
    var highlight: CLLocationCoordinate2D? = nil
    var onMapClick: ((CLLocationCoordinate2D) -> Void)? = nil
    @Binding var layer: MapLayer

    private static let connectorIds = [
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    ]
    private var connectorOverlays: [TrackOverlayInput] {
        connectors.enumerated().compactMap { i, c in
            guard c.count >= 2 else { return nil }
            return TrackOverlayInput(activityId: Self.connectorIds[i % Self.connectorIds.count],
                                     activityType: activityType, coordinates: c,
                                     segmentColors: [NSColor](repeating: .systemOrange, count: c.count))
        }
    }

    private var overlay: TrackOverlayInput {
        guard !stages.isEmpty, !coords.isEmpty else {
            return TrackOverlayInput(activityId: activityId, activityType: activityType, coordinates: coords)
        }
        var colors = [NSColor](repeating: .systemGray, count: coords.count)
        for (k, s) in stages.enumerated() {
            let c = MapTrackPalette.colors[k % MapTrackPalette.colors.count]
            let lo = max(0, min(s.startIndex, coords.count - 1))
            let hi = max(lo, min(s.endIndex, coords.count - 1))
            if lo <= hi { for i in lo...hi { colors[i] = c } }
        }
        return TrackOverlayInput(activityId: activityId, activityType: activityType, coordinates: coords, segmentColors: colors)
    }

    var body: some View {
        TrackMapView(tracks: (coords.isEmpty ? [] : [overlay]) + connectorOverlays, layer: $layer, highlight: highlight, fitsOnce: true, onMapClick: onMapClick)
            .overlay(alignment: .topTrailing) {
                LayerPicker(layer: $layer).padding(8)
            }
    }
}

/// Carte plein cadre d'un parcours (mode Vue d'ensemble) : tracé du parcours avec ses étapes colorées.
struct StagedRouteOverviewMap: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @State private var coords: [CLLocationCoordinate2D] = []
    @State private var stages: [Stage] = []
    @State private var isLoading = true
    @AppStorage("mapLayerParcoursMap") private var layerRaw = MapLayer.ignScan25.rawValue

    private var layerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer.base(fromRawValue: layerRaw) }, set: { layerRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StageColoredMap(activityId: activity.id, activityType: activity.activityType, coords: coords, stages: stages, layer: layerBinding)
            }
        }
        .task(id: activity.id) { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        if let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) {
            coords = pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        stages = ((try? await repository.fetchStages(activityId: activity.id)) ?? []).sorted { $0.order < $1.order }
    }
}

/// Éditeur d'itinéraire d'un parcours, **inline** dans la section Carte (activé par un toggle) : points de
/// passage déplaçables sur la carte IGN, ajout au clic (insertion ou extension), suppression, routage live.
/// Enregistre en sortant (toggle off / changement d'activité) ou via le bouton.
struct RouteEditorView: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @Binding var layer: MapLayer
    let mapHeight: Double
    var onSaved: () -> Void

    @State private var waypoints: [RouteWaypoint] = []
    @State private var routedCoords: [CLLocationCoordinate2D] = []
    @State private var selectedWaypointId: UUID?
    @State private var isLoading = true
    @State private var isRouting = false
    @State private var isSaving = false
    @State private var dirty = false
    @State private var routeDone = 0
    @State private var routeTotal = 0
    @AppStorage("connectorEngine") private var engineRaw = "mapkit"

    private func coord(_ w: RouteWaypoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude) }
    private var markers: [WaypointMarker] { waypoints.enumerated().map { WaypointMarker(id: $1.id, coordinate: coord($1), index: $0) } }
    private var displayCoords: [CLLocationCoordinate2D] { routedCoords.count >= 2 ? routedCoords : waypoints.map(coord) }

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView("Chargement…").frame(maxWidth: .infinity, minHeight: mapHeight)
            } else {
                TrackMapView(
                    tracks: displayCoords.count >= 2
                        ? [TrackOverlayInput(activityId: activity.id, activityType: activity.activityType, coordinates: displayCoords)]
                        : [],
                    layer: $layer, fitsOnce: true, waypoints: markers,
                    onWaypointMoved: { id, c in moveWaypoint(id: id, to: c) },
                    onWaypointTapped: { selectedWaypointId = ($0 == selectedWaypointId ? nil : $0) },
                    onMapClick: { addWaypoint(at: $0) }
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
                controls
                waypointList
            }
        }
        .task { await load() }
        .onDisappear { saveIfNeeded() }
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
            Button { reroute() } label: { Label("Recalculer l'itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond") }
                .controlSize(.small).disabled(isRouting || isSaving || waypoints.count < 2)
            Spacer()
            Button { saveNow() } label: { Label("Enregistrer", systemImage: "checkmark") }
                .controlSize(.small).disabled(waypoints.count < 2 || isRouting || isSaving)
        }
    }

    private var waypointList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { i, wp in
                    HStack(spacing: 8) {
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

    // Nomme les points sans nom par géocodage inverse (POI/col, quartier, ville…).
    private func nameWaypoints() async {
        let targets = waypoints.filter { ($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !targets.isEmpty else { return }
        let geocoder = CLGeocoder()
        for wp in targets {
            let loc = CLLocation(latitude: wp.latitude, longitude: wp.longitude)
            let label = (try? await geocoder.reverseGeocodeLocation(loc)).flatMap { Self.placeLabel($0.first) }
            if let label, let j = waypoints.firstIndex(where: { $0.id == wp.id }),
               (waypoints[j].name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                waypoints[j].name = label
                dirty = true
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // CLGeocoder est limité en débit.
        }
    }

    private static func placeLabel(_ p: CLPlacemark?) -> String? {
        guard let p else { return nil }
        if let aoi = p.areasOfInterest?.first, !aoi.isEmpty { return aoi }
        if let sub = p.subLocality, !sub.isEmpty { return sub }
        if let loc = p.locality, !loc.isEmpty { return loc }
        if let name = p.name, !name.isEmpty { return name }
        return p.administrativeArea
    }

    // Les éditions montrent un aperçu en lignes droites (instantané) ; le routage est explicite (« Recalculer »).
    private func invalidate() { routedCoords = []; dirty = true }

    private func moveWaypoint(id: UUID, to c: CLLocationCoordinate2D) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[i].latitude = c.latitude
        waypoints[i].longitude = c.longitude
        invalidate()
    }

    private func addWaypoint(at c: CLLocationCoordinate2D) {
        let wp = RouteWaypoint(latitude: c.latitude, longitude: c.longitude)
        if waypoints.count < 2 {
            waypoints.append(wp)
        } else {
            // Meilleure position : extension à une extrémité OU insertion sur le segment au détour minimal.
            var bestPos = waypoints.count
            var bestCost = planar(waypoints[waypoints.count - 1], c)
            let startCost = planar(waypoints[0], c)
            if startCost < bestCost { bestCost = startCost; bestPos = 0 }
            for i in 0..<(waypoints.count - 1) {
                let cost = planar(waypoints[i], c) + planar(waypoints[i + 1], c) - planarWW(waypoints[i], waypoints[i + 1])
                if cost < bestCost { bestCost = cost; bestPos = i + 1 }
            }
            waypoints.insert(wp, at: bestPos)
        }
        selectedWaypointId = wp.id
        invalidate()
    }

    private func delete(_ id: UUID) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }), waypoints.count > 2 else { return }
        waypoints.remove(at: i)
        if selectedWaypointId == id { selectedWaypointId = nil }
        invalidate()
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
        guard waypoints.count >= 2, !isRouting else { return }
        let snapshot = waypoints
        let engine = ConnectorRouter.Engine(rawValue: engineRaw) ?? .mapkit
        routeTotal = snapshot.count - 1
        routeDone = 0
        isRouting = true
        Task {
            var coords: [CLLocationCoordinate2D] = []
            for i in 0..<(snapshot.count - 1) {
                if i > 0, engine == .mapkit || engine == .car { try? await Task.sleep(nanoseconds: 150_000_000) }
                var seg = await ConnectorRouter.route(from: coord(snapshot[i]), to: coord(snapshot[i + 1]), engine: engine)
                if seg.count < 2 { seg = [coord(snapshot[i]), coord(snapshot[i + 1])] }
                if !coords.isEmpty { seg.removeFirst() }
                coords.append(contentsOf: seg)
                routeDone = i + 1
            }
            routedCoords = coords
            dirty = true
            isRouting = false
            await nameWaypoints()
        }
    }

    private func saveNow() {
        guard waypoints.count >= 2, !isRouting, !isSaving else { return }
        dirty = false
        isSaving = true
        Task {
            await nameWaypoints()
            let snapshot = waypoints
            let coords = routedCoords
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
        // Affiche le tracé existant (déjà routé) sans re-router au chargement.
        if let data = try? await repository.fetchTrackData(id: activity.id), let pts = try? TrackPointCodec.decode(data) {
            routedCoords = pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        isLoading = false
    }
}
