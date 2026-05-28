import Foundation
import AppKit
import UniformTypeIdentifiers
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
    let stravaImporter: StravaArchiveImporter

    var pendingImports: [ImportProposal] = []
    var importError: String?
    var importedCount: Int = 0
    var isScanningHealthExport: Bool = false
    var healthScanProgress: String?
    var isScanningWatchedFolder: Bool = false
    var watchedFolderProgress: String?
    var lastWatchedFolderSummary: String?
    var isRenamingAll: Bool = false
    var renameAllProgress: String?
    var lastMaintenanceSummary: String?
    var libraryRevision: Int = 0

    private init() {
        self.persistence = PersistenceController.shared
        self.iCloudContainer = ICloudContainer(identifier: AppConfig.iCloudContainerIdentifier)
        self.storage = FileStorageService(container: iCloudContainer, pattern: .default)
        let repo = CoreDataActivityRepository(persistence: persistence)
        self.repository = repo
        self.importer = ImportService(storage: storage, repository: repo)
        self.healthImporter = AppleHealthImporter()
        self.stravaImporter = StravaArchiveImporter()
    }

    var coreDataRepository: CoreDataActivityRepository? {
        repository as? CoreDataActivityRepository
    }

    // MARK: - Imports (barre de menus)

    func importFilesViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "gpx") ?? .xml,
            UTType(filenameExtension: "fit") ?? .data
        ]
        panel.title = "Choisir des fichiers GPX ou FIT"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await prepareImports(from: urls) }
    }

    func importWatchedFolderViaPanel() {
        if let saved = WatchedFolderBookmark.resolve() {
            Task { await scanWatchedFolder(saved) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choisir un dossier à surveiller"
        panel.message = "Sélectionnez le dossier iCloud où HealthFit (ou un autre service) dépose vos fichiers GPX/FIT."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        try? WatchedFolderBookmark.save(url: folder)
        Task { await scanWatchedFolder(folder) }
    }

    func importAppleHealthViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choisir le dossier d'export Apple Santé"
        panel.message = "Sélectionnez le dossier qui contient export.xml (et workout-routes/)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await importAppleHealthExport(rootURL: folder) }
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

    func importStravaViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.title = "Choisir l'export Strava (ZIP ou dossier)"
        panel.message = "Sélectionnez le .zip téléchargé depuis Strava, ou le dossier déjà décompressé."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importStravaArchive(at: url, fallbackType: .cyclingRoad) }
    }

    func importStravaArchive(at url: URL, fallbackType: ActivityType) async {
        isScanningWatchedFolder = true
        defer {
            isScanningWatchedFolder = false
            watchedFolderProgress = nil
        }
        importError = nil
        lastWatchedFolderSummary = nil

        let result: StravaArchiveResult
        do {
            watchedFolderProgress = "Lecture de l'export…"
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            result = isDir
                ? try await stravaImporter.extract(folderURL: url)
                : try await stravaImporter.extract(zipURL: url)
        } catch {
            importError = "Échec de la lecture de l'export Strava : \(error.localizedDescription)"
            return
        }

        if result.extractedFiles.isEmpty {
            var parts = ["Aucune trace GPX/FIT trouvée dans activities/."]
            if result.unsupportedCount > 0 {
                parts.append("\(result.unsupportedCount) fichier(s) .tcx ignoré(s) (format non supporté).")
            }
            importError = parts.joined(separator: " ")
            return
        }

        var imported = 0
        var duplicates = 0
        var fallbackUsed = 0
        var failures = result.failedCount
        let files = result.extractedFiles
        for (idx, fileURL) in files.enumerated() {
            watchedFolderProgress = "Import \(idx + 1)/\(files.count)…"
            do {
                let proposal = try await importer.prepareImport(
                    from: fileURL,
                    hintedActivityType: nil,
                    hintedTitle: nil,
                    origin: .strava
                )
                if proposal.duplicateOfActivityId != nil {
                    duplicates += 1
                    continue
                }
                let type = proposal.suggestedActivityType ?? fallbackType
                if proposal.suggestedActivityType == nil { fallbackUsed += 1 }
                _ = try await importer.confirmImport(proposal, activityType: type, title: proposal.suggestedTitle)
                imported += 1
                if imported % 25 == 0 {
                    importedCount += 1
                    libraryRevision += 1
                }
            } catch {
                failures += 1
                NSLog("GPXManagement: Strava import failed for \(fileURL.lastPathComponent): \(error)")
            }
        }

        try? FileManager.default.removeItem(at: result.workingDirectory)
        importedCount += 1
        libraryRevision += 1

        var parts: [String] = ["\(imported) importée(s)"]
        if duplicates > 0 { parts.append("\(duplicates) déjà présente(s)") }
        if fallbackUsed > 0 { parts.append("\(fallbackUsed) type indéterminé → \(fallbackType.displayName)") }
        if result.unsupportedCount > 0 { parts.append("\(result.unsupportedCount) .tcx ignorée(s)") }
        if failures > 0 { parts.append("\(failures) échec(s)") }
        lastWatchedFolderSummary = parts.joined(separator: " · ")
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

    func renameAllActivitiesFromRoute() async {
        guard let repo = repository as? CoreDataActivityRepository else { return }
        isRenamingAll = true
        lastMaintenanceSummary = nil
        defer {
            isRenamingAll = false
            renameAllProgress = nil
        }

        let summaries = (try? await repo.fetchAllSummaries()) ?? []
        guard !summaries.isEmpty else {
            lastMaintenanceSummary = "Aucune activité à renommer."
            return
        }

        var renamed = 0
        var skipped = 0
        for (idx, summary) in summaries.enumerated() {
            renameAllProgress = "Renommage \(idx + 1)/\(summaries.count)… (le débit du géocodage est limité, soyez patient)"
            guard let data = try? await repo.fetchTrackData(id: summary.id), !data.isEmpty,
                  let points = try? TrackPointCodec.decode(data),
                  let name = await RouteNamer.suggestName(points: points) else {
                skipped += 1
                continue
            }
            do {
                try await repo.updateTitle(id: summary.id, title: name)
                renamed += 1
            } catch {
                skipped += 1
            }
            if idx % 10 == 9 { libraryRevision += 1 }
        }

        libraryRevision += 1
        lastMaintenanceSummary = "\(renamed) renommée(s) · \(skipped) ignorée(s) sur \(summaries.count)."
    }

    func scanWatchedFolder(_ folderURL: URL) async {
        isScanningWatchedFolder = true
        defer {
            isScanningWatchedFolder = false
            watchedFolderProgress = nil
        }
        importError = nil
        lastWatchedFolderSummary = nil

        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let candidates: [URL]
        do {
            candidates = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        } catch {
            importError = "Échec de la lecture du dossier : \(error.localizedDescription)"
            return
        }

        let supported = candidates.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "gpx" || ext == "fit"
        }

        if supported.isEmpty {
            lastWatchedFolderSummary = "Aucun fichier GPX/FIT trouvé."
            return
        }

        var proposals: [ImportProposal] = []
        var duplicates = 0
        var failures = 0
        for (idx, url) in supported.enumerated() {
            watchedFolderProgress = "Analyse \(idx + 1)/\(supported.count)…"
            do {
                let proposal = try await importer.prepareImport(from: url)
                if proposal.duplicateOfActivityId != nil {
                    duplicates += 1
                } else {
                    proposals.append(proposal)
                }
            } catch {
                failures += 1
                NSLog("GPXManagement: prepareImport failed for \(url.lastPathComponent): \(error)")
            }
        }

        pendingImports.append(contentsOf: proposals)

        var parts: [String] = []
        parts.append("\(proposals.count) nouveau(x)")
        if duplicates > 0 { parts.append("\(duplicates) déjà importé(s)") }
        if failures > 0 { parts.append("\(failures) échec(s)") }
        lastWatchedFolderSummary = parts.joined(separator: " · ")
        if proposals.isEmpty && duplicates > 0 {
            importError = "Tous les fichiers (\(duplicates)) sont déjà importés."
        }
    }
}
