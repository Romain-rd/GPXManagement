import SwiftUI
import AppKit
import MapKit
import Photos
import QuickLook
import AVFoundation
import UniformTypeIdentifiers
import GPXCore
import GPXMapKit

struct ActivityDetailView: View {
    let activity: ActivitySummary
    @Bindable var listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    /// Vrai dans la fenêtre détail dédiée (double-clic) : autorise les ajustements de barre de titre en plein écran.
    var isStandaloneWindow: Bool = false
    @State private var notesDraft: String = ""
    @State private var shareURL: URL?
    @State private var isShareSheetPresented = false
    @State private var exportError: String?
    @State private var isExportingPDF = false
    @State private var profileMode: ProfileMode = .distance
    @State private var profileMetric: ProfileMetric = .altitude
    @State private var highlightedCoordinate: CLLocationCoordinate2D?
    @State private var photoAssets: [PHAsset] = []
    @State private var photoMapItems: [PhotoMapItem] = []
    @State private var previewURL: URL?
    @State private var hiddenPhotoIDs: Set<String> = []
    @State private var editingMedia: EditingMedia?
    @State private var photosReload = 0
    @AppStorage("appCreatedAssets") private var appCreatedAssetsJSON = ""
    @State private var isExportingVideo = false
    @State private var videoProgress: Double = 0
    @State private var showVideoOptions = false
    @State private var showWebExportOptions = false
    @State private var isExportingWeb = false
    @State private var webOptions = WebExportOptions()
    @State private var publishedURL: String?
    @State private var publishConfigJSON: String?
    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool
    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = "ign_scan25"
    @AppStorage("slopeOverlayEnabled") private var slopeOverlayEnabled: Bool = false
    @AppStorage("slopeOverlayOpacity") private var slopeOverlayOpacity: Double = 0.6
    @AppStorage("trackColorMode") private var trackColorModeRaw: String = TrackColorMode.uniform.rawValue
    @AppStorage("detailMapHeight") private var mapHeight: Double = 340
    @State private var dragAccumulator: Double = 0
    @State private var fullscreenMap = false
    @AppStorage("fullscreenProfileHeight") private var fsProfileHeight: Double = 200
    @State private var fsProfileDrag: Double = 0
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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                metricsGrid
                publishedLinkSection
                mapSection
                profileSection
                photosSection
                notesSection
            }
            .padding(20)
        }
        .overlay {
            if fullscreenMap { fullscreenMapOverlay }
        }
        .toolbar((fullscreenMap && isStandaloneWindow) ? .hidden : .automatic, for: .windowToolbar)
        .background {
            if isStandaloneWindow { FullScreenWindowConfigurator(active: fullscreenMap) }
        }
        .navigationTitle(activity.title)
        .onAppear {
            notesDraft = activity.notes ?? ""
            titleDraft = activity.title
            hiddenPhotoIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenPhotosKey) ?? [])
            Task { await loadPublishState() }
        }
        .onChange(of: activity.id) { _, _ in
            notesDraft = activity.notes ?? ""
            titleDraft = activity.title
            publishedURL = nil
            publishConfigJSON = nil
            Task { await loadPublishState() }
        }
        .onChange(of: activity.title) { _, newTitle in
            if !titleFocused { titleDraft = newTitle }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await listVM.autoRename(id: activity.id) }
                } label: {
                    if listVM.renamingIds.contains(activity.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Nommer d'après le parcours", systemImage: "mappin.and.ellipse")
                    }
                }
                .disabled(listVM.renamingIds.contains(activity.id))
                .help("Renomme l'activité avec lieu de départ → point de passage → arrivée")

                Button {
                    Task { await exportGPX() }
                } label: {
                    Label("Exporter en GPX", systemImage: "arrow.down.doc")
                }
                Button {
                    Task { await exportPDF() }
                } label: {
                    if isExportingPDF {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Exporter en PDF", systemImage: "doc.richtext")
                    }
                }
                .disabled(isExportingPDF)
                Button {
                    showWebExportOptions = true
                } label: {
                    if isExportingWeb {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Exporter en page web", systemImage: "globe")
                    }
                }
                .disabled(isExportingWeb)
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
                .disabled(isExportingVideo)
                .help("Crée un film du parcours (point animé) avec les photos/vidéos sélectionnées")

                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("Partager", systemImage: "square.and.arrow.up")
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
    }

    private var header: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Button {
                        Task { await listVM.updateType(id: activity.id, type: type) }
                    } label: {
                        Label(type.displayName, systemImage: type == activity.activityType ? "checkmark" : type.symbolName)
                    }
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
                Text("\(activity.activityType.displayName) · \(Self.formatDate(activity.startDate))")
                    .foregroundStyle(.secondary)
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
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { titleDraft = activity.title; return }
        guard trimmed != activity.title else { return }
        Task { await listVM.updateTitle(id: activity.id, title: trimmed) }
    }

    @ViewBuilder
    private var publishedLinkSection: some View {
        if let urlString = publishedURL, let url = URL(string: urlString) {
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

    private var metricsGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            MetricCard(icon: "ruler", value: distanceText(activity.distance), label: "Distance", tint: .blue)
            MetricCard(icon: "arrow.up.forward", value: "\(Int(activity.elevationGain.rounded())) m", label: "Dénivelé +", tint: .green)
            MetricCard(icon: "arrow.down.forward", value: "\(Int(activity.elevationLoss.rounded())) m", label: "Dénivelé −", tint: .orange)
            MetricCard(icon: "clock", value: Self.duration(activity.duration), label: "Durée totale", tint: .purple)
            MetricCard(icon: "stopwatch", value: Self.duration(activity.movingDuration), label: "En mouvement", tint: .purple)
            MetricCard(icon: "speedometer", value: speedText(activity.avgSpeed), label: "Vitesse moy.", tint: .teal)
            MetricCard(icon: "gauge.with.dots.needle.67percent", value: speedText(activity.maxSpeed), label: "Vitesse max", tint: .teal)
            if let hr = activity.avgHeartRate {
                MetricCard(icon: "heart", value: "\(Int(hr.rounded())) bpm", label: "FC moyenne", tint: .red)
            }
            if let hr = activity.maxHeartRate {
                MetricCard(icon: "heart.fill", value: "\(Int(hr.rounded())) bpm", label: "FC max", tint: .red)
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(profileMetric == .speed ? "Profil de vitesse" : "Profil altimétrique",
                      systemImage: profileMetric == .speed ? "speedometer" : "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
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
            ElevationProfileTabView(activityId: activity.id, activityType: activity.activityType, repository: repository, mode: $profileMode, metric: $profileMetric, highlightedCoordinate: $highlightedCoordinate)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        }
        .onChange(of: activity.id, initial: true) {
            profileMetric = activity.activityType == .sailing ? .speed : .altitude
        }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Carte", systemImage: "map")
                    .font(.headline)
                Spacer()
                TrackColorControl(mode: Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue }))
                    .controlSize(.small)
                if mapLayerBinding.wrappedValue.isIGN {
                    SlopeOverlayControl(enabled: $slopeOverlayEnabled, opacity: $slopeOverlayOpacity)
                        .controlSize(.small)
                }
                LayerPicker(layer: mapLayerBinding)
                    .controlSize(.small)
            }
            ActivityMapCard(
                activityId: activity.id,
                activityType: activity.activityType,
                repository: repository,
                layer: mapLayerBinding,
                highlight: highlightedCoordinate,
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

    private var fullscreenMapOverlay: some View {
        ActivityMapCard(
            activityId: activity.id,
            activityType: activity.activityType,
            repository: repository,
            layer: mapLayerBinding,
            highlight: highlightedCoordinate,
            photos: mapPhotos,
            slopeOverlayOpacity: slopeOverlayEnabled ? slopeOverlayOpacity : 0,
            trackColorMode: trackColorMode,
            onSelectPhoto: openPhoto
        )
        .overlay(alignment: .topLeading) { fsMapControls.padding(10) }
        .overlay(alignment: .topTrailing) { fsTopRightButtons.padding(10) }
        .overlay(alignment: .bottom) { if showFsProfile { fsProfilePanel } }
        .background(Color.black)
        .ignoresSafeArea()
    }

    /// Contrôles carte en plein écran : fond + couleur de trace + surcouche pentes.
    private var fsMapControls: some View {
        HStack(spacing: 8) {
            LayerPicker(layer: mapLayerBinding)
            TrackColorControl(mode: Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue }))
            if mapLayerBinding.wrappedValue.isIGN {
                SlopeOverlayControl(enabled: $slopeOverlayEnabled, opacity: $slopeOverlayOpacity)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var fsTopRightButtons: some View {
        HStack(spacing: 10) {
            Button { showFsProfile.toggle() } label: {
                Image(systemName: showFsProfile ? "chart.xyaxis.line" : "chart.bar.xaxis")
                    .padding(7).background(.black.opacity(0.5), in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain).help(showFsProfile ? "Masquer le profil" : "Afficher le profil")
            Button { fullscreenMap = false } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Quitter le plein écran (Échap)")
        }
    }

    /// Profil en surimpression discrète, navigable (survol → marqueur sur la carte), à hauteur réglable.
    private var fsProfilePanel: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(.secondary.opacity(0.6)).frame(width: 46, height: 5).padding(.vertical, 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let dy = Double(v.translation.height)
                            fsProfileHeight = min(520, max(120, fsProfileHeight - (dy - fsProfileDrag)))
                            fsProfileDrag = dy
                        }
                        .onEnded { _ in fsProfileDrag = 0 }
                )
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            HStack(spacing: 8) {
                Picker("", selection: $profileMetric) { ForEach(ProfileMetric.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $profileMode) { ForEach(ProfileMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            ElevationProfileTabView(activityId: activity.id, activityType: activity.activityType, repository: repository, mode: $profileMode, metric: $profileMetric, highlightedCoordinate: $highlightedCoordinate)
                .frame(height: fsProfileHeight)
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

    private var mapPhotos: [PhotoMapItem] {
        guard photosOnMapEnabled else { return [] }
        return photoMapItems.filter { !hiddenPhotoIDs.contains($0.id) }
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
            isShownOnMap: { !hiddenPhotoIDs.contains($0) },
            isAppCreated: { appCreatedAssets.contains($0) },
            onToggleMap: togglePhotoOnMap,
            onSelect: previewPhoto,
            onEdit: editMedia,
            onDelete: deleteMedia
        )
        .onChange(of: photoAssets) { _, newAssets in
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
    }

    private func togglePhotoOnMap(_ id: String) {
        if hiddenPhotoIDs.contains(id) { hiddenPhotoIDs.remove(id) } else { hiddenPhotoIDs.insert(id) }
        UserDefaults.standard.set(Array(hiddenPhotoIDs), forKey: Self.hiddenPhotosKey)
    }

    // MARK: - Édition des médias

    private var appCreatedAssets: Set<String> {
        guard let d = appCreatedAssetsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(arr)
    }
    private func setAppCreatedAssets(_ set: Set<String>) {
        if let d = try? JSONEncoder().encode(Array(set)), let s = String(data: d, encoding: .utf8) { appCreatedAssetsJSON = s }
    }
    private func editMedia(_ asset: PHAsset) {
        editingMedia = EditingMedia(id: asset.localIdentifier, asset: asset)
    }
    private func saveCroppedPhoto(from asset: PHAsset, jpeg: Data) {
        editingMedia = nil
        Task {
            if let id = await PhotoLibraryService.createImageAsset(jpeg: jpeg, creationDate: asset.creationDate, location: asset.location) {
                setAppCreatedAssets(appCreatedAssets.union([id]))
            }
            photosReload += 1
        }
    }
    private func saveEditedVideo(from asset: PHAsset, url: URL) {
        editingMedia = nil
        Task {
            if let id = await PhotoLibraryService.createVideoAsset(fileURL: url, creationDate: asset.creationDate, location: asset.location) {
                setAppCreatedAssets(appCreatedAssets.union([id]))
            }
            try? FileManager.default.removeItem(at: url)
            photosReload += 1
        }
    }

    private func deleteMedia(_ asset: PHAsset) {
        let id = asset.localIdentifier
        Task {
            if await PhotoLibraryService.deleteAssets([id]) {
                setAppCreatedAssets(appCreatedAssets.subtracting([id]))
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
            }
            Text("Glissez les zones pour les déplacer, la poignée (coin) pour les redimensionner. Carton titre+date au début, résumé à la fin.")
                .font(.caption).foregroundStyle(.secondary)
            VideoLayoutEditor(aspect: videoFormat.aspect, layout: $currentLayout, tracePoints: tracePreview)
            HStack {
                Button("Réinitialiser") { currentLayout = VideoLayout.defaultLayout(for: videoFormat) }
                Spacer()
                Button("Annuler") { showVideoOptions = false }
                Button("Créer la vidéo") {
                    showVideoOptions = false
                    persistCurrentLayout()
                    exportVideo()
                }
                .keyboardShortcut(.defaultAction)
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
                        Button { applyTemplate(t) } label: { Label(t.name, systemImage: t.id == selectedTemplateID ? "checkmark" : "") }
                    }
                }
                if !userTemplates.isEmpty {
                    Section("Mes modèles") {
                        ForEach(userTemplates) { t in
                            Button { applyTemplate(t) } label: { Label(t.name, systemImage: t.id == selectedTemplateID ? "checkmark" : "") }
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
            ("En mouvement", Self.duration(activity.movingDuration)),
            ("Dénivelé +", "\(Int(activity.elevationGain.rounded())) m"),
            ("Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m"),
            ("Vitesse moy.", speedText(activity.avgSpeed)),
            ("Vitesse max", speedText(activity.maxSpeed))
        ]
        if let hr = activity.avgHeartRate { lines.append(("FC moyenne", "\(Int(hr.rounded())) bpm")) }
        if let hr = activity.maxHeartRate { lines.append(("FC max", "\(Int(hr.rounded())) bpm")) }
        return lines
    }

    private func exportVideo() {
        let quality = VideoQuality(rawValue: videoQualityRaw) ?? .hd720
        let dims = videoFormat.dimensions(base: quality.base)
        let layout = currentLayout

        let panel = NSSavePanel()
        panel.title = "Enregistrer la vidéo du parcours"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = activity.title.replacingOccurrences(of: "/", with: "-") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let config = VideoConfig(
            width: dims.width,
            height: dims.height,
            layout: layout,
            transition: MediaTransition(rawValue: videoTransitionRaw) ?? .fade,
            showHeartRate: videoHeartRateOn && layout.profile != nil,
            showIntro: videoIntroOn,
            showOutro: videoOutroOn,
            mapLayer: MapLayer(rawValue: videoMapLayerRaw) ?? .ignScan25,
            title: activity.title,
            dateText: Self.formatDate(activity.startDate),
            summary: videoSummaryLines()
        )

        Task {
            isExportingVideo = true
            videoProgress = 0
            defer { isExportingVideo = false }

            guard let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
                  let points = try? TrackPointCodec.decode(data) else {
                exportError = "Cette activité n'a pas de tracé exploitable."
                return
            }

            // Médias sélectionnés (épingle active) et géolocalisés.
            var media: [TrackVideoMedia] = []
            for asset in photoAssets where !hiddenPhotoIDs.contains(asset.localIdentifier) {
                guard let location = asset.location else { continue }
                let thumb = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 160, height: 160))
                if asset.mediaType == .video {
                    if let av = await PhotoLibraryService.avAsset(for: asset) {
                        media.append(.video(asset: av, thumbnail: thumb, coordinate: location.coordinate))
                    }
                } else if let image = await PhotoLibraryService.fullImage(for: asset) {
                    media.append(.photo(image: image, thumbnail: thumb, coordinate: location.coordinate))
                }
            }

            do {
                try await TrackVideoExporter.export(points: points, media: media, config: config, to: url) { fraction in
                    Task { @MainActor in videoProgress = fraction }
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// Construit les vignettes à placer sur la carte (coordonnée GPS + miniature) depuis les photos trouvées.
    private func buildPhotoMapItems(_ assets: [PHAsset]) async {
        var items: [PhotoMapItem] = []
        for asset in assets {
            guard let location = asset.location else { continue }
            let thumb = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 120, height: 120))
            items.append(PhotoMapItem(id: asset.localIdentifier, coordinate: location.coordinate, image: thumb, isVideo: asset.mediaType == .video))
        }
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
                Label("Notes", systemImage: "note.text").font(.headline)
                Spacer()
                Button("Enregistrer") {
                    Task { await listVM.updateNotes(id: activity.id, notes: notesDraft) }
                }
                .disabled(notesDraft == (activity.notes ?? ""))
            }
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
                                Text(publishedURL == nil
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
        let photos = webOptions.includePhotos ? photoAssets.filter { !hiddenPhotoIDs.contains($0.localIdentifier) } : []
        let safeName = activity.title.replacingOccurrences(of: "/", with: "-")
        do {
            let output = try await HTMLReportRenderer.render(activity: activity, repository: repository, layer: layer, options: webOptions, photos: photos)
            progress.update(0.6, "Préparation des fichiers…")
            switch output {
            case .singleFile(let html):
                let panel = NSSavePanel()
                panel.title = "Exporter en page web"
                panel.nameFieldStringValue = "\(safeName).html"
                panel.allowedContentTypes = [.html]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try html.write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
        let uuid = existingPublishUUID() ?? UUID().uuidString.lowercased()
        try await BunnyStorageService.publish(files: files, folder: "traces/\(uuid)", onProgress: onProgress)
        let url = "https://www.gpxmanagement.net/traces/\(uuid)/"
        let configJSON = (try? JSONEncoder().encode(webOptions)).flatMap { String(data: $0, encoding: .utf8) }
        try await repository.setWebPublished(id: activity.id, url: url, configJSON: configJSON)
        publishedURL = url
        publishConfigJSON = configJSON
    }

    private func loadPublishState() async {
        publishedURL = try? await repository.fetchWebPublishedURL(id: activity.id)
        publishConfigJSON = try? await repository.fetchWebPublishConfig(id: activity.id)
    }

    /// Republie avec les paramètres de la publication d'origine (même UUID via le lien stocké).
    private func republishWeb() async {
        if let json = publishConfigJSON, let data = json.data(using: .utf8),
           var opts = try? JSONDecoder().decode(WebExportOptions.self, from: data) {
            opts.output = .publishBunny
            webOptions = opts
        } else {
            webOptions.output = .publishBunny
        }
        await exportWeb()
    }

    /// UUID du dossier déjà publié (extrait du lien stocké) pour republier au même endroit.
    private func existingPublishUUID() -> String? {
        guard let s = publishedURL, let comps = URLComponents(string: s) else { return nil }
        return comps.path.split(separator: "/").map(String.init).last
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

/// Rend la barre de titre transparente et le contenu pleine taille pendant le plein écran carte
/// (la carte couvre la zone de titre) ; restaure ensuite.
private struct FullScreenWindowConfigurator: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            w.titlebarAppearsTransparent = active
            w.titleVisibility = active ? .hidden : .visible
            if active { w.styleMask.insert(.fullSizeContentView) }
            else { w.styleMask.remove(.fullSizeContentView) }
        }
    }
}

private struct ActivityMapCard: View {
    let activityId: UUID
    let activityType: ActivityType
    let repository: CoreDataActivityRepository
    @Binding var layer: MapLayer
    let highlight: CLLocationCoordinate2D?
    let photos: [PhotoMapItem]
    var slopeOverlayOpacity: Double = 0
    var trackColorMode: TrackColorMode = .uniform
    var onFullscreen: (() -> Void)? = nil
    let onSelectPhoto: (String) -> Void

    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoaded = false

    var body: some View {
        Group {
            if !isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("Pas de tracé", systemImage: "map", description: Text("La trace ne contient pas de coordonnées."))
            } else {
                TrackMapView(tracks: tracks, layer: $layer, highlight: highlight, photos: photos, slopeOverlayOpacity: slopeOverlayOpacity, onSelectPhoto: onSelectPhoto)
                    .overlay(alignment: .bottomLeading) {
                        if let credit = layer.attribution {
                            Text(credit)
                                .font(.system(size: 9))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if slopeOverlayOpacity > 0 { slopeLegend.padding(6) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if trackColorMode != .uniform { trackColorLegend.padding(6) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let onFullscreen {
                            Button(action: onFullscreen) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .padding(7)
                                    .background(.black.opacity(0.5), in: Circle())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .help("Carte en plein écran")
                        }
                    }
            }
        }
        .task(id: "\(activityId.uuidString)|\(trackColorMode.rawValue)") { await load() }
    }

    /// Légende du code couleur de la trace (vitesse ou pente).
    @ViewBuilder
    private var trackColorLegend: some View {
        let items: [(String, Color)] = {
            switch trackColorMode {
            case .uniform: return []
            case .slope:
                let s = SlopeScale.percent
                return s.categories.map { (s.label(for: $0), Color(red: $0.rgb.r, green: $0.rgb.g, blue: $0.rgb.b)) }
            case .speed:
                let s = activityType.speedScale
                return s.categories.map { (s.label(for: $0), Color(red: $0.rgb.r, green: $0.rgb.g, blue: $0.rgb.b)) }
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(trackColorMode == .speed ? "Vitesse" : "Pente").font(.system(size: 9, weight: .semibold))
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                    Text(item.0).font(.system(size: 9))
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    /// Légende de la pente du terrain IGN (visible quand la trace neige est colorée sur fond IGN).
    private var slopeLegend: some View {
        let bands: [SlopeBand] = [.d30_35, .d35_40, .d40_45, .above45]
        return VStack(alignment: .leading, spacing: 2) {
            Text("Pente du terrain").font(.system(size: 9, weight: .semibold))
            ForEach(bands, id: \.label) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(band.color.map { Color(nsColor: $0) } ?? .clear)
                        .frame(width: 10, height: 10)
                    Text(band.label).font(.system(size: 9))
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    private func load() async {
        isLoaded = false
        guard let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
              let input = try? TrackOverlayInput.fromTrackData(data, activityId: activityId, activityType: activityType, colorMode: trackColorMode),
              !input.coordinates.isEmpty else {
            tracks = []
            isLoaded = true
            return
        }
        tracks = [input]
        isLoaded = true
    }
}

// MARK: - Photos prises pendant la trace

enum PhotoLibraryService {
    static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    /// Photos de la photothèque prises dans la fenêtre temporelle ET géolocalisées à proximité du tracé.
    static func photos(start: Date, end: Date, near coordinates: [CLLocationCoordinate2D], maxDistance: CLLocationDistance) -> [PHAsset] {
        guard start <= end, !coordinates.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@ AND (mediaType == %d OR mediaType == %d)",
            start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let samples = sampled(coordinates, max: 2000).map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let result = PHAsset.fetchAssets(with: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            if samples.contains(where: { $0.distance(from: location) <= maxDistance }) {
                out.append(asset)
            }
        }
        return out
    }

    static func fullImage(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1280, height: 1280), contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Image haute définition (recadrage). Plafonnée pour rester raisonnable en mémoire.
    static func editingImage(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 4096, height: 4096), contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Crée une nouvelle photo dans la photothèque (en conservant date et lieu de l'original). Renvoie son identifiant.
    static func createImageAsset(jpeg: Data, creationDate: Date?, location: CLLocation?) async -> String? {
        var newID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpeg, options: nil)
                request.creationDate = creationDate
                request.location = location
                newID = request.placeholderForCreatedAsset?.localIdentifier
            }
            return newID
        } catch {
            return nil
        }
    }

    /// Crée une nouvelle vidéo dans la photothèque depuis un fichier (date/lieu conservés). Renvoie son identifiant.
    static func createVideoAsset(fileURL: URL, creationDate: Date?, location: CLLocation?) async -> String? {
        var newID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: nil)
                request.creationDate = creationDate
                request.location = location
                newID = request.placeholderForCreatedAsset?.localIdentifier
            }
            return newID
        } catch {
            return nil
        }
    }

    /// Exporte un extrait recadré (trim + crop) d'une vidéo vers un fichier temporaire.
    /// `crop` est normalisé (0..1, origine haut-gauche) dans l'espace d'affichage orienté de la vidéo.
    static func exportEditedVideo(asset: AVAsset, start: Double, end: Double, crop: CGRect, to outputURL: URL) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let pref = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = natural.applying(pref)
        let displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard displaySize.width > 0, displaySize.height > 0 else { return false }

        let cropRect = CGRect(x: crop.minX * displaySize.width, y: crop.minY * displaySize.height,
                              width: crop.width * displaySize.width, height: crop.height * displaySize.height).integral
        guard cropRect.width >= 16, cropRect.height >= 16 else { return false }

        let composition = AVMutableVideoComposition()
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.renderSize = cropRect.size
        let instruction = AVMutableVideoCompositionInstruction()
        let duration = (try? await asset.load(.duration)) ?? .zero
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(pref.concatenating(CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return false }
        session.videoComposition = composition
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        try? FileManager.default.removeItem(at: outputURL)
        do { try await session.export(to: outputURL, as: .mp4); return true } catch { return false }
    }

    /// Supprime des assets (confirmation système requise pour la photothèque de l'utilisateur).
    static func deleteAssets(_ localIdentifiers: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            return true
        } catch {
            return false
        }
    }

    static func avAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    static func thumbnail(for asset: PHAsset, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Exporte l'original dans un fichier temporaire (réutilisé s'il existe) pour l'aperçu Quick Look in-app.
    static func exportForPreview(_ asset: PHAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = resources.first(where: { $0.type == wanted }) ?? resources.first else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GPXPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(resource.originalFilename)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil ? url : nil)
            }
        }
    }

    private static func sampled(_ coords: [CLLocationCoordinate2D], max: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > max else { return coords }
        let step = Double(coords.count) / Double(max)
        return (0..<max).map { coords[Int(Double($0) * step)] }
    }
}

private struct ActivityPhotosSection: View {
    let activityId: UUID
    let repository: CoreDataActivityRepository
    let start: Date
    let end: Date
    @Binding var assets: [PHAsset]
    @Binding var showOnMap: Bool
    let reloadToken: Int
    let isShownOnMap: (String) -> Bool
    let isAppCreated: (String) -> Bool
    let onToggleMap: (String) -> Void
    let onSelect: (PHAsset) -> Void
    let onEdit: (PHAsset) -> Void
    let onDelete: (PHAsset) -> Void

    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Photos & vidéos", systemImage: "photo.on.rectangle.angled").font(.headline)
                if !assets.isEmpty { Text("(\(assets.count))").foregroundStyle(.secondary) }
                Spacer()
                if !assets.isEmpty {
                    Toggle("Sur la carte", isOn: $showOnMap)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                }
            }
            content
        }
        .task(id: activityId) { await load() }
        .onChange(of: reloadToken) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .center)
        } else if status == .denied || status == .restricted {
            HStack(spacing: 8) {
                Text("Accès à la photothèque refusé.").font(.callout).foregroundStyle(.secondary)
                Button("Ouvrir les réglages…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if assets.isEmpty {
            Text("Aucune photo trouvée à proximité du parcours pendant cette activité.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    PhotoThumbnail(
                        asset: asset,
                        shownOnMap: isShownOnMap(asset.localIdentifier),
                        mapToggleEnabled: showOnMap,
                        isAppCreated: isAppCreated(asset.localIdentifier),
                        onToggleMap: { onToggleMap(asset.localIdentifier) },
                        onSelect: { onSelect(asset) },
                        onEdit: { onEdit(asset) },
                        onDelete: { onDelete(asset) }
                    )
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        status = await PhotoLibraryService.requestAccess()
        guard status == .authorized || status == .limited else { assets = []; return }

        var coordinates: [CLLocationCoordinate2D] = []
        if let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
           let points = try? TrackPointCodec.decode(data) {
            coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        // Petite marge temporelle (clocs appareil photo ≠ GPS) ; la proximité géographique cadre le résultat.
        assets = PhotoLibraryService.photos(
            start: start.addingTimeInterval(-900),
            end: end.addingTimeInterval(900),
            near: coordinates,
            maxDistance: 300
        )
    }
}

private struct PhotoThumbnail: View {
    let asset: PHAsset
    let shownOnMap: Bool
    let mapToggleEnabled: Bool
    let isAppCreated: Bool
    let onToggleMap: () -> Void
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    private var canEdit: Bool { asset.mediaType == .image || asset.mediaType == .video }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { onSelect() }
            .help(asset.mediaType == .video ? "Lire la vidéo" : "Ouvrir la photo")
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text(Self.durationText(asset.duration)).font(.system(size: 9).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(3)
                }
            }

            Button(action: onToggleMap) {
                Image(systemName: shownOnMap ? "mappin.circle.fill" : "mappin.slash.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, shownOnMap ? Color.accentColor : Color.secondary)
                    .background(Circle().fill(.black.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .padding(3)
            .opacity(mapToggleEnabled ? 1 : 0.45)
            .help(shownOnMap ? "Masquer sur la carte" : "Afficher sur la carte")
        }
        .overlay(alignment: .topLeading) {
            if canEdit && hovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Circle().fill(.black.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Modifier…")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if canEdit { Button("Modifier…") { onEdit() } }
            if isAppCreated { Button("Supprimer", role: .destructive) { onDelete() } }
        }
        .task(id: asset.localIdentifier) {
            image = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 200, height: 200))
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Édition de média (recadrage)

enum CropRatio: String, CaseIterable, Identifiable {
    case r16x9, r1x1, r9x16, original, free
    var id: String { rawValue }
    var label: String {
        switch self {
        case .r16x9: return "16:9"
        case .r1x1: return "1:1"
        case .r9x16: return "9:16"
        case .original: return "Original"
        case .free: return "Libre"
        }
    }
    /// Aspect cible en pixels (largeur/hauteur). nil = libre.
    func pixelAspect(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .r16x9: return 16.0 / 9.0
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16.0
        case .original: return imageAspect
        case .free: return nil
        }
    }
}

private struct EditingMedia: Identifiable {
    let id: String
    let asset: PHAsset
}

/// Recadrage d'une photo selon un ratio, puis enregistrement d'une nouvelle photo dans la photothèque.
private struct PhotoCropEditor: View {
    let asset: PHAsset
    let onCancel: () -> Void
    let onSave: (Data) -> Void

    @State private var image: NSImage?
    @State private var ratio: CropRatio = .original
    @State private var crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.5) // normalisé, origine haut-gauche

    private var imageAspect: CGFloat {
        guard let s = image?.size, s.height > 0 else { return 1 }
        return s.width / s.height
    }
    /// Aspect normalisé (nw/nh) correspondant au ratio pixel cible.
    private var normalizedAspect: CGFloat? {
        guard let r = ratio.pixelAspect(imageAspect: imageAspect) else { return nil }
        return r / imageAspect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recadrer la photo").font(.title3.bold())
            Picker("Format", selection: $ratio) {
                ForEach(CropRatio.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: ratio) { _, _ in resetCrop() }

            GeometryReader { geo in
                if let image {
                    let iv = Self.fit(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable()
                            .frame(width: iv.width, height: iv.height)
                            .position(x: iv.midX, y: iv.midY)
                        CropDim(crop: crop, imageRect: iv)
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        CropRectView(crop: $crop, imageRect: iv, normalizedAspect: normalizedAspect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .coordinateSpace(name: "crop")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 380)

            HStack {
                Spacer()
                Button("Annuler") { onCancel() }
                Button("Enregistrer") { if let data = makeJPEG() { onSave(data) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task {
            image = await PhotoLibraryService.editingImage(for: asset)
            resetCrop()
        }
    }

    private func resetCrop() {
        let an = normalizedAspect ?? imageAspect / imageAspect // libre → 1 (carré normalisé de base)
        var w: CGFloat = 1, h: CGFloat = 1
        if an >= 1 { w = 1; h = 1 / an } else { h = 1; w = an }
        if ratio == .free { w = 0.9; h = 0.9 }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func makeJPEG() -> Data? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let px = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H).integral
        guard let cropped = cg.cropping(to: px) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    static func fit(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let s = min(container.width / size.width, container.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

@MainActor @Observable private final class VideoPlayerModel {
    let player: AVPlayer
    var time: Double = 0
    var isPlaying = false
    var start = 0.0
    var end = 0.0
    @ObservationIgnored private var token: Any?

    init(asset: AVAsset) {
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.time = t.seconds
            if self.isPlaying, t.seconds >= self.end { self.seek(self.start) }
        }
    }
    func play(from s: Double) { seek(s); player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ s: Double) { player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func stop() { player.pause(); if let token { player.removeTimeObserver(token); self.token = nil } }
}

private struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView { let v = PlayerLayerView(); v.playerLayer.player = player; return v }
    func updateNSView(_ nsView: PlayerLayerView, context: Context) { nsView.playerLayer.player = player }
    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = playerLayer; playerLayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError() }
    }
}

/// Recadrage + extrait (trim) d'une vidéo, avec lecture, puis enregistrement dans la photothèque.
private struct VideoEditor: View {
    let asset: PHAsset
    let onCancel: () -> Void
    let onExported: (URL) -> Void

    @State private var avAsset: AVAsset?
    @State private var playback: VideoPlayerModel?
    @State private var displaySize: CGSize = .zero
    @State private var duration: Double = 0
    @State private var startT: Double = 0
    @State private var endT: Double = 0
    @State private var ratio: CropRatio = .original
    @State private var crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.5)
    @State private var isExporting = false

    private var imageAspect: CGFloat { displaySize.height > 0 ? displaySize.width / displaySize.height : 16.0 / 9.0 }
    private var normalizedAspect: CGFloat? {
        guard let r = ratio.pixelAspect(imageAspect: imageAspect) else { return nil }
        return r / imageAspect
    }
    private var playheadBinding: Binding<Double> {
        Binding(get: { playback?.time ?? 0 }, set: { playback?.seek($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recadrer / extraire la vidéo").font(.title3.bold())
            Picker("Format", selection: $ratio) {
                ForEach(CropRatio.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .onChange(of: ratio) { _, _ in resetCrop() }

            GeometryReader { geo in
                if let playback, displaySize != .zero {
                    let iv = PhotoCropEditor.fit(displaySize, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        VideoPlayerSurface(player: playback.player)
                            .frame(width: iv.width, height: iv.height)
                            .position(x: iv.midX, y: iv.midY)
                        CropDim(crop: crop, imageRect: iv).fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        CropRectView(crop: $crop, imageRect: iv, normalizedAspect: normalizedAspect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .coordinateSpace(name: "crop")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 320)

            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: (playback?.isPlaying ?? false) ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .disabled(playback == nil)
                TrimBar(duration: duration, start: $startT, end: $endT, playhead: playheadBinding)
                    .frame(height: 34)
            }
            Text("Extrait : \(Self.time(startT)) → \(Self.time(endT))  ·  \(Self.time(endT - startT))")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                if isExporting { ProgressView().controlSize(.small); Text("Export…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Annuler") { playback?.stop(); onCancel() }.disabled(isExporting)
                Button("Enregistrer") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(avAsset == nil || isExporting || endT - startT < 0.3)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task {
            let a = await PhotoLibraryService.avAsset(for: asset)
            avAsset = a
            guard let a, let track = try? await a.loadTracks(withMediaType: .video).first else { return }
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let pref = (try? await track.load(.preferredTransform)) ?? .identity
            let oriented = natural.applying(pref)
            displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            duration = (try? await a.load(.duration).seconds) ?? 0
            startT = 0; endT = duration
            let model = VideoPlayerModel(asset: a)
            model.start = 0; model.end = duration
            playback = model
            resetCrop()
        }
        .onChange(of: startT) { _, v in playback?.start = v }
        .onChange(of: endT) { _, v in playback?.end = v }
        .onDisappear { playback?.stop() }
    }

    private func togglePlay() {
        guard let p = playback else { return }
        if p.isPlaying { p.pause() }
        else { p.play(from: p.time >= endT - 0.05 ? startT : max(startT, p.time)) }
    }

    private func resetCrop() {
        let an = normalizedAspect ?? 1
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio == .free { w = 0.9; h = 0.9 } else if an >= 1 { w = 1; h = 1 / an } else { h = 1; w = an }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func export() async {
        guard let a = avAsset else { return }
        playback?.pause()
        isExporting = true
        defer { isExporting = false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).mp4")
        if await PhotoLibraryService.exportEditedVideo(asset: a, start: startT, end: endT, crop: crop, to: url) {
            playback?.stop()
            onExported(url)
        }
    }

    static func time(_ s: Double) -> String {
        let total = Int(max(0, s).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TrimBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { t in duration > 0 ? CGFloat(t / duration) * w : 0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.25))
                // zone retenue
                Rectangle().fill(Color.accentColor.opacity(0.3))
                    .frame(width: max(0, x(end) - x(start)))
                    .offset(x: x(start))
                // playhead
                Rectangle().fill(.white).frame(width: 2).offset(x: x(playhead))
                handle(color: .accentColor, at: x(start)) { nx in
                    start = min(max(0, nx / w * duration), end - 0.3)
                    playhead = start
                }
                handle(color: .accentColor, at: x(end)) { nx in
                    end = max(min(duration, nx / w * duration), start + 0.3)
                    playhead = end
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                playhead = min(max(0, Double(v.location.x / w) * duration), duration)
            })
        }
    }

    private func handle(color: Color, at px: CGFloat, onMove: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color)
            .frame(width: 10)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1))
            .offset(x: px - 5)
            .highPriorityGesture(DragGesture(coordinateSpace: .local).onChanged { v in onMove(v.location.x) })
    }
}

private struct CropDim: Shape {
    let crop: CGRect
    let imageRect: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path(imageRect)
        p.addRect(CGRect(x: imageRect.minX + crop.minX * imageRect.width,
                         y: imageRect.minY + crop.minY * imageRect.height,
                         width: crop.width * imageRect.width,
                         height: crop.height * imageRect.height))
        return p
    }
}

private struct CropRectView: View {
    @Binding var crop: CGRect
    let imageRect: CGRect
    let normalizedAspect: CGFloat?
    @State private var dragStart: CGRect?

    private func viewRect() -> CGRect {
        CGRect(x: imageRect.minX + crop.minX * imageRect.width,
               y: imageRect.minY + crop.minY * imageRect.height,
               width: crop.width * imageRect.width, height: crop.height * imageRect.height)
    }

    var body: some View {
        let r = viewRect()
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .overlay(Rectangle().strokeBorder(.white, lineWidth: 2))
                .position(x: r.midX, y: r.midY)
                .gesture(moveGesture)
            handle(at: CGPoint(x: r.minX, y: r.minY), corner: .topLeft)
            handle(at: CGPoint(x: r.maxX, y: r.maxY), corner: .bottomRight)
        }
    }

    private enum Corner { case topLeft, bottomRight }

    private func handle(at p: CGPoint, corner: Corner) -> some View {
        Circle().fill(.white).frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.gray, lineWidth: 1))
            .position(x: p.x, y: p.y)
            .highPriorityGesture(
                DragGesture(coordinateSpace: .named("crop"))
                    .onChanged { v in resize(corner: corner, to: v.location) }
            )
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("crop"))
            .onChanged { v in
                let s = dragStart ?? crop; if dragStart == nil { dragStart = s }
                let dx = Double(v.translation.width) / Double(imageRect.width)
                let dy = Double(v.translation.height) / Double(imageRect.height)
                crop.origin = CGPoint(x: min(max(0, s.minX + dx), 1 - crop.width),
                                      y: min(max(0, s.minY + dy), 1 - crop.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resize(corner: Corner, to location: CGPoint) {
        let nx = Double((location.x - imageRect.minX) / imageRect.width)
        let ny = Double((location.y - imageRect.minY) / imageRect.height)
        let cx = min(max(0, nx), 1), cy = min(max(0, ny), 1)
        switch corner {
        case .bottomRight:
            let anchorX = crop.minX, anchorY = crop.minY
            var w = max(0.05, cx - anchorX), h = max(0.05, cy - anchorY)
            if let an = normalizedAspect {
                h = w / an
                if anchorY + h > 1 { h = 1 - anchorY; w = h * an }
                if anchorX + w > 1 { w = 1 - anchorX; h = w / an }
            } else {
                w = min(w, 1 - anchorX); h = min(h, 1 - anchorY)
            }
            crop = CGRect(x: anchorX, y: anchorY, width: w, height: h)
        case .topLeft:
            let anchorX = crop.maxX, anchorY = crop.maxY
            var w = max(0.05, anchorX - cx), h = max(0.05, anchorY - cy)
            if let an = normalizedAspect {
                h = w / an
                if anchorY - h < 0 { h = anchorY; w = h * an }
                if anchorX - w < 0 { w = anchorX; h = w / an }
            } else {
                w = min(w, anchorX); h = min(h, anchorY)
            }
            crop = CGRect(x: anchorX - w, y: anchorY - h, width: w, height: h)
        }
    }
}

// MARK: - Éditeur de disposition vidéo

struct VideoLayoutEditor: View {
    static let space = "videoEditor"
    let aspect: Double
    @Binding var layout: VideoLayout
    let tracePoints: [CGPoint]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.16))
                ZoneBox(zone: $layout.trace, canvas: geo.size, color: .blue, label: "Trace") {
                    TracePreview(points: tracePoints).padding(5)
                }
                ZoneBox(zone: $layout.media, canvas: geo.size, color: .orange, label: "Photo / Vidéo") {
                    Image(systemName: "photo").foregroundStyle(.orange.opacity(0.7))
                }
                if layout.profile != nil {
                    ZoneBox(zone: Binding(get: { layout.profile ?? LayoutZone(x: 0.6, y: 0.74, w: 0.38, h: 0.22) },
                                          set: { layout.profile = $0 }),
                            canvas: geo.size, color: .teal, label: "Profil") {
                        Image(systemName: "chart.xyaxis.line").foregroundStyle(.teal.opacity(0.7))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
            .coordinateSpace(name: Self.space)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: 480, maxHeight: 360)
    }
}

private struct ZoneBox<Content: View>: View {
    @Binding var zone: LayoutZone
    let canvas: CGSize
    let color: Color
    let label: String
    @ViewBuilder var content: Content
    @State private var startZone: LayoutZone?

    var body: some View {
        let rw = zone.w * canvas.width
        let rh = zone.h * canvas.height
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.14))
            content.frame(width: rw, height: rh).clipped()
            RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 2)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(color.opacity(0.85)).foregroundStyle(.white).clipShape(Capsule())
                .padding(3)
        }
        .frame(width: rw, height: rh)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(color)
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: "arrow.down.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                .offset(x: 7, y: 7)
                .highPriorityGesture(
                    // Le coin suit la position absolue du curseur (repère du canevas) → pas de rétroaction.
                    DragGesture(coordinateSpace: .named(VideoLayoutEditor.space))
                        .onChanged { v in
                            let nw = Swift.min(Swift.max(0.12, Double(v.location.x) / Double(canvas.width) - zone.x), 1 - zone.x)
                            let nh = Swift.min(Swift.max(0.10, Double(v.location.y) / Double(canvas.height) - zone.y), 1 - zone.y)
                            zone.w = nw; zone.h = nh
                        }
                )
        }
        .offset(x: zone.x * canvas.width, y: zone.y * canvas.height)
        .gesture(
            DragGesture()
                .onChanged { v in
                    let s = startZone ?? zone; if startZone == nil { startZone = s }
                    let nx = Swift.min(Swift.max(0, s.x + Double(v.translation.width) / Double(canvas.width)), 1 - zone.w)
                    let ny = Swift.min(Swift.max(0, s.y + Double(v.translation.height) / Double(canvas.height)), 1 - zone.h)
                    zone.x = nx; zone.y = ny
                }
                .onEnded { _ in startZone = nil }
        )
    }
}

private struct TracePreview: View {
    let points: [CGPoint]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard points.count > 1 else { return }
                let maxX = points.map(\.x).max() ?? 1, maxY = points.map(\.y).max() ?? 1
                let sc = Swift.min(geo.size.width / Swift.max(0.01, maxX), geo.size.height / Swift.max(0.01, maxY))
                let ox = (geo.size.width - maxX * sc) / 2, oy = (geo.size.height - maxY * sc) / 2
                func pt(_ q: CGPoint) -> CGPoint { CGPoint(x: ox + q.x * sc, y: oy + q.y * sc) }
                path.move(to: pt(points[0]))
                for q in points.dropFirst() { path.addLine(to: pt(q)) }
            }
            .stroke(Color.red, lineWidth: 2)
        }
    }
}

struct MetricCard: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}
