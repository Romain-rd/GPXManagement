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
    var lastMaintenanceSummary: String?
    var libraryRevision: Int = 0
    var isReorganizing: Bool = false
    var reorganizeProgress: String?
    var pendingReorganizeCount: Int = 0
    var isSyncingStrava: Bool = false
    var stravaSyncProgress: String?
    var lastStravaSyncSummary: String?

    private let stravaAPI = StravaAPI()
    private static let stravaLastRunKey = "stravaLastSyncRun"

    /// Date du dernier lancement de sync (affichage uniquement). Le curseur réel est dérivé des données.
    var stravaLastSyncDate: Date? {
        let t = UserDefaults.standard.double(forKey: Self.stravaLastRunKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private var plannedReorg: (pattern: OrganizationPattern, moves: [ReorganizationMove])?

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
        if fallbackUsed > 0 { parts.append("\(fallbackUsed) classée(s) \(fallbackType.displayName)") }
        if failures > 0 { parts.append("\(failures) échec(s) réel(s)") }
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

    func deleteAllData() async {
        guard let repo = coreDataRepository else { return }
        isDeletingAll = true
        lastMaintenanceSummary = nil
        importError = nil
        defer { isDeletingAll = false }

        do {
            let count = try await repo.deleteAllActivities()
            try await storage.removeAllStoredFiles()
            UserDefaults.standard.removeObject(forKey: Self.stravaLastRunKey)
            lastStravaSyncSummary = nil
            libraryRevision += 1
            lastMaintenanceSummary = "\(count) activité(s) supprimée(s). Bibliothèque et fichiers vidés."
        } catch {
            importError = "Échec de la suppression : \(error.localizedDescription)"
        }
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

    // MARK: - Synchronisation Strava (récupération des activités)

    func syncStrava() async {
        guard !isSyncingStrava else { return }
        guard await strava.validAccessToken() != nil else {
            lastStravaSyncSummary = "Non connecté à Strava."
            return
        }
        isSyncingStrava = true
        lastStravaSyncSummary = nil
        defer {
            isSyncingStrava = false
            stravaSyncProgress = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.stravaLastRunKey)
        }

        // 1. Lister les activités (pagination, depuis la dernière activité Strava connue en base).
        //    Curseur dérivé des données → se réinitialise automatiquement si on a tout supprimé.
        stravaSyncProgress = "Récupération de la liste des activités…"
        let after = (try? await coreDataRepository?.latestStravaActivityDate()) ?? nil
        var summaries: [StravaActivitySummary] = []
        var page = 1
        do {
            while page <= 60 {
                guard let token = await strava.validAccessToken() else { break }
                let batch = try await stravaAPI.activities(accessToken: token, after: after, page: page, perPage: 50)
                if batch.isEmpty { break }
                summaries.append(contentsOf: batch)
                page += 1
            }
        } catch let error as StravaError {
            lastStravaSyncSummary = error.localizedDescription
            return
        } catch {
            lastStravaSyncSummary = "Échec de la récupération : \(error.localizedDescription)"
            return
        }

        // 2. Traiter du plus ancien au plus récent → reprise propre si limite de débit.
        let geo = summaries.filter(\.hasGPS).sorted { $0.startDate < $1.startDate }
        guard !geo.isEmpty else {
            lastStravaSyncSummary = "Aucune nouvelle activité avec trace GPS."
            return
        }

        var imported = 0, duplicates = 0, failures = 0
        for (idx, act) in geo.enumerated() {
            stravaSyncProgress = "Import \(idx + 1)/\(geo.count) : \(act.name)"
            guard let token = await strava.validAccessToken() else { break }
            do {
                let stream = try await stravaAPI.streams(accessToken: token, activityId: act.id)
                guard !stream.isEmpty else { continue }
                let type = ActivityType.fromStravaSportType(act.sportType)
                let points = stream.map { p in
                    TrackPoint(
                        latitude: p.latitude, longitude: p.longitude,
                        altitude: p.altitude,
                        timestamp: p.timeOffset.map { act.startDate.addingTimeInterval($0) },
                        heartRate: p.heartRate, cadence: p.cadence, power: p.power
                    )
                }
                let gpxData = try GPXWriter.write(name: act.name, activityType: type, points: points)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("strava-\(act.id).gpx")
                try gpxData.write(to: tmp, options: .atomic)
                let proposal = try await importer.prepareImport(from: tmp, hintedActivityType: type, hintedTitle: act.name, origin: .strava, stravaId: String(act.id))
                if proposal.duplicateOfActivityId != nil {
                    duplicates += 1
                } else {
                    _ = try await importer.confirmImport(proposal, activityType: type ?? .other, title: act.name)
                    imported += 1
                }
                try? FileManager.default.removeItem(at: tmp)
                if imported % 10 == 0 && imported > 0 { libraryRevision += 1 }
                try? await Task.sleep(nanoseconds: 250_000_000)
            } catch StravaError.rateLimited {
                if imported > 0 { libraryRevision += 1 }
                lastStravaSyncSummary = "Limite Strava atteinte — \(imported) importée(s). Relancez la sync dans quelques minutes (reprise automatique)."
                return
            } catch {
                failures += 1
                NSLog("GPXManagement: Strava sync failed for \(act.id): \(error)")
            }
        }

        if imported > 0 { libraryRevision += 1 }
        lastStravaSyncSummary = "\(imported) importée(s) · \(duplicates) déjà présente(s)" + (failures > 0 ? " · \(failures) échec(s)" : "")
    }

    /// Extrait l'identifiant d'activité Strava depuis le nom de fichier d'archive (ex. "123456.gpx" → "123456").
    nonisolated static func stravaActivityId(fromArchiveFile url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let digits = name.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    // MARK: - Réorganisation des fichiers selon le modèle

    /// Calcule (dry-run) les déplacements nécessaires pour le modèle courant. Renvoie le nombre de fichiers à déplacer.
    func prepareReorganization() async -> Int {
        guard let repo = coreDataRepository else { return 0 }
        let pattern = Self.currentOrganizationPattern()
        let summaries = (try? await repo.fetchAllSummaries()) ?? []
        let entries: [ReorganizationEntry] = summaries.compactMap { s in
            guard !s.sourceFileName.isEmpty else { return nil }
            let descriptor = ActivityDescriptor(
                id: s.id,
                startDate: s.startDate,
                activityType: s.activityType,
                title: s.title,
                sourceFileFormat: s.sourceFileFormat
            )
            return ReorganizationEntry(descriptor: descriptor, currentRelativePath: s.sourceFileName)
        }
        let moves = (try? await storage.reorganize(entries, to: pattern, dryRun: true)) ?? []
        plannedReorg = (pattern, moves)
        pendingReorganizeCount = moves.count
        return moves.count
    }

    /// Applique les déplacements calculés et met à jour les chemins en base.
    func applyReorganization() async {
        guard let repo = coreDataRepository, let planned = plannedReorg, !planned.moves.isEmpty else { return }
        isReorganizing = true
        lastMaintenanceSummary = nil
        defer {
            isReorganizing = false
            reorganizeProgress = nil
            plannedReorg = nil
            pendingReorganizeCount = 0
        }

        reorganizeProgress = "Réorganisation des fichiers…"
        await storage.updatePattern(planned.pattern)
        do {
            let applied = try await storage.reorganizeMoves(planned.moves)
            var updated = 0
            for move in applied {
                do {
                    try await repo.updateSourceFileName(id: move.activityId, relativePath: move.to)
                    updated += 1
                } catch {
                    NSLog("GPXManagement: updateSourceFileName failed for \(move.activityId): \(error)")
                }
            }
            libraryRevision += 1
            lastMaintenanceSummary = "\(updated) fichier(s) réorganisé(s)."
        } catch {
            lastMaintenanceSummary = "Échec de la réorganisation : \(error.localizedDescription)"
        }
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
            return ext == "gpx" || ext == "fit" || ext == "tcx"
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
