import SwiftUI
import GPXCore

struct ContentView: View {
    @Bindable var services: AppServices = .shared
    @State private var navigation = AppNavigationModel()
    @State private var listVM: ActivityListViewModel

    init(services: AppServices = .shared) {
        self._services = Bindable(wrappedValue: services)
        let repo = services.repository as! CoreDataActivityRepository
        self._listVM = State(initialValue: ActivityListViewModel(repository: repo))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(navigation: navigation, listVM: listVM)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            detail
        }
        .task {
            await listVM.reload()
        }
        .onChange(of: services.importedCount) { _, _ in
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
    private var content: some View {
        switch navigation.mode {
        case .threeColumn:
            ActivityListView(listVM: listVM, navigation: navigation, services: services)
        case .mapOverview:
            if let repo = services.repository as? CoreDataActivityRepository {
                MapOverviewView(
                    activities: listVM.visibleActivities,
                    selectedIds: navigation.listSelection,
                    repository: repo,
                    onSelect: { id in
                        navigation.listSelection = [id]
                        navigation.mode = .threeColumn
                    }
                )
            } else {
                MapOverviewPlaceholder()
            }
        case .statistics:
            StatisticsView(activities: listVM.allActivities)
        case .strava:
            StravaPlaceholder()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if navigation.mode == .threeColumn,
           let selectedId = navigation.listSelection.first,
           let activity = listVM.visibleActivities.first(where: { $0.id == selectedId }),
           let repo = services.repository as? CoreDataActivityRepository {
            ActivityDetailView(activity: activity, listVM: listVM, repository: repo)
        } else if navigation.mode == .threeColumn {
            ContentUnavailableView("Aucune activité sélectionnée", systemImage: "tray", description: Text("Choisissez une activité dans la liste."))
        } else {
            EmptyView()
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
            description: Text("Disponible en P6 (MapKit + tuiles IGN).")
        )
    }
}

struct StatsOverviewPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Statistiques",
            systemImage: "chart.bar.xaxis",
            description: Text("Disponible en P8 (vues agrégées Swift Charts).")
        )
    }
}

struct StravaPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Strava",
            systemImage: "arrow.triangle.2.circlepath",
            description: Text("Connexion et synchronisation prévues en P8.")
        )
    }
}
