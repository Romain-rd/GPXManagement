import Foundation
import GPXCore

@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let persistence: PersistenceController
    let iCloudContainer: ICloudContainer
    let storage: FileStorageService
    let repository: ActivityRepository
    let importer: ImportService

    var pendingImports: [ImportProposal] = []
    var importError: String?

    private init() {
        self.persistence = PersistenceController.shared
        self.iCloudContainer = ICloudContainer(identifier: AppConfig.iCloudContainerIdentifier)
        self.storage = FileStorageService(container: iCloudContainer, pattern: .default)
        self.repository = CoreDataActivityRepository(persistence: persistence)
        self.importer = ImportService(storage: storage, repository: repository)
    }

    func prepareImports(from urls: [URL]) async {
        importError = nil
        var proposals: [ImportProposal] = []
        for url in urls {
            do {
                let proposal = try await importer.prepareImport(from: url)
                proposals.append(proposal)
            } catch {
                NSLog("GPXManagement: prepareImport failed for \(url.lastPathComponent): \(error)")
                importError = "Échec de l'import de \(url.lastPathComponent) : \(error.localizedDescription)"
            }
        }
        pendingImports = proposals
    }

    func confirmImport(_ proposal: ImportProposal, activityType: ActivityType, title: String) async {
        do {
            _ = try await importer.confirmImport(proposal, activityType: activityType, title: title)
            pendingImports.removeAll { $0.sourceURL == proposal.sourceURL }
        } catch {
            NSLog("GPXManagement: confirmImport failed: \(error)")
            importError = "Échec de la confirmation : \(error.localizedDescription)"
        }
    }

    func cancelImport(_ proposal: ImportProposal) {
        pendingImports.removeAll { $0.sourceURL == proposal.sourceURL }
    }

    func cancelAllImports() {
        pendingImports.removeAll()
    }
}
