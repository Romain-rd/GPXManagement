import SwiftUI
import AppKit
import PhotosUI
import Photos
import CoreLocation
import MapKit
import GPXCore
import GPXMapKit

struct RaidDetailView: View {
    let raid: Raid
    let listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    let navigation: AppNavigationModel

    @State private var draft: Raid
    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignScan25.rawValue
    @AppStorage("slopeOverlayEnabled") private var slopeOverlayEnabled: Bool = false
    @AppStorage("slopeOverlayOpacity") private var slopeOverlayOpacity: Double = 0.6
    @AppStorage("trackColorMode") private var trackColorModeRaw: String = TrackColorMode.uniform.rawValue
    @State private var layer: MapLayer = .ignScan25
    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoadingMap = true
    @State private var proxy = MapViewProxy()
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var editingParticipant: RaidParticipant?
    @State private var isAddingParticipant = false
    @State private var showFilmOptions = false
    @State private var filmPublish = false
    @State private var filmPublishedURL: String?
    @State private var isExportingFilm = false
    @State private var filmProgress: Double = 0
    @State private var filmStatus = ""
    @State private var exportError: String?
    @State private var showWebExportOptions = false
    @State private var isExportingWeb = false
    @State private var webOptions = WebExportOptions()
    @State private var publishedURL: String?
    @State private var publishConfigJSON: String?

    @AppStorage("raidVideoQuality") private var raidVideoQualityRaw = VideoQuality.hd720.rawValue
    @AppStorage("raidVideoFormat") private var raidVideoFormatRaw = VideoFormat.landscape.rawValue
    @AppStorage("raidVideoTransition") private var raidVideoTransitionRaw = MediaTransition.fade.rawValue
    @AppStorage("raidVideoMapLayer") private var raidVideoMapLayerRaw = MapLayer.ignScan25.rawValue
    @AppStorage("raidVideoHeartRate") private var raidVideoHeartRateOn = true
    @AppStorage("raidVideoStageCards") private var raidVideoStageCardsOn = true

    @State private var stageLayouts: [UUID: VideoLayout] = [:]
    @State private var editingLayoutStageId: UUID?
    @State private var editingLayout = VideoLayout.defaultLayout(for: .landscape)
    @State private var editingTracePoints: [CGPoint] = []

    @AppStorage("videoUserTemplates") private var userTemplatesJSON = ""
    @State private var editingTemplateID: String?
    @State private var showTemplateNameAlert = false
    @State private var templateNameInput = ""
    @State private var savingNewTemplate = false

    private var filmFormat: VideoFormat { VideoFormat(rawValue: raidVideoFormatRaw) ?? .landscape }

    private func layoutFor(_ id: UUID) -> VideoLayout {
        stageLayouts[id] ?? VideoLayout.defaultLayout(for: filmFormat)
    }

    init(raid: Raid, listVM: ActivityListViewModel, repository: CoreDataActivityRepository, navigation: AppNavigationModel) {
        self.raid = raid
        self.listVM = listVM
        self.repository = repository
        self.navigation = navigation
        _draft = State(initialValue: raid)
    }

    private var members: [ActivitySummary] {
        listVM.allActivities.filter { $0.raidId == raid.id }.sorted { $0.startDate < $1.startDate }
    }

