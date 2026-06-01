import SwiftUI
import GPXCore
import GPXMapKit

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
    var isExportingPDF: Bool = false
    var exportError: String?

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

    func exportSelectedActivityPDF() {
        guard let activity = selectedSummaries.first else { return }
        let layerRaw = UserDefaults.standard.string(forKey: "defaultMapLayer")
        let layer = layerRaw.flatMap { MapLayer(rawValue: $0) } ?? .ignScan25
        isExportingPDF = true
        Task {
            defer { isExportingPDF = false }
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

    func requestNewRaid() {
        guard hasSelection else { return }
        navigation.newRaidToken += 1
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
