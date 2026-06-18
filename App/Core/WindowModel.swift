import SwiftUI
import GPXCore
import GPXRender
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
    /// Carte du détail/vue d'ensemble en plein écran (barre de titre transparente, pastilles conservées).
    var mapFullscreen: Bool = false
    /// Carte d'un raid en plein écran : overlay couvrant la fenêtre (la carte du raid est dans la colonne du milieu).
    var fullscreenRaidId: UUID? = nil
    /// Une carte est en mode immersif (détail/overview ou raid).
    var isMapImmersive: Bool { mapFullscreen || fullscreenRaidId != nil }

    private let repository: CoreDataActivityRepository

    init(repository: CoreDataActivityRepository) {
        self.repository = repository
        self.listVM = ActivityListViewModel(repository: repository)
    }

    var hasSelection: Bool { !navigation.listSelection.isEmpty }
    var canExportMap: Bool { navigation.visualizationMode == .mapOverview }
    var canMerge: Bool { selectedSummaries.count >= 2 && canEditTrack }

    /// Libellé de duplication selon le type sélectionné (activité / parcours / raid).
    var duplicateLabel: String {
        if navigation.isRaidsScope { return "Dupliquer le raid" }
        if navigation.isCoursesScope { return "Dupliquer le parcours" }
        return "Dupliquer l'activité"
    }
    /// Simplifier, nettoyer, fusionner : activités seulement.
    var canEditTrack: Bool { hasSelection && !navigation.isRaidsScope && !navigation.isCoursesScope }
    /// Scinder (découper) et inverser : activités ET parcours (pas les raids) — pour un parcours, supprime les étapes.
    var canSplitReverse: Bool { hasSelection && !navigation.isRaidsScope }

    var selectedSummaries: [ActivitySummary] {
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

    // Actions dont la logique vit dans la fiche détail (sheets/partage) : on déclenche via un token
    // que la fiche de l'activité sélectionnée observe — même mécanisme que l'export carte.
    var repairToken: Int = 0
    var webExportToken: Int = 0
    var videoToken: Int = 0
    var shareToken: Int = 0
    var elevationToken: Int = 0
    var splitToken: Int = 0
    var simplifyToken: Int = 0
    var cleanToken: Int = 0
    var mergeToken: Int = 0
    var reverseToken: Int = 0
    var duplicateToken: Int = 0

    func requestRepair() { guard hasSelection else { return }; repairToken += 1 }
    func requestGenerateElevation() { guard hasSelection else { return }; elevationToken += 1 }
    func requestSplit() { guard hasSelection else { return }; splitToken += 1 }
    func requestReverse() { guard hasSelection else { return }; reverseToken += 1 }
    func requestDuplicate() { guard hasSelection else { return }; duplicateToken += 1 }
    func requestSimplify() { guard hasSelection else { return }; simplifyToken += 1 }
    func requestClean() { guard hasSelection else { return }; cleanToken += 1 }
    func requestMerge() { guard canMerge else { return }; mergeToken += 1 }
    func requestWebExport() { guard hasSelection else { return }; webExportToken += 1 }
    func requestVideo() { guard hasSelection else { return }; videoToken += 1 }
    func requestShare() { guard hasSelection else { return }; shareToken += 1 }

    func requestNewRaid() {
        guard hasSelection else { return }
        navigation.newRaidToken += 1
    }

    func requestNewStagedRoute() {
        guard hasSelection else { return }
        navigation.newStagedRouteToken += 1
    }
}

/// Progression d'un export/publication web, affichée dans la barre d'outils (façon Photos).
@MainActor
@Observable
final class WebExportProgress {
    static let shared = WebExportProgress()
    var isActive = false
    var fraction: Double = 0
    var status = ""

    func begin(_ status: String) { isActive = true; fraction = 0; self.status = status }
    func update(_ fraction: Double, _ status: String) { self.fraction = fraction; self.status = status }
    func end() { isActive = false; fraction = 0; status = "" }
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
