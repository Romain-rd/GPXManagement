import SwiftUI
import GPXCore

struct ContentView: View {
    @Bindable var services: AppServices
    @State private var window: WindowModel

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

    /// Activités ciblées par le mode courant : la sélection si elle existe, sinon tout l'ensemble filtré.
    private var targetActivities: [ActivitySummary] {
        if navigation.listSelection.isEmpty {
            return listVM.visibleActivities
        }
        return listVM.visibleActivities.filter { navigation.listSelection.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(navigation: navigation, listVM: listVM)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            ActivityListView(listVM: listVM, navigation: navigation, services: services)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            modeContent
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Un seul item (pas de fond glass autour de l'indicateur) ;
                // écart fixe pour ne pas coller l'indicateur au sélecteur de mode.
                HStack(spacing: 0) {
                    Picker("Mode", selection: Binding(
                        get: { navigation.visualizationMode },
                        set: { navigation.visualizationMode = $0 }
                    )) {
                        ForEach(VisualizationMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if window.isExportingMap {
                        Color.clear.frame(width: 28)
                        ProgressView(value: window.mapExportFraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .help("Export de la carte — \(window.mapExportStatus)")
                    }
                }
            }
        }
        .focusedSceneValue(\.windowModel, window)
        .task {
            await listVM.reload()
        }
        .onChange(of: services.importedCount) { _, _ in
            Task { await listVM.reload() }
        }
        .onChange(of: services.libraryRevision) { _, _ in
            Task { await listVM.reload() }
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

    @ViewBuilder
    private var modeContent: some View {
        switch navigation.visualizationMode {
        case .activities:
            activitiesDetail
        case .statistics:
            StatisticsView(activities: targetActivities)
        case .mapOverview:
            if let repository {
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
        if let selectedId = navigation.listSelection.first,
           let activity = listVM.visibleActivities.first(where: { $0.id == selectedId }),
           let repository {
            ActivityDetailView(activity: activity, listVM: listVM, repository: repository)
        } else {
            ContentUnavailableView(
                "Aucune activité sélectionnée",
                systemImage: "tray",
                description: Text("Choisissez une activité dans la liste.")
            )
        }
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

struct MapOverviewPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Carte d'ensemble",
            systemImage: "map",
            description: Text("Sélectionnez des activités pour les afficher.")
        )
    }
}
