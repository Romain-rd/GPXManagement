import SwiftUI
import AppKit
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
    @State private var isExportingVideo = false
    @State private var videoProgress: Double = 0
    @State private var showVideoOptions = false
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

    var body: some View {
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
        .onChange(of: windowModel.webExportToken) { _, _ in
            if model.hasTrack { showWebExportOptions = true }
        }
        .onChange(of: windowModel.videoToken) { _, _ in
            if model.hasTrack { showVideoOptions = true }
        }
        .onChange(of: windowModel.shareToken) { _, _ in
            if model.hasTrack { Task { await prepareShare() } }
        }
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

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionChevron($secMapExpanded)
                Label("Carte", systemImage: "map")
                    .font(.headline)
                Spacer()
                if secMapExpanded {
                    TrackColorControl(mode: Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue }))
                        .controlSize(.small)
                    if mapLayerBinding.wrappedValue.isIGN {
                        SlopeOverlayControl(enabled: $slopeOverlayEnabled, opacity: $slopeOverlayOpacity)
                            .controlSize(.small)
                    }
                    LayerPicker(layer: mapLayerBinding)
                        .controlSize(.small)
                }
            }
            if secMapExpanded {
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
            ElevationProfileTabView(activityId: activity.id, activityType: activity.activityType, repository: repository, mode: $profileMode, metric: $profileMetric, highlightedCoordinate: $highlightedCoordinate, highlightedDistanceRange: selectedSegmentRange)
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
