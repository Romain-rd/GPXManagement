import Foundation
import GPXCore

// MARK: - Maintenance de la bibliothèque (suppression, renommage, recalculs, resync CloudKit)

extension AppServices {
    func deleteAllData() async {
        guard let repo = coreDataRepository else { return }
        isDeletingAll = true
        lastMaintenanceSummary = nil
        importError = nil
        defer { isDeletingAll = false }

        do {
            let count = try await repo.deleteAllActivities()
            try await storage.removeAllStoredFiles()
            CloudPreferences.shared.resetStravaSync()
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

    /// Recalcule l'application source de toutes les activités en relisant leurs fichiers stockés.
    func recalculateSources() async {
        guard let repo = coreDataRepository else { return }
        isRecalculatingSources = true
        lastMaintenanceSummary = nil
        defer {
            isRecalculatingSources = false
            recalcSourcesProgress = nil
        }

        let entries = (try? await repo.fetchSourceRecomputeEntries()) ?? []
        guard !entries.isEmpty else {
            lastMaintenanceSummary = "Aucune activité à analyser."
            return
        }

        var updated = 0
        var missing = 0
        var failures = 0
        var reclassified = 0
        for (idx, entry) in entries.enumerated() {
            recalcSourcesProgress = "Analyse \(idx + 1)/\(entries.count)…"
            do {
                let url = try await storage.url(forRelativePath: entry.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missing += 1
                    continue
                }
                let sourceApp = try await importer.detectSourceApp(at: url, origin: entry.origin)
                try await repo.updateSourceApp(id: entry.id, sourceApp: sourceApp)
                updated += 1

                // Réaffecte le type déduit de la source (ex. Scenic → Moto) si le type est resté générique.
                if entry.activityType == .other,
                   let deducedType = ActivityTypeDetector.detect(source: ActivitySource(rawCreator: sourceApp)) {
                    try await repo.updateActivityType(id: entry.id, rawValue: deducedType.rawValue)
                    reclassified += 1
                }
            } catch {
                failures += 1
                NSLog("GPXManagement: recalc source failed for \(entry.id): \(error)")
            }
            if idx % 25 == 24 { libraryRevision += 1 }
        }

        libraryRevision += 1
        var parts = ["\(updated) mise(s) à jour"]
        if reclassified > 0 { parts.append("\(reclassified) reclassée(s) par type") }
        if missing > 0 { parts.append("\(missing) fichier(s) introuvable(s)") }
        if failures > 0 { parts.append("\(failures) échec(s)") }
        lastMaintenanceSummary = parts.joined(separator: " · ")
    }

    /// Re-traite tous les fichiers stockés : recalcule tracé + statistiques (corrige les tracés
    /// pollués, ex. Scenic) et met à jour la source. Réaffecte le type déduit si resté générique.
    /// Répare une activité : ré-analyse son fichier source et rafraîchit ses statistiques (utile pour les
    /// activités importées par une ancienne version — ex. FC d'une séance sans GPS jamais enregistrée).
    @discardableResult
    func reprocessActivity(id: UUID) async -> Bool {
        guard let repo = coreDataRepository,
              let entry = try? await repo.fetchSourceRecomputeEntry(id: id) else {
            importError = "Activité sans fichier source exploitable."
            return false
        }
        do {
            let url = try await storage.url(forRelativePath: entry.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                importError = "Fichier source introuvable dans le conteneur iCloud."
                return false
            }
            let result = try await importer.reprocess(fileAt: url, origin: entry.origin)
            // Ne reclasse que si le type est resté générique (« Autre »).
            let newType: ActivityType? = (entry.activityType == .other && (result.suggestedType ?? .other) != .other) ? result.suggestedType : nil
            try await repo.applyReprocess(id: id, result: result, newType: newType)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la réparation : \(error.localizedDescription)"
            return false
        }
    }

    func reprocessAllFromSource() async {
        guard let repo = coreDataRepository else { return }
        isReprocessing = true
        lastMaintenanceSummary = nil
        defer {
            isReprocessing = false
            reprocessProgress = nil
        }

        let entries = (try? await repo.fetchSourceRecomputeEntries()) ?? []
        guard !entries.isEmpty else {
            lastMaintenanceSummary = "Aucune activité à re-traiter."
            return
        }

        var updated = 0
        var missing = 0
        var failures = 0
        var reclassified = 0
        for (idx, entry) in entries.enumerated() {
            reprocessProgress = "Re-traitement \(idx + 1)/\(entries.count)…"
            do {
                let url = try await storage.url(forRelativePath: entry.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missing += 1
                    continue
                }
                let result = try await importer.reprocess(fileAt: url, origin: entry.origin)
                // N'écrase pas un type choisi : ne reclasse que si le type est resté générique.
                var newType: ActivityType?
                if entry.activityType == .other, let suggested = result.suggestedType, suggested != .other {
                    newType = suggested
                    reclassified += 1
                }
                try await repo.applyReprocess(id: entry.id, result: result, newType: newType)
                updated += 1
            } catch {
                failures += 1
                NSLog("GPXManagement: reprocess failed for \(entry.id): \(error)")
            }
            if idx % 25 == 24 { libraryRevision += 1 }
        }

        libraryRevision += 1
        var parts = ["\(updated) re-traitée(s)"]
        if reclassified > 0 { parts.append("\(reclassified) reclassée(s) par type") }
        if missing > 0 { parts.append("\(missing) fichier(s) introuvable(s)") }
        if failures > 0 { parts.append("\(failures) échec(s)") }
        lastMaintenanceSummary = parts.joined(separator: " · ")
    }

    // MARK: - Resync CloudKit (rattrapage des activités non poussées)

    /// Touche `updatedAt` sur chaque Activity pour relancer un export CloudKit complet.
    /// Utile quand une machine a un historique local que NSPersistentCloudKitContainer n'a jamais pushé.
    func forceCloudKitResync() async {
        guard let repo = coreDataRepository else { return }
        guard !isForcingCloudKitResync else { return }
        isForcingCloudKitResync = true
        lastMaintenanceSummary = nil
        defer {
            isForcingCloudKitResync = false
            cloudKitResyncProgress = nil
        }
        do {
            let total = try await repo.touchAllActivitiesForResync { done, total in
                self.cloudKitResyncProgress = "Touche \(done)/\(total)…"
            }
            libraryRevision += 1
            lastMaintenanceSummary = total > 0
                ? "\(total) activité(s) marquée(s) pour resync CloudKit. La synchronisation peut prendre quelques minutes."
                : "Aucune activité à resynchroniser."
        } catch {
            NSLog("GPXManagement: forceCloudKitResync failed: \(error)")
            lastMaintenanceSummary = "Échec de la resync : \(error.localizedDescription)"
        }
    }

    enum ElevationGenerationOutcome: Sendable {
        case enriched(resolved: Int, total: Int)
        case noCoverage
        case failed(String)
    }

    /// Génère un profil altimétrique pour une trace qui n'en a pas : récupère l'altitude (IGN + repli
    /// mondial), recalcule le dénivelé et enregistre la trace enrichie en place.
    func generateElevationProfile(id: UUID) async -> ElevationGenerationOutcome {
        guard let repo = coreDataRepository else { return .failed("Stockage indisponible.") }
        do {
            guard let data = try await repo.fetchTrackData(id: id) else { return .failed("Trace introuvable.") }
            let points = try TrackPointCodec.decode(data)
            guard points.count >= 2 else { return .failed("Trace trop courte.") }
            let result = await ElevationEnricher.shared.enrich(points: points)
            guard result.resolved >= 2 else { return .noCoverage }
            let stats = ActivityStatsCalculator.compute(points: result.points)
            let encoded = try TrackPointCodec.encode(result.points)
            try await repo.updateTrackData(id: id, trackData: encoded, stats: stats)
            // Réécrit l'altitude dans le fichier GPX source pour qu'elle survive à un futur « Réparer ».
            if let entry = try? await repo.fetchSourceRecomputeEntry(id: id), entry.format == .gpx {
                await rewriteSourceGPX(entry: entry, points: result.points)
            }
            libraryRevision += 1
            return .enriched(resolved: result.resolved, total: points.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func rewriteSourceGPX(entry: SourceRecomputeEntry, points: [TrackPoint]) async {
        guard let url = try? await storage.url(forRelativePath: entry.relativePath),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let name = Self.gpxName(in: existing) ?? url.deletingPathExtension().lastPathComponent
        guard let data = try? GPXWriter.write(name: name, activityType: entry.activityType, points: points) else { return }
        try? await storage.overwrite(relativePath: entry.relativePath, with: data)
    }

    /// Découpe une trace en deux activités dérivées « (1/2) » et « (2/2) » au point `index` (inclus dans les deux).
    @discardableResult
    func splitActivity(parent: ActivitySummary, at index: Int) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            guard let data = try await repo.fetchTrackData(id: parent.id) else { importError = "Trace introuvable."; return false }
            let points = try TrackPointCodec.decode(data)
            let halves = TrackOperations.split(points: points, at: index)
            guard halves.left.count >= 2, halves.right.count >= 2 else {
                importError = "Point de découpe trop proche d'une extrémité."
                return false
            }
            _ = try await createDerivedActivity(parent: parent, title: "\(parent.title) (1/2)", points: halves.left, repo: repo)
            _ = try await createDerivedActivity(parent: parent, title: "\(parent.title) (2/2)", points: halves.right, repo: repo)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la découpe : \(error.localizedDescription)"
            return false
        }
    }

    /// Simplifie une trace (Douglas-Peucker) en une activité dérivée « (simplifié) ».
    @discardableResult
    func simplifyActivity(parent: ActivitySummary, tolerance: Double) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            guard let data = try await repo.fetchTrackData(id: parent.id) else { importError = "Trace introuvable."; return false }
            let points = try TrackPointCodec.decode(data)
            let simplified = TrackOperations.simplify(points: points, tolerance: tolerance)
            guard simplified.count >= 2 else { importError = "Résultat trop court."; return false }
            _ = try await createDerivedActivity(parent: parent, title: "\(parent.title) (simplifié)", points: simplified, repo: repo)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la simplification : \(error.localizedDescription)"
            return false
        }
    }

    /// Retire les points aberrants d'une trace en une activité dérivée « (nettoyé) ».
    @discardableResult
    func cleanActivity(parent: ActivitySummary, maxSpeed: Double) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            guard let data = try await repo.fetchTrackData(id: parent.id) else { importError = "Trace introuvable."; return false }
            let points = try TrackPointCodec.decode(data)
            let result = TrackOperations.cleanOutliers(points: points, maxSpeed: maxSpeed)
            guard result.cleaned.count >= 2 else { importError = "Résultat trop court."; return false }
            _ = try await createDerivedActivity(parent: parent, title: "\(parent.title) (nettoyé)", points: result.cleaned, repo: repo)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec du nettoyage : \(error.localizedDescription)"
            return false
        }
    }

    /// Duplique une trace en une copie indépendante « (copie) » (sans lien de dérivation).
    @discardableResult
    func duplicateActivity(parent: ActivitySummary) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            guard let data = try await repo.fetchTrackData(id: parent.id) else { importError = "Trace introuvable."; return false }
            let points = try TrackPointCodec.decode(data)
            guard points.count >= 2 else { importError = "Trace trop courte."; return false }
            _ = try await createDerivedActivity(parent: parent, title: "\(parent.title) (copie)", points: points, repo: repo, linkToParent: false)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la duplication : \(error.localizedDescription)"
            return false
        }
    }

    /// Inverse le sens d'une trace en une activité dérivée « (sens inversé) ».
    @discardableResult
    func reverseActivity(parent: ActivitySummary) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            guard let data = try await repo.fetchTrackData(id: parent.id) else { importError = "Trace introuvable."; return false }
            let points = try TrackPointCodec.decode(data)
            let reversed = TrackOperations.reverse(points: points)
            guard reversed.count >= 2 else { importError = "Trace trop courte."; return false }
            _ = try await createDerivedActivity(parent: parent, title: "\(parent.title) (sens inversé)", points: reversed, repo: repo)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de l'inversion : \(error.localizedDescription)"
            return false
        }
    }

    /// Enregistre une fusion : les points déjà ordonnés/orientés par l'UI deviennent une activité dérivée « (fusion) ».
    @discardableResult
    func saveMergedActivity(points: [TrackPoint], parents: [ActivitySummary]) async -> Bool {
        guard points.count >= 2, let repo = coreDataRepository,
              let base = parents.min(by: { $0.startDate < $1.startDate }) else { return false }
        do {
            _ = try await createDerivedActivity(parent: base, title: "\(base.title) (fusion)", points: points, repo: repo)
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la fusion : \(error.localizedDescription)"
            return false
        }
    }

    /// Crée une activité dérivée à partir de points édités : écrit un GPX temporaire, le ré-importe (stats
    /// recalculées) et renseigne `editedFromActivityId`.
    private func createDerivedActivity(parent: ActivitySummary, title: String, points: [TrackPoint], repo: CoreDataActivityRepository, linkToParent: Bool = true) async throws -> UUID {
        let gpx = try GPXWriter.write(name: title, activityType: parent.activityType, points: points)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gpx")
        try gpx.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let proposal = try await importer.prepareImport(from: tmp, hintedActivityType: parent.activityType, hintedTitle: title)
        let newId = try await importer.confirmImport(proposal, activityType: parent.activityType, title: title, isCourse: parent.isCourse)
        if linkToParent { try await repo.setEditedFromActivityId(newId: newId, parentId: parent.id) }
        return newId
    }

    private static func gpxName(in xml: String) -> String? {
        guard let open = xml.range(of: "<name>"),
              let close = xml.range(of: "</name>", range: open.upperBound..<xml.endIndex) else { return nil }
        let raw = String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
