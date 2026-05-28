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
    let healthImporter: AppleHealthImporter

    var pendingImports: [ImportProposal] = []
    var importError: String?
    var importedCount: Int = 0
    var isScanningHealthExport: Bool = false
    var healthScanProgress: String?

    private init() {
        self.persistence = PersistenceController.shared
        self.iCloudContainer = ICloudContainer(identifier: AppConfig.iCloudContainerIdentifier)
        self.storage = FileStorageService(container: iCloudContainer, pattern: .default)
        self.repository = CoreDataActivityRepository(persistence: persistence)
        self.importer = ImportService(storage: storage, repository: repository)
        self.healthImporter = AppleHealthImporter()
    }

    func importAppleHealthExport(rootURL: URL) async {
        isScanningHealthExport = true
        defer {
            isScanningHealthExport = false
            healthScanProgress = nil
        }
        importError = nil

        let workouts: [AppleHealthWorkout]
        do {
            workouts = try await healthImporter.scan(exportRoot: rootURL)
        } catch {
            importError = "Échec du scan Apple Santé : \(error.localizedDescription)"
            return
        }

        let geoWorkouts = workouts.filter { $0.gpxFileURL != nil }
        if geoWorkouts.isEmpty {
            importError = "Aucun workout avec données GPS trouvé dans l'export (\(workouts.count) workout(s) scanné(s))."
            return
        }

        var proposals: [ImportProposal] = []
        var failures = 0
        for (idx, workout) in geoWorkouts.enumerated() {
            healthScanProgress = "Analyse \(idx + 1)/\(geoWorkouts.count)…"
            guard let gpxURL = workout.gpxFileURL else { continue }
            do {
                let proposal = try await importer.prepareImport(
                    from: gpxURL,
                    hintedActivityType: workout.suggestedActivityType,
                    hintedTitle: workout.suggestedTitle
                )
                proposals.append(proposal)
            } catch {
                failures += 1
                NSLog("GPXManagement: failed to prepare \(gpxURL.lastPathComponent): \(error)")
            }
        }

        pendingImports = proposals
        if failures > 0 {
            importError = "\(failures) workout(s) n'ont pas pu être préparé(s)."
        }
    }

    func confirmAllPendingImports(defaultActivityType: ActivityType) async {
        let snapshot = pendingImports
        for proposal in snapshot {
            let type = proposal.suggestedActivityType ?? defaultActivityType
            do {
                _ = try await importer.confirmImport(proposal, activityType: type, title: proposal.suggestedTitle)
                pendingImports.removeAll { $0.sourceURL == proposal.sourceURL }
                importedCount += 1
            } catch {
                NSLog("GPXManagement: confirmAllPendingImports failed: \(error)")
                importError = "Échec d'un import en lot : \(error.localizedDescription)"
                return
            }
        }
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
            importedCount += 1
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
