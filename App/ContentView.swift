import SwiftUI
import GPXCore

struct ContentView: View {
    @Bindable var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var window: WindowModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var mergeCandidates: [ActivitySummary] = []
    @State private var showMergeSheet = false
    private let webProgress = WebExportProgress.shared

    init(services: AppServices = .shared) {
        self._services = Bindable(wrappedValue: services)
        let repo = (services.repository as? CoreDataActivityRepository) ?? CoreDataActivityRepository(persistence: services.persistence)
        self._window = State(initialValue: WindowModel(repository: repo))
    }

    private var navigation: AppNavigationModel { window.navigation }
    private var listVM: ActivityListViewModel { window.listVM }

    private var repository: CoreDataActivityRepository? {
        services.repository as? CoreDataActivityRepository
    }

    private var raidMembers: [ActivitySummary] {
        guard let id = navigation.selectedRaidId else { return [] }
        return listVM.allActivities.filter { $0.raidId == id }.sorted { $0.startDate < $1.startDate }
    }

    /// Activités ciblées par le mode courant : la sélection si elle existe, sinon l'ensemble
    /// courant (étapes du raid sélectionné, sinon toutes les activités filtrées).
    private var baseActivities: [ActivitySummary] {
        navigation.selectedRaidId != nil ? raidMembers : listVM.visibleActivities
    }

    private var targetActivities: [ActivitySummary] {
        if navigation.listSelection.isEmpty { return baseActivities }
        return baseActivities.filter { navigation.listSelection.contains($0.id) }
    }

