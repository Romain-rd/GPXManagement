import Foundation
import AppKit
import UniformTypeIdentifiers
import GPXCore
import GPXStrava

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
    let strava = StravaAuthService()

    var pendingImports: [ImportProposal] = []
    var importError: String?
    var importedCount: Int = 0
    var isPreparingImports: Bool = false
    var preparingImportProgress: String?
    var isScanningHealthExport: Bool = false
    var healthScanProgress: String?
    var isScanningWatchedFolder: Bool = false
    var watchedFolderProgress: String?
    var lastWatchedFolderSummary: String?
    var isRenamingAll: Bool = false
    var renameAllProgress: String?
    var isDeletingAll: Bool = false
    var isRecalculatingSources: Bool = false
    var recalcSourcesProgress: String?
    var isReprocessing: Bool = false
    var reprocessProgress: String?
    var isForcingCloudKitResync: Bool = false
    var cloudKitResyncProgress: String?
    var lastMaintenanceSummary: String?
    var libraryRevision: Int = 0
    var isReorganizing: Bool = false
    var reorganizeProgress: String?
    var pendingReorganizeCount: Int = 0
    var isSyncingStrava: Bool = false
    var stravaSyncProgress: String?
    var lastStravaSyncSummary: String?

    let stravaAPI = StravaAPI()

    /// Date du dernier lancement de sync (affichage uniquement, synchronisée entre appareils via iCloud).
    /// Le curseur réel de la sync incrémentale est dérivé des données (latestStravaActivityDate).
    var stravaLastSyncDate: Date? { CloudPreferences.shared.stravaLastSyncDate }

    var plannedReorg: (pattern: OrganizationPattern, moves: [ReorganizationMove])?

    private init() {
        self.persistence = PersistenceController.shared
        self.iCloudContainer = ICloudContainer(identifier: AppConfig.iCloudContainerIdentifier)
        let pattern = Self.currentOrganizationPattern()
        self.storage = FileStorageService(container: iCloudContainer, pattern: pattern)
        let repo = CoreDataActivityRepository(persistence: persistence)
        self.repository = repo
        self.importer = ImportService(storage: storage, repository: repo)
        self.healthImporter = AppleHealthImporter()
        self.stravaImporter = StravaArchiveImporter()
        // Active la sync iCloud du modèle d'organisation dès le lancement (push initial + écoute des autres appareils).
        _ = CloudPreferences.shared
    }

    static func currentOrganizationPattern() -> OrganizationPattern {
        if let template = UserDefaults.standard.string(forKey: "organizationPattern"),
           let pattern = try? OrganizationPattern(template: template) {
            return pattern
        }
        return .default
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
            UTType(filenameExtension: "fit") ?? .data,
            UTType(filenameExtension: "tcx") ?? .xml
        ]
        panel.title = "Choisir des fichiers GPX, FIT ou TCX"
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
        Task { await importStravaArchive(at: url, fallbackType: .other) }
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
            importError = "Aucune trace GPX/FIT/TCX trouvée dans activities/."
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
                    origin: .strava,
                    stravaId: Self.stravaActivityId(fromArchiveFile: fileURL)
                )
                if proposal.duplicateOfActivityId != nil {
                    duplicates += 1
                    continue
                }
                let type = proposal.suggestedActivityType ?? fallbackType
                if proposal.suggestedActivityType == nil { fallbackUsed += 1 }
                _ = try await importer.confirmImport(proposal, activityType: type, title: proposal.defaultTitle(for: type))
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
        if fallbackUsed > 0 { parts.append("\(fallbackUsed) classée(s) \(fallbackType.displayName)") }
        if failures > 0 { parts.append("\(failures) échec(s) réel(s)") }
        lastWatchedFolderSummary = parts.joined(separator: " · ")
    }

    func confirmAllPendingImports(defaultActivityType: ActivityType) async {
        // Les fichiers issus de HealthFit vivent dans le dossier surveillé : sans accès ouvert ici,
        // la copie vers le container échoue (Code=513), car le scan a déjà refermé son accès.
        let folder = WatchedFolderBookmark.resolve()
        let access = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if access { folder?.stopAccessingSecurityScopedResource() } }
        let snapshot = pendingImports
        for proposal in snapshot {
            let type = proposal.suggestedActivityType ?? defaultActivityType
            do {
                _ = try await importer.confirmImport(proposal, activityType: type, title: proposal.defaultTitle(for: type))
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
        isPreparingImports = true
        defer {
            isPreparingImports = false
            preparingImportProgress = nil
        }
        var proposals: [ImportProposal] = []
        for (idx, url) in urls.enumerated() {
            preparingImportProgress = urls.count > 1
                ? "Analyse \(idx + 1)/\(urls.count) — \(url.lastPathComponent)"
                : "Analyse de \(url.lastPathComponent)…"
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

    func confirmImport(_ proposal: ImportProposal, activityType: ActivityType, title: String, isCourse: Bool? = nil) async {
        let folder = WatchedFolderBookmark.resolve()
        let access = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if access { folder?.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await importer.confirmImport(proposal, activityType: activityType, title: title, isCourse: isCourse)
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




    /// Scan auto (lancement / réactivation) : ne propose que les fichiers déposés depuis le dernier scan,
    /// en silence. Au tout premier scan on amorce juste la date — le retard existant n'est jamais proposé.
    func scanWatchedFolderIfConfigured() async {
        guard let folder = WatchedFolderBookmark.resolve() else { return }
        guard let cutoff = WatchedFolderBookmark.lastScanDate else {
            WatchedFolderBookmark.lastScanDate = Date()
            return
        }
        let scanStart = Date()
        await scanWatchedFolder(folder, silent: true, modifiedAfter: cutoff)
        WatchedFolderBookmark.lastScanDate = scanStart
    }

    func scanWatchedFolder(_ folderURL: URL, silent: Bool = false, modifiedAfter cutoff: Date? = nil) async {
        isScanningWatchedFolder = true
        defer {
            isScanningWatchedFolder = false
            watchedFolderProgress = nil
        }
        if !silent { importError = nil }
        lastWatchedFolderSummary = nil

        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let candidates: [URL]
        do {
            candidates = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        } catch {
            if silent {
                NSLog("GPXManagement: scan auto du dossier surveillé échoué: \(error)")
            } else {
                importError = "Échec de la lecture du dossier : \(error.localizedDescription)"
            }
            return
        }

        let supported = candidates.filter { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "gpx" || ext == "fit" || ext == "tcx" else { return false }
            guard let cutoff else { return true }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return mod > cutoff
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
        if !silent, proposals.isEmpty && duplicates > 0 {
            importError = "Tous les fichiers (\(duplicates)) sont déjà importés."
        }
    }
}