    private var isDirty: Bool {
        draft.name != raid.name
            || (draft.place ?? "") != (raid.place ?? "")
            || (draft.notes ?? "") != (raid.notes ?? "")
            || draft.participants != raid.participants
            || draft.coverImageData != raid.coverImageData
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                coverBanner
                header
                statsGrid
                publishedLinkSection
                filmLinkSection
                participantsSection
                mapCard
                stepsSection
                infoSection
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(raid.name)
        .toolbar { ToolbarItemGroup { raidActions } }
        .task(id: "\(raid.id.uuidString)|\(trackColorModeRaw)") { await loadMap() }
        .task(id: raid.id) { await loadStageLayouts() }
        .task(id: raid.id) { await loadPublishState() }
        .sheet(isPresented: $showWebExportOptions) { webExportOptionsSheet }
        .onAppear { layer = MapLayer.base(fromRawValue: defaultLayerRaw) }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
        .onChange(of: coverPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let resized = Self.downscaledJPEG(data, maxDimension: 1600) {
                    draft.coverImageData = resized
                    await listVM.saveRaid(draft)
                }
                coverPickerItem = nil
            }
        }
        .sheet(isPresented: $isAddingParticipant) {
            RaidParticipantEditor(participant: RaidParticipant(name: ""), onSave: { updated in
                draft.participants.append(updated)
                persist()
            }, onDelete: nil)
        }
        .sheet(item: $editingParticipant) { participant in
            RaidParticipantEditor(participant: participant, onSave: { updated in
                if let idx = draft.participants.firstIndex(where: { $0.id == updated.id }) {
                    draft.participants[idx] = updated
                    persist()
                }
            }, onDelete: {
                draft.participants.removeAll { $0.id == participant.id }
                persist()
            })
        }
        .sheet(isPresented: $showFilmOptions) {
            raidFilmOptions
        }
        .sheet(isPresented: Binding(get: { editingLayoutStageId != nil }, set: { if !$0 { editingLayoutStageId = nil } })) {
            layoutEditorSheet
        }
        .alert("Export du raid", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Barre d'actions

    @ViewBuilder
    private var raidActions: some View {
        if isExportingFilm {
            ProgressView(value: filmProgress).frame(width: 90)
            Text(filmStatus.isEmpty ? "\(Int((filmProgress * 100).rounded())) %" : filmStatus)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Button {
            exportGroupedGPX()
        } label: {
            Label("Exporter les GPX", systemImage: "square.and.arrow.up.on.square")
        }
        .disabled(members.isEmpty || isExportingFilm)

        Button {
            showWebExportOptions = true
        } label: {
            if isExportingWeb { ProgressView().controlSize(.small) }
            else { Label("Exporter en page web", systemImage: "globe") }
        }
        .disabled(members.isEmpty || isExportingWeb)

        Button {
            showFilmOptions = true
        } label: {
            Label("Film du raid", systemImage: "film")
        }
        .disabled(members.isEmpty || isExportingFilm)
    }

    // MARK: Publication web

    @ViewBuilder
    private var filmLinkSection: some View {
        if let urlString = filmPublishedURL, let url = URL(string: urlString) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "film").foregroundStyle(.tint)
                    Text("Film publié").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        filmPublish = true
                        showFilmOptions = true
                    } label: {
                        Label("Recréer", systemImage: "arrow.clockwise")
                    }
                    .disabled(isExportingFilm || !BunnyStorageService.isConfigured)
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
        if let urlString = publishedURL, let url = URL(string: urlString) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundStyle(.tint)
                    Text("Publié sur le web").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await republishWeb() } } label: {
                        if isExportingWeb { ProgressView().controlSize(.small) } else { Label("Republier", systemImage: "arrow.clockwise") }
                    }
                    .disabled(isExportingWeb || !BunnyStorageService.isConfigured)
                    .help("Republier avec les mêmes paramètres")
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

    private var webExportOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporter le raid en page web").font(.title3.bold())
            Text("Génère une page d'ensemble du raid (couverture, participants, carte multi-traces) reliant une page par étape.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Carte").gridColumnAlignment(.trailing)
                    Picker("", selection: $webOptions.map) {
                        ForEach(WebExportOptions.MapRendering.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Profil").gridColumnAlignment(.trailing)
                    Picker("", selection: $webOptions.profile) {
                        ForEach(WebExportOptions.ProfileRendering.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Destination").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("", selection: $webOptions.output) {
                            Text(WebExportOptions.Output.folder.label).tag(WebExportOptions.Output.folder)
                            Text(WebExportOptions.Output.publishBunny.label).tag(WebExportOptions.Output.publishBunny)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if webOptions.output == .publishBunny, !BunnyStorageService.isConfigured {
                            Text("⚠︎ Bunny non configuré (renseigner Secrets.xcconfig).").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                GridRow {
                    Text("Photos").gridColumnAlignment(.trailing)
                    Toggle("Inclure les photos des étapes", isOn: $webOptions.includePhotos)
                }
                GridRow {
                    Text("Notes").gridColumnAlignment(.trailing)
                    Toggle("Inclure les notes", isOn: $webOptions.includeNotes)
                }
            }

            HStack {
                Spacer()
                Button("Annuler") { showWebExportOptions = false }
                Button(webOptions.output == .publishBunny ? "Publier" : "Générer") {
                    showWebExportOptions = false
                    Task { await exportRaidWeb() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(webOptions.output == .publishBunny && !BunnyStorageService.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func loadPublishState() async {
        publishedURL = try? await repository.fetchRaidWebPublishedURL(id: raid.id)
        publishConfigJSON = try? await repository.fetchRaidWebPublishConfig(id: raid.id)
        filmPublishedURL = try? await repository.fetchRaidFilmPublishedURL(id: raid.id)
    }

    private func exportRaidWeb() async {
        isExportingWeb = true
        let progress = WebExportProgress.shared
        progress.begin("Préparation…")
        defer { isExportingWeb = false; progress.end() }
        let mapLayer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25
        let safeName = raid.name.replacingOccurrences(of: "/", with: "-")
        do {
            if webOptions.includePhotos { progress.update(0, "Recherche des photos…") }
            let stagePhotos = await gatherStagePhotos()
            let files = try await HTMLReportRenderer.renderRaid(raid: raid, members: members, repository: repository, layer: mapLayer, options: webOptions, stagePhotos: stagePhotos) { f, s in
                progress.update(f * 0.7, s)
            }
            if webOptions.output == .publishBunny {
                try await publishRaidToBunny(files: files) { f, s in progress.update(0.7 + f * 0.3, s) }
            } else {
                progress.update(0.9, "Écriture du dossier…")
                let panel = NSSavePanel()
                panel.title = "Exporter le raid en page web"
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
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func gatherStagePhotos() async -> [UUID: [PHAsset]] {
        guard webOptions.includePhotos else { return [:] }
        let status = await PhotoLibraryService.requestAccess()
        guard status == .authorized || status == .limited else { return [:] }
        // Ne garder que les photos sélectionnées (affichées sur la carte) — pas toutes celles trouvées.
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "photosHiddenOnMap") ?? [])
        var result: [UUID: [PHAsset]] = [:]
        for m in members {
            var coords: [CLLocationCoordinate2D] = []
            if let data = try? await repository.fetchTrackData(id: m.id), !data.isEmpty, let pts = try? TrackPointCodec.decode(data) {
                coords = pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            }
            result[m.id] = PhotoLibraryService.photos(start: m.startDate.addingTimeInterval(-1800), end: m.endDate.addingTimeInterval(1800), near: coords, maxDistance: 300)
                .filter { !hidden.contains($0.localIdentifier) }
        }
        return result
    }

    private func publishRaidToBunny(files: [String: Data], onProgress: ((Double, String) -> Void)? = nil) async throws {
        let uuid = existingPublishUUID() ?? UUID().uuidString.lowercased()
        try await BunnyStorageService.publish(files: files, folder: "raids/\(uuid)", onProgress: onProgress)
        let url = "https://www.gpxmanagement.net/raids/\(uuid)/"
        let configJSON = (try? JSONEncoder().encode(webOptions)).flatMap { String(data: $0, encoding: .utf8) }
        try await repository.setRaidWebPublished(id: raid.id, url: url, configJSON: configJSON)
        publishedURL = url
        publishConfigJSON = configJSON
    }

    private func existingPublishUUID() -> String? {
        guard let s = publishedURL, let comps = URLComponents(string: s) else { return nil }
        return comps.path.split(separator: "/").map(String.init).last
    }

    private func republishWeb() async {
        if let json = publishConfigJSON, let data = json.data(using: .utf8), var opts = try? JSONDecoder().decode(WebExportOptions.self, from: data) {
            opts.output = .publishBunny
            webOptions = opts
        } else {
            webOptions.output = .publishBunny
        }
        await exportRaidWeb()
    }

    // MARK: Couverture

    @ViewBuilder
    private var coverBanner: some View {
        if let data = draft.coverImageData, let image = NSImage(data: data) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Menu {
                    PhotosPicker("Changer la photo…", selection: $coverPickerItem, matching: .images)
                    Button("Retirer la photo", role: .destructive) {
                        draft.coverImageData = nil
                        persist()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(10)
            }
        } else {
            PhotosPicker(selection: $coverPickerItem, matching: .images) {
                Label("Ajouter une photo de couverture", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Participants").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(draft.participants) { participant in
                    Button { editingParticipant = participant } label: {
                        participantChip(participant)
                    }
                    .buttonStyle(.plain)
                }
                Button { isAddingParticipant = true } label: {
                    Label("Ajouter", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func participantChip(_ participant: RaidParticipant) -> some View {
        HStack(spacing: 8) {
            ParticipantAvatar(participant: participant, size: 28)
            Text(participant.name.isEmpty ? "Sans nom" : participant.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: Capsule())
        .contentShape(Capsule())
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "flag.2.crossed.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                TextField("Nom du raid", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .onSubmit { save() }
            }
            TextField("Lieu / région (facultatif)", text: Binding(
                get: { draft.place ?? "" },
                set: { draft.place = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .font(.title3)
            .foregroundStyle(.secondary)
            .onSubmit { save() }

            if let range = dateRangeText {
                Label(range, systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Statistiques cumulées

    private var statsGrid: some View {
        let totalDistance = members.reduce(0) { $0 + $1.distance }
        let totalGain = members.reduce(0) { $0 + $1.elevationGain }
        let totalMoving = members.reduce(0) { $0 + $1.movingDuration }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            statTile("Étapes", "\(members.count)", "point.topleft.down.to.point.bottomright.curvepath")
            statTile("Distance", Self.formatDistance(totalDistance), "ruler")
            statTile("Dénivelé +", "\(Int(totalGain.rounded())) m", "mountain.2")
            statTile("Temps en mouvement", Self.formatDuration(totalMoving), "stopwatch")
        }
    }

    private func statTile(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Carte multi-traces

    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isLoadingMap {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                } else if tracks.isEmpty {
                    ContentUnavailableView("Aucune trace", systemImage: "map",
                                           description: Text("Les étapes de ce raid n'ont pas de données GPS."))
                        .frame(minHeight: 320)
                } else {
                    TrackMapView(tracks: tracks, layer: $layer, proxy: proxy, slopeOverlayOpacity: slopeOverlayEnabled ? slopeOverlayOpacity : 0, onSelectActivity: { id in
                        navigation.visualizationMode = .activities
                        navigation.listSelection = [id]
                    })
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            if !tracks.isEmpty {
                HStack(spacing: 8) {
                    TrackColorControl(mode: Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue }))
                    if layer.isIGN {
                        SlopeOverlayControl(enabled: $slopeOverlayEnabled, opacity: $slopeOverlayOpacity)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    LayerPicker(layer: $layer)
                }
                .padding(8)
            }
        }
    }

    // MARK: Étapes

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Étapes").font(.headline)
            if members.isEmpty {
                Text("Aucune activité dans ce raid.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                Text("La disposition (profil / photos) de chaque étape sert au film du raid et de modèle par défaut pour le film de cette trace.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(members.enumerated()), id: \.element.id) { index, activity in
                    stepRow(index: index + 1, activity: activity)
                }
            }
        }
    }

    private func stepRow(index: Int, activity: ActivitySummary) -> some View {
        HStack(spacing: 12) {
            Button {
                navigation.visualizationMode = .activities
                navigation.listSelection = [activity.id]
            } label: {
                HStack(spacing: 12) {
                    Text("J\(index)")
                        .font(.caption.bold().monospacedDigit())
                        .frame(width: 34, height: 34)
                        .background(.tint.opacity(0.15), in: Circle())
                    Image(systemName: activity.activityType.symbolName)
                        .frame(width: 24)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title).font(.body)
                        Text("\(Self.dayFormatter.string(from: activity.startDate)) · \(Self.formatDistance(activity.distance)) · \(Int(activity.elevationGain.rounded())) m D+")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editLayout(for: activity)
            } label: {
                RaidLayoutThumbnail(layout: layoutFor(activity.id), aspect: filmFormat.aspect)
                    .frame(width: 116)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(3)
                    }
            }
            .buttonStyle(.plain)
            .help("Modifier la disposition (profil / photos) de cette étape")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var layoutEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disposition de l'étape").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("MODÈLE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                layoutTemplateBar
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.15)))

            Toggle("Afficher le profil altimétrique", isOn: Binding(
                get: { editingLayout.profile != nil },
                set: { on in
                    if on { editingLayout.profile = VideoLayout.defaultLayout(for: filmFormat).profile ?? LayoutZone(x: 0.6, y: 0.74, w: 0.38, h: 0.22) }
                    else { editingLayout.profile = nil }
                }
            ))
            Text("Glissez les zones pour les déplacer, la poignée (coin) pour les redimensionner. Format : \(filmFormat.label).")
                .font(.caption).foregroundStyle(.secondary)
            VideoLayoutEditor(aspect: filmFormat.aspect, layout: $editingLayout, tracePoints: editingTracePoints)
            HStack {
                Button("Réinitialiser") { editingLayout = VideoLayout.defaultLayout(for: filmFormat) }
                Spacer()
                Button("Annuler") { editingLayoutStageId = nil }
                Button("Enregistrer") { saveEditingLayout() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
        .alert(savingNewTemplate ? "Nouveau modèle" : "Renommer le modèle", isPresented: $showTemplateNameAlert) {
            TextField("Nom du modèle", text: $templateNameInput)
            Button(savingNewTemplate ? "Enregistrer" : "Renommer") {
                let name = templateNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if savingNewTemplate { saveLayoutAsNewTemplate(name: name) } else { renameSelectedTemplate(name) }
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var layoutTemplateBar: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Prédéfinis") {
                    ForEach(VideoTemplate.builtins) { t in
                        Button { applyTemplateToEditor(t) } label: {
                            Label(t.name, systemImage: t.id == editingTemplateID ? "checkmark" : "")
                        }
                    }
                }
                if !userTemplates.isEmpty {
                    Section("Mes modèles") {
                        ForEach(userTemplates) { t in
                            Button { applyTemplateToEditor(t) } label: {
                                Label(t.name, systemImage: t.id == editingTemplateID ? "checkmark" : "")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                    Text(selectedEditorTemplate?.name ?? "Modèle")
                    if !editorMatchesTemplate { Text("• modifié").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .fixedSize()

            Spacer()

            Button("Enregistrer sous…") {
                savingNewTemplate = true
                templateNameInput = (selectedEditorTemplate?.name).map { "\($0) copie" } ?? "Ma disposition"
                showTemplateNameAlert = true
            }
            if let t = selectedEditorTemplate, !t.builtin {
                Button("Mettre à jour") { updateSelectedTemplate() }
                    .disabled(editorMatchesTemplate)
                Menu {
                    Button("Renommer…") { savingNewTemplate = false; templateNameInput = t.name; showTemplateNameAlert = true }
                    Button("Supprimer", role: .destructive) { deleteSelectedTemplate() }
                } label: { Image(systemName: "ellipsis.circle") }
                .fixedSize()
            }
        }
    }

    // MARK: Informations / notes

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                if isDirty {
                    Button("Enregistrer") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            TextEditor(text: Binding(
                get: { draft.notes ?? "" },
                set: { draft.notes = $0.isEmpty ? nil : $0 }
            ))
            .frame(minHeight: 90)
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .font(.body)
        }
    }

    // MARK: Actions

    // MARK: Film & export groupé

    private var raidFilmOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Film du raid").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Qualité")
                    Picker("", selection: $raidVideoQualityRaw) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Format")
                    Picker("", selection: $raidVideoFormatRaw) {
                        ForEach(VideoFormat.allCases) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Animation")
                    Picker("", selection: $raidVideoTransitionRaw) {
                        ForEach(MediaTransition.allCases) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Fond de carte")
                    LayerPicker(layer: Binding(
                        get: { MapLayer(rawValue: raidVideoMapLayerRaw) ?? .ignScan25 },
                        set: { raidVideoMapLayerRaw = $0.rawValue }
                    ))
                }
            }
            Toggle("Profil + fréquence cardiaque", isOn: $raidVideoHeartRateOn)
            Toggle("Carton de titre par étape", isOn: $raidVideoStageCardsOn)
            HStack(spacing: 8) {
                Text("Destination")
                Picker("", selection: $filmPublish) {
                    Text("Fichier").tag(false)
                    Text("GPXManagement.net").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if filmPublish && !BunnyStorageService.isConfigured {
                    Text("⚠︎ Bunny non configuré").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
            }
            Text("Les photos et vidéos géolocalisées proches de chaque étape sont ajoutées automatiquement. L'intro et la fin reprennent la couverture et les participants.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler") { showFilmOptions = false }
                Button(filmPublish ? "Générer et publier" : "Générer") { showFilmOptions = false; generateRaidFilm(publish: filmPublish) }
                    .buttonStyle(.borderedProminent)
                    .disabled(filmPublish && !BunnyStorageService.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func cumulativeSummary() -> [(label: String, value: String)] {
        let totalDistance = members.reduce(0) { $0 + $1.distance }
        let totalGain = members.reduce(0) { $0 + $1.elevationGain }
        let totalMoving = members.reduce(0) { $0 + $1.movingDuration }
        return [
            ("Étapes", "\(members.count)"),
            ("Distance", Self.formatDistance(totalDistance)),
            ("Dénivelé +", "\(Int(totalGain.rounded())) m"),
            ("Temps", Self.formatDuration(totalMoving))
        ]
    }

    private func generateRaidFilm(publish: Bool) {
        let quality = VideoQuality(rawValue: raidVideoQualityRaw) ?? .hd720
        let format = VideoFormat(rawValue: raidVideoFormatRaw) ?? .landscape
        let dims = format.dimensions(base: quality.base)
        let mapLayer = MapLayer(rawValue: raidVideoMapLayerRaw) ?? .ignScan25
        let transition = MediaTransition(rawValue: raidVideoTransitionRaw) ?? .fade

        let url: URL
        if publish {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("raid-film-\(UUID().uuidString).mp4")
        } else {
            let panel = NSSavePanel()
            panel.title = "Enregistrer le film du raid"
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = raid.name.replacingOccurrences(of: "/", with: "-") + ".mp4"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        let memberList = members
        let cover = draft.coverImageData.flatMap { NSImage(data: $0) }
        let participants = draft.participants.map { (name: $0.name, avatar: $0.avatarImageData.flatMap { NSImage(data: $0) }) }
        let summary = cumulativeSummary()
        let dateText = dateRangeText ?? ""
        let place = draft.place

        Task {
            isExportingFilm = true
            filmProgress = 0
            filmStatus = "Préparation…"
            defer { isExportingFilm = false; filmStatus = "" }

            let status = await PhotoLibraryService.requestAccess()
            var stages: [RaidVideoStage] = []
            for (i, member) in memberList.enumerated() {
                filmStatus = "Étape \(i + 1)/\(memberList.count)…"
                guard let data = try? await repository.fetchTrackData(id: member.id), !data.isEmpty,
                      let points = try? TrackPointCodec.decode(data), points.count >= 2 else { continue }
                var media: [TrackVideoMedia] = []
                if status == .authorized || status == .limited {
                    let coords = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let assets = PhotoLibraryService.photos(
                        start: member.startDate.addingTimeInterval(-1800),
                        end: member.endDate.addingTimeInterval(1800),
                        near: coords, maxDistance: 300
                    )
                    for asset in assets {
                        guard let coord = PhotoLibraryService.resolvedCoordinate(for: asset, in: points) else { continue }
                        let thumb = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 160, height: 160))
                        if asset.mediaType == .video {
                            if let av = await PhotoLibraryService.avAsset(for: asset) {
                                media.append(.video(asset: av, thumbnail: thumb, coordinate: coord))
                            }
                        } else if let image = await PhotoLibraryService.fullImage(for: asset) {
                            media.append(.photo(image: image, thumbnail: thumb, coordinate: coord))
                        }
                    }
                }
                stages.append(RaidVideoStage(
                    title: member.title,
                    dateText: Self.dayFormatter.string(from: member.startDate),
                    points: points, media: media, layout: layoutFor(member.id)
                ))
            }

            let config = RaidVideoConfig(
                width: dims.width, height: dims.height, transition: transition,
                showHeartRate: raidVideoHeartRateOn, showStageCards: raidVideoStageCardsOn,
                mapLayer: mapLayer, title: raid.name, dateText: dateText, place: place,
                summary: summary, coverImage: cover, participants: participants
            )
            filmStatus = "Rendu de la vidéo…"
            do {
                try await RaidVideoExporter.export(stages: stages, config: config, to: url) { f in
                    Task { @MainActor in filmProgress = publish ? f * 0.5 : f }
                }
                if publish {
                    filmStatus = "Publication…"
                    await publishRaidFilm(localURL: url)
                    try? FileManager.default.removeItem(at: url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// Upload le film de raid sur Bunny Storage + une page wrapper `<video>`, puis ouvre/copie l'URL publique.
    private func publishRaidFilm(localURL: URL) async {
        guard let data = try? Data(contentsOf: localURL) else { exportError = "Vidéo introuvable après le rendu."; return }
        let folder = "films/raid-\(raid.id.uuidString.lowercased())"
        let html = Self.videoPageHTML(title: raid.name, dateText: dateRangeText ?? "")
        let files: [String: Data] = ["film.mp4": data, "index.html": Data(html.utf8)]
        do {
            try await BunnyStorageService.publish(files: files, folder: folder) { f, s in
                Task { @MainActor in filmProgress = 0.5 + f * 0.5; filmStatus = s }
            }
            let urlStr = "https://www.gpxmanagement.net/\(folder)/"
            try? await repository.setRaidFilmPublished(id: raid.id, url: urlStr)
            filmPublishedURL = urlStr
            if let u = URL(string: urlStr) {
                NSWorkspace.shared.open(u)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlStr, forType: .string)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Page HTML minimale hébergeant le film de raid (lecteur natif).
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
          <header><h1>\(safe)</h1><div class="date">\(dateText)</div></header>
          <main><video src="film.mp4" controls playsinline preload="metadata"></video></main>
          <footer>GPXManagement</footer>
        </body></html>
        """
    }

    private func exportGroupedGPX() {
        let panel = NSOpenPanel()
        panel.title = "Choisir un dossier d'export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exporter ici"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let memberList = members
        let folderName = raid.name.replacingOccurrences(of: "/", with: "-")
        Task {
            isExportingFilm = true
            filmProgress = 0
            filmStatus = "Export des GPX…"
            defer { isExportingFilm = false; filmStatus = "" }

            let target = dir.appendingPathComponent(folderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var done = 0
            for member in memberList {
                if let data = try? await repository.fetchTrackData(id: member.id), !data.isEmpty,
                   let points = try? TrackPointCodec.decode(data),
                   let gpx = try? GPXWriter.write(name: member.title, activityType: member.activityType, points: points) {
                    let safe = member.title.replacingOccurrences(of: "/", with: "-")
                    try? gpx.write(to: uniqueURL(in: target, name: safe, ext: "gpx"), options: .atomic)
                }
                done += 1
                filmProgress = Double(done) / Double(max(1, memberList.count))
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    private func loadStageLayouts() async {
        var dict: [UUID: VideoLayout] = [:]
        for member in members {
            if let data = try? await repository.fetchVideoLayoutData(id: member.id),
               let layout = try? JSONDecoder().decode(VideoLayout.self, from: data) {
                dict[member.id] = layout
            }
        }
        stageLayouts = dict
    }

    private func editLayout(for member: ActivitySummary) {
        editingLayout = layoutFor(member.id)
        editingTracePoints = []
        editingTemplateID = allTemplates.first(where: { $0.layout == editingLayout })?.id
        editingLayoutStageId = member.id
        Task { editingTracePoints = await tracePreviewPoints(for: member.id) }
    }

    private func saveEditingLayout() {
        guard let id = editingLayoutStageId else { return }
        stageLayouts[id] = editingLayout
        let data = try? JSONEncoder().encode(editingLayout)
        Task { try? await repository.updateVideoLayoutData(id: id, data: data) }
        editingLayoutStageId = nil
    }

    // MARK: Modèles de disposition (partagés avec le film d'activité)

    private var userTemplates: [VideoTemplate] {
        guard let d = userTemplatesJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([VideoTemplate].self, from: d) else { return [] }
        return arr
    }
    private func setUserTemplates(_ arr: [VideoTemplate]) {
        if let d = try? JSONEncoder().encode(arr), let s = String(data: d, encoding: .utf8) { userTemplatesJSON = s }
    }
    private var allTemplates: [VideoTemplate] { VideoTemplate.builtins + userTemplates }
    private var selectedEditorTemplate: VideoTemplate? { allTemplates.first { $0.id == editingTemplateID } }
    private var editorMatchesTemplate: Bool {
        guard let t = selectedEditorTemplate else { return false }
        return t.layout == editingLayout
    }
    private func applyTemplateToEditor(_ t: VideoTemplate) {
        editingLayout = t.layout
        editingTemplateID = t.id
    }
    private func templateFromEditor(id: String, name: String) -> VideoTemplate {
        VideoTemplate(id: id, name: name,
                      quality: VideoQuality(rawValue: raidVideoQualityRaw) ?? .hd720,
                      format: filmFormat, layout: editingLayout, builtin: false,
                      transition: MediaTransition(rawValue: raidVideoTransitionRaw) ?? .fade,
                      showHeartRate: raidVideoHeartRateOn, showIntro: true, showOutro: true,
                      mapLayerRaw: raidVideoMapLayerRaw)
    }
    private func saveLayoutAsNewTemplate(name: String) {
        let t = templateFromEditor(id: "user.\(UUID().uuidString)", name: name)
        setUserTemplates(userTemplates + [t])
        editingTemplateID = t.id
    }
    private func updateSelectedTemplate() {
        guard let id = editingTemplateID, var t = userTemplates.first(where: { $0.id == id }), !t.builtin else { return }
        t.layout = editingLayout
        setUserTemplates(userTemplates.map { $0.id == t.id ? t : $0 })
    }
    private func renameSelectedTemplate(_ name: String) {
        guard var t = selectedEditorTemplate, !t.builtin else { return }
        t.name = name
        setUserTemplates(userTemplates.map { $0.id == t.id ? t : $0 })
    }
    private func deleteSelectedTemplate() {
        guard let t = selectedEditorTemplate, !t.builtin else { return }
        setUserTemplates(userTemplates.filter { $0.id != t.id })
        editingTemplateID = nil
    }

    private func tracePreviewPoints(for id: UUID) async -> [CGPoint] {
        guard let data = try? await repository.fetchTrackData(id: id), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data), points.count > 1 else { return [] }
        let mps = points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let minX = mps.map(\.x).min() ?? 0, maxX = mps.map(\.x).max() ?? 1
        let minY = mps.map(\.y).min() ?? 0, maxY = mps.map(\.y).max() ?? 1
        let scale = Swift.max(1, Swift.max(maxX - minX, maxY - minY))
        let step = Swift.max(1, mps.count / 400)
        return stride(from: 0, to: mps.count, by: step).map { i in
            CGPoint(x: (mps[i].x - minX) / scale, y: (mps[i].y - minY) / scale)
        }
    }

    private func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) (\(i)).\(ext)")
            i += 1
        }
        return candidate
    }

    private func save() {
        guard isDirty else { return }
        persist()
    }

    private func persist() {
        let snapshot = draft
        Task { await listVM.saveRaid(snapshot) }
    }

    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat = 0.8) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private var trackColorMode: TrackColorMode { TrackColorMode(rawValue: trackColorModeRaw) ?? .uniform }

    private func loadMap() async {
        isLoadingMap = true
        var loaded: [TrackOverlayInput] = []
        for activity in members {
            if let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
               let overlay = try? TrackOverlayInput.fromTrackData(data, activityId: activity.id, activityType: activity.activityType, colorMode: trackColorMode),
               !overlay.coordinates.isEmpty {
                loaded.append(overlay)
            }
        }
        tracks = loaded
        isLoadingMap = false
    }

    // MARK: Formatage

    private var dateRangeText: String? {
        guard let start = raid.startDate else { return nil }
        let end = raid.endDate ?? start
        let cal = Calendar.current
        if cal.isDate(start, inSameDayAs: end) {
            return Self.dayFormatter.string(from: start)
        }
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0) + 1
        return "\(Self.dayFormatter.string(from: start)) → \(Self.dayFormatter.string(from: end)) · \(days) jours"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m))" }
        return "\(m) min"
    }
}

struct RaidLayoutThumbnail: View {
    let layout: VideoLayout
    let aspect: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.18))
                zone(layout.trace, in: geo.size, color: .blue)
                if let profile = layout.profile {
                    zone(profile, in: geo.size, color: .teal)
                }
                zone(layout.media, in: geo.size, color: .orange)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func zone(_ z: LayoutZone, in size: CGSize, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: 1.2))
            .frame(width: max(1, z.w * size.width), height: max(1, z.h * size.height))
            .offset(x: z.x * size.width, y: z.y * size.height)
    }
}

struct ParticipantAvatar: View {
    let participant: RaidParticipant
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let data = participant.avatarImageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.accentColor.opacity(0.25)
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = participant.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

struct RaidParticipantEditor: View {
    @State private var participant: RaidParticipant
    let onSave: (RaidParticipant) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var avatarItem: PhotosPickerItem?

    init(participant: RaidParticipant, onSave: @escaping (RaidParticipant) -> Void, onDelete: (() -> Void)?) {
        _participant = State(initialValue: participant)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onDelete == nil ? "Nouveau participant" : "Modifier le participant")
                .font(.headline)

            HStack(spacing: 16) {
                ParticipantAvatar(participant: participant, size: 72)
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(participant.avatarImageData == nil ? "Choisir une photo…" : "Changer la photo…",
                                 selection: $avatarItem, matching: .images)
                    if participant.avatarImageData != nil {
                        Button("Retirer la photo", role: .destructive) { participant.avatarImageData = nil }
                            .buttonStyle(.link)
                    }
                }
            }

            TextField("Nom", text: $participant.name)
                .textFieldStyle(.roundedBorder)

            HStack {
                if onDelete != nil {
                    Button("Supprimer", role: .destructive) {
                        onDelete?()
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") {
                    onSave(participant)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(participant.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let resized = RaidDetailView.downscaledJPEG(data, maxDimension: 256) {
                    participant.avatarImageData = resized
                }
                avatarItem = nil
            }
        }
    }
}