    private var splitView: some View {
        // En plein écran carte on force le repli sidebar + liste (la carte occupe tout) ; sinon visibilité normale.
        NavigationSplitView(columnVisibility: Binding(
            get: { window.mapFullscreen ? .detailOnly : columnVisibility },
            set: { columnVisibility = $0 }
        )) {
            SidebarView(navigation: navigation, listVM: listVM)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            if let raidId = navigation.selectedRaidId,
               let raid = listVM.raids.first(where: { $0.id == raidId }),
               let repository {
                RaidDetailView(raid: raid, listVM: listVM, repository: repository, navigation: navigation, window: window)
                    .id(raid.id)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400)
            } else if let routeId = navigation.selectedStagedRouteId,
                      let route = listVM.allActivities.first(where: { $0.id == routeId }),
                      let repository {
                ParcoursDetailView(activity: route, listVM: listVM, repository: repository, navigation: navigation)
                    .id(route.id)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 440)
            } else {
                ActivityListView(listVM: listVM, navigation: navigation, services: services, searchDisabled: window.mapFullscreen)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            }
        } detail: {
            modeContent
        }
        .toolbar {
            if !window.isMapImmersive {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: Binding(
                        get: { navigation.visualizationMode },
                        set: { navigation.visualizationMode = $0 }
                    )) {
                        ForEach(VisualizationMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                // En plein écran : bouton de sortie en haut-droite, dans la toolbar (au-dessus de la carte
                // → reçoit le clic, contrairement à un overlay dessiné sous la barre transparente).
                ToolbarItem(placement: .automatic) {
                    Button { window.mapFullscreen = false; window.fullscreenRaidId = nil } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Quitter le plein écran (Échap)")
                    .keyboardShortcut(.cancelAction)
                }
            }
            if window.isExportingMap {
                exportToolbarItem
            }
            if webProgress.isActive {
                ToolbarItem(placement: .automatic) {
                    ExportProgressLabel(fraction: webProgress.fraction, status: webProgress.status, title: "Publication web")
                }
            }
        }
        // Plein écran carte façon Plan.app : barre de titre transparente (pastilles flottantes conservées) ;
        // titre vidé + recherche retirée côté vues, contrôles décalés sous la barre d'outils (qui reste présente).
        .toolbarBackground(window.isMapImmersive ? .hidden : .automatic, for: .windowToolbar)
    }

    var body: some View {
        splitView
        // Carte d'un raid en plein écran : overlay couvrant toute la fenêtre (réutilise la vue d'ensemble).
        .overlay { raidFullscreenOverlay }
        .focusedSceneValue(\.windowModel, window)
        .task {
            await listVM.reload()
            await listVM.classifyCoursesIfNeeded()
            syncActiveSmartFilter()
            await services.scanWatchedFolderIfConfigured()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await services.scanWatchedFolderIfConfigured() }
            }
        }
        .onChange(of: navigation.sidebarSelection) { _, _ in
            navigation.listSelection = []
            navigation.selectedStageId = nil // sinon la fiche d'étape de l'ancien parcours resterait affichée
            syncActiveSmartFilter()
        }
        .sheet(item: editingSmartFilterBinding) { filter in
            SmartFilterEditor(filter: filter, listVM: listVM, onSave: { updated in
                Task {
                    await listVM.saveSmartFilter(updated)
                    navigation.editingSmartFilter = nil
                    navigation.sidebarSelection = .smartFilter(updated.id)
                }
            }, onCancel: { navigation.editingSmartFilter = nil })
        }
        .onChange(of: services.importedCount) { _, _ in
            Task { await listVM.reload() }
        }
        .onChange(of: services.libraryRevision) { _, _ in
            Task { await listVM.reload() }
        }
        .onChange(of: window.mergeToken) { _, _ in
            mergeCandidates = window.selectedSummaries
            showMergeSheet = true
        }
        .sheet(isPresented: $showMergeSheet) {
            if let repository {
                MergeTracksSheet(activities: mergeCandidates, repository: repository)
            }
        }
        .sheet(isPresented: hasPendingImportsBinding) {
            ImportSheetView(services: services)
        }
        .alert("Erreur", isPresented: hasErrorBinding) {
            Button("OK") { services.importError = nil }
        } message: {
            Text(services.importError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var exportToolbarItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) {
                ExportProgressLabel(fraction: window.mapExportFraction, status: window.mapExportStatus)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) {
                ExportProgressLabel(fraction: window.mapExportFraction, status: window.mapExportStatus)
            }
        }
    }

    /// Overlay plein écran de la carte d'un raid : réutilise la vue d'ensemble sur les étapes du raid.
    @ViewBuilder
    private var raidFullscreenOverlay: some View {
        if window.fullscreenRaidId != nil, let repository {
            MapOverviewView(
                activities: raidMembers,
                selectedIds: [],
                repository: repository,
                window: window,
                onSelect: { id in
                    navigation.listSelection = [id]
                    navigation.visualizationMode = .activities
                    window.fullscreenRaidId = nil
                },
                forceFullscreen: true
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch navigation.visualizationMode {
        case .activities:
            activitiesDetail
        case .statistics:
            StatisticsView(
                activities: targetActivities,
                annualActivities: baseActivities,
                selectionActive: !navigation.listSelection.isEmpty,
                onOpenActivity: { id in
                    navigation.listSelection = [id]
                    navigation.visualizationMode = .activities
                }
            )
        case .mapOverview:
            if let routeId = navigation.selectedStagedRouteId,
               let route = listVM.allActivities.first(where: { $0.id == routeId }),
               let repository {
                StagedRouteOverviewMap(activity: route, repository: repository)
            } else if let repository {
                MapOverviewView(
                    activities: targetActivities,
                    selectedIds: [],
                    repository: repository,
                    window: window,
                    onSelect: { id in
                        navigation.listSelection = [id]
                        navigation.visualizationMode = .activities
                    }
                )
            } else {
                MapOverviewPlaceholder()
            }
        }
    }

    @ViewBuilder
    private var activitiesDetail: some View {
        if let routeId = navigation.selectedStagedRouteId,
           let route = listVM.allActivities.first(where: { $0.id == routeId }),
           let repository {
            if let stageId = navigation.selectedStageId {
                StageDetailView(activity: route, stageId: stageId, repository: repository).id(stageId)
            } else {
                ContentUnavailableView("Sélectionnez une étape", systemImage: "flag.checkered",
                                       description: Text("Choisissez une étape à gauche pour voir sa fiche."))
            }
        } else if let selectedId = navigation.listSelection.first,
           let activity = listVM.allActivities.first(where: { $0.id == selectedId }),
           let repository {
            ActivityDetailView(activity: activity, listVM: listVM, repository: repository, windowModel: window, navigation: navigation, fullscreenMap: $window.mapFullscreen)
        } else if navigation.selectedRaidId != nil {
            ContentUnavailableView(
                "Sélectionnez une étape",
                systemImage: "flag.2.crossed",
                description: Text("Choisissez une étape du raid à gauche pour voir son détail. L'aperçu du raid reste affiché.")
            )
        } else {
            ContentUnavailableView(
                "Aucune activité sélectionnée",
                systemImage: "tray",
                description: Text("Choisissez une activité dans la liste.")
            )
        }
    }

    private func syncActiveSmartFilter() {
        listVM.activeSmartFilter = navigation.selectedSmartFilterId.flatMap { id in
            listVM.smartFilters.first { $0.id == id }
        }
        listVM.activeType = navigation.selectedActivityType
        listVM.activeYear = navigation.selectedYear
        listVM.scope = navigation.sidebarSelection == .allCourses ? .courses : .activities
    }

    private var editingSmartFilterBinding: Binding<SmartFilter?> {
        Binding(
            get: { navigation.editingSmartFilter },
            set: { navigation.editingSmartFilter = $0 }
        )
    }

    private var hasPendingImportsBinding: Binding<Bool> {
        Binding(
            get: { !services.pendingImports.isEmpty },
            set: { if !$0 { services.cancelAllImports() } }
        )
    }

    private var hasErrorBinding: Binding<Bool> {
        Binding(
            get: { services.importError != nil },
            set: { if !$0 { services.importError = nil } }
        )
    }
}

struct ExportProgressLabel: View {
    let fraction: Double
    let status: String
    var title: String = "Export de la carte"

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("\(Int((fraction * 100).rounded())) %")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(title) — \(status)")
    }
}

struct MapOverviewPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Carte d'ensemble",
            systemImage: "map",
            description: Text("Sélectionnez des activités pour les afficher.")
        )
    }
}