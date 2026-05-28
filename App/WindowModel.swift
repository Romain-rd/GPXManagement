import SwiftUI
import GPXCore

@MainActor
@Observable
final class WindowModel {
    let navigation = AppNavigationModel()
    let listVM: ActivityListViewModel
    var mapExportToken: Int = 0
    var mapExportFullRoute: Bool = false
    var isExportingMap: Bool = false
    var mapExportFraction: Double = 0
    var mapExportStatus: String = ""

    private let repository: CoreDataActivityRepository

    init(repository: CoreDataActivityRepository) {
        self.repository = repository
        self.listVM = ActivityListViewModel(repository: repository)
    }

    var hasSelection: Bool { !navigation.listSelection.isEmpty }
    var canExportMap: Bool { navigation.visualizationMode == .mapOverview }

    private var selectedSummaries: [ActivitySummary] {
        listVM.visibleActivities.filter { navigation.listSelection.contains($0.id) }
    }

    func exportSelectedActivityGPX() {
        guard let activity = selectedSummaries.first else { return }
        Task {
            do {
                _ = try await ExportService.exportGPX(activity: activity, repository: repository)
            } catch ExportError.userCancelled {
            } catch {
                listVM.error = error.localizedDescription
            }
        }
    }

    func renameSelectedFromRoute() {
        let ids = navigation.listSelection
        Task { for id in ids { await listVM.autoRename(id: id) } }
    }

    func changeTypeOfSelection(_ type: ActivityType) {
        let ids = navigation.listSelection
        Task { await listVM.updateType(ids: ids, type: type) }
    }

    func deleteSelection() {
        let ids = navigation.listSelection
        Task {
            for id in ids { await listVM.delete(id: id) }
            navigation.listSelection = []
        }
    }

    func requestMapExport(fullRoute: Bool) {
        mapExportFullRoute = fullRoute
        mapExportToken += 1
    }
}

private struct WindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}
