import Foundation
import GPXCore
import MapKit

// MARK: - Maintenance de la bibliothèque (suppression, renommage, recalculs, resync CloudKit)

extension AppServices {
    /// Reconstruit la bibliothèque depuis les fichiers GPX/FIT déjà présents dans le conteneur — sans copier ni
    /// supprimer. Récupération après une perte des métadonnées Core Data (ex. reset du miroir CloudKit) ; les
    /// classements/annotations manuels (tags, notes, raids, parcours) ne sont pas restaurés.
    func rebuildLibraryFromStorage() async {
        guard let _ = coreDataRepository, !isDeletingAll else { return }
        isDeletingAll = true
        lastMaintenanceSummary = nil
        importError = nil
        defer { isDeletingAll = false; watchedFolderProgress = nil }
        do {
            let files = try await storage.enumerateStoredFiles()
            guard !files.isEmpty else { lastMaintenanceSummary = "Aucun fichier à reconstruire."; return }
            var ok = 0, dup = 0, fail = 0
            for (idx, entry) in files.enumerated() {
                watchedFolderProgress = "Reconstruction \(idx + 1)/\(files.count)…"
                do {
                    let proposal = try await importer.prepareImport(from: entry.url)
                    if proposal.duplicateOfActivityId != nil { dup += 1; continue }
                    _ = try await importer.registerExisting(proposal, relativePath: entry.relativePath,
                                                            activityType: proposal.suggestedActivityType ?? .other,
                                                            title: proposal.suggestedTitle)
                    ok += 1
                } catch {
                    fail += 1
                    NSLog("GPXManagement: reconstruction échouée pour \(entry.url.lastPathComponent): \(error)")
                }
            }
            libraryRevision += 1
            var parts = ["\(ok) activité(s) reconstruite(s)"]
            if dup > 0 { parts.append("\(dup) doublon(s) ignoré(s)") }
            if fail > 0 { parts.append("\(fail) échec(s)") }
            lastMaintenanceSummary = parts.joined(separator: " · ")
        } catch {
            importError = "Échec de la reconstruction : \(error.localizedDescription)"
        }
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

    /// Inverse le sens d'un parcours EN PLACE : trace + points de passage retournés, étapes supprimées (devenues caduques).
    func reverseParcours(activityId: UUID) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            if let data = try await repo.fetchTrackData(id: activityId), let pts = try? TrackPointCodec.decode(data), pts.count >= 2 {
                let reversed = TrackOperations.reverse(points: pts)
                try await repo.updateTrackData(id: activityId, trackData: try TrackPointCodec.encode(reversed), stats: ActivityStatsCalculator.compute(points: reversed))
            }
            let wps = RouteWaypointCodec.decode(try await repo.fetchRouteWaypointsData(id: activityId))
            if !wps.isEmpty {
                try await repo.updateRouteWaypointsData(id: activityId, data: RouteWaypointCodec.encode(Array(wps.reversed())))
            }
            try await repo.replaceStages(activityId: activityId, with: [])
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de l'inversion : \(error.localizedDescription)"
            return false
        }
    }

    /// Duplique un parcours : trace + points de passage typés + étapes (re-clés sur la copie) + drapeaux parcours.
    func duplicateParcours(parent: ActivitySummary) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            let points = try await (repo.fetchTrackData(id: parent.id).map { try TrackPointCodec.decode($0) }) ?? []
            guard points.count >= 2 else { importError = "Parcours sans tracé à dupliquer."; return false }
            let newId = try await createDerivedActivity(parent: parent, title: "\(parent.title) (copie)", points: points, repo: repo, linkToParent: false)
            if parent.isEditableRoute { try await repo.setEditableRoute(id: newId, true) }
            if let wp = try await repo.fetchRouteWaypointsData(id: parent.id) { try await repo.updateRouteWaypointsData(id: newId, data: wp) }
            let stages = try await repo.fetchStages(activityId: parent.id)
            if !stages.isEmpty || parent.isStagedRoute {
                try await repo.setStagedRoute(activityId: newId, true)
                let copies = stages.map { s in
                    Stage(activityId: newId, order: s.order, name: s.name, notes: s.notes, startIndex: s.startIndex, endIndex: s.endIndex,
                          stopWaypointId: s.stopWaypointId, coverImageData: s.coverImageData,
                          endOffTrackLatitude: s.endOffTrackLatitude, endOffTrackLongitude: s.endOffTrackLongitude,
                          endConnectorData: s.endConnectorData, startConnectorData: s.startConnectorData, plannedDate: s.plannedDate)
                }
                try await repo.replaceStages(activityId: newId, with: copies)
            }
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la duplication : \(error.localizedDescription)"
            return false
        }
    }

    /// Duplique un raid : nouveau raid (mêmes métadonnées/participants/couverture) + copies de chaque activité membre.
    func duplicateRaid(_ raid: Raid, members: [ActivitySummary]) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        do {
            let newRaid = Raid(name: "\(raid.name) (copie)", subtitle: raid.subtitle, place: raid.place, notes: raid.notes,
                               startDate: raid.startDate, endDate: raid.endDate, coverImageData: raid.coverImageData,
                               participants: raid.participants)
            try await repo.createRaid(newRaid)
            var newMemberIds: [UUID] = []
            for m in members {
                guard let data = try? await repo.fetchTrackData(id: m.id),
                      let pts = try? TrackPointCodec.decode(data), pts.count >= 2 else { continue }
                let newId = try await createDerivedActivity(parent: m, title: m.title, points: pts, repo: repo, linkToParent: false)
                newMemberIds.append(newId)
            }
            if !newMemberIds.isEmpty { try await repo.setRaid(activityIds: newMemberIds, raidId: newRaid.id) }
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec de la duplication du raid : \(error.localizedDescription)"
            return false
        }
    }

    /// Crée un parcours en étapes à partir d'une trace : **duplique** la trace (l'originale reste intacte),
    /// passe la copie en mode étapes et l'initialise avec une étape couvrant tout le tracé.
    @discardableResult
    /// Crée un parcours **vide** (modifiable, sans trace) — l'utilisateur posera les points dans l'éditeur d'itinéraire.
    func createEmptyParcours() async -> UUID? {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return nil }
        let id = UUID()
        let now = Date()
        let payload = ActivityCreationPayload(
            id: id, title: "Nouveau parcours", activityType: .hiking, origin: .manualImport,
            sourceFileName: "", sourceFileFormat: .gpx, startDate: now, endDate: now,
            stats: .zero, trackData: (try? TrackPointCodec.encode([])) ?? Data(),
            fileSHA256: "", isCourse: true, isEditableRoute: true
        )
        do {
            try await repo.createActivity(payload)
            try await repo.setStagedRoute(activityId: id, true)
            libraryRevision += 1
            return id
        } catch {
            importError = "Échec de la création du parcours : \(error.localizedDescription)"
            return nil
        }
    }

    /// Passe une activité en parcours en étapes **en place** (pas de copie) : un seul objet édité côté itinéraire ET étapes.
    func convertToStagedRoute(activity: ActivitySummary) async -> UUID? {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return nil }
        do {
            guard let data = try await repo.fetchTrackData(id: activity.id) else { importError = "Trace introuvable."; return nil }
            let points = try TrackPointCodec.decode(data)
            guard points.count > 1 else { importError = "Trace trop courte."; return nil }
            try await repo.setIsCourse(id: activity.id, isCourse: true)   // un parcours = une route classée « parcours »
            try await repo.setStagedRoute(activityId: activity.id, true)
            let existing = (try? await repo.fetchStages(activityId: activity.id)) ?? []
            if existing.isEmpty {
                let stage = Stage(activityId: activity.id, order: 0, name: "Étape 1", startIndex: 0, endIndex: points.count - 1)
                try await repo.replaceStages(activityId: activity.id, with: [stage])
            }
            libraryRevision += 1
            return activity.id
        } catch {
            importError = "Échec de la création du parcours : \(error.localizedDescription)"
            return nil
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



extension AppServices {
    /// Route un itinéraire à partir de ses points de passage (segments routés + altitude IGN), réécrit le tracé
    /// et les stats, et enregistre les points de passage. Réservé aux parcours.
    @discardableResult
    func applyRouteWaypoints(activityId: UUID, waypoints: [RouteWaypoint], routedCoords: [CLLocationCoordinate2D] = []) async -> Bool {
        guard let repo = coreDataRepository else { importError = "Stockage indisponible."; return false }
        guard waypoints.count >= 2 else { importError = "Au moins 2 points de passage requis."; return false }
        do {
            var coords = routedCoords
            if coords.count < 2 {
                let profile = RouteProfile(rawValue: UserDefaults.standard.string(forKey: "routeProfile") ?? "") ?? .car
                for i in 0..<(waypoints.count - 1) {
                    if i > 0, ConnectorRouter.needsPacing { try? await Task.sleep(nanoseconds: 350_000_000) }
                    let a = CLLocationCoordinate2D(latitude: waypoints[i].latitude, longitude: waypoints[i].longitude)
                    let b = CLLocationCoordinate2D(latitude: waypoints[i + 1].latitude, longitude: waypoints[i + 1].longitude)
                    var seg = await ConnectorRouter.route(from: a, to: b, profile: profile).coords
                    if seg.count < 2 { seg = [a, b] }
                    if !coords.isEmpty { seg.removeFirst() }
                    coords.append(contentsOf: seg)
                }
            }
            guard coords.count >= 2 else { importError = "Itinéraire vide."; return false }
            // 1) Écriture rapide de la GÉOMÉTRIE (sans attendre l'altitude, qui peut être très lente en transfrontalier).
            let raw = coords.map { TrackPoint(latitude: $0.latitude, longitude: $0.longitude) }
            let stats = ActivityStatsCalculator.compute(points: raw)
            let trackData = try TrackPointCodec.encode(raw)
            let wpData = RouteWaypointCodec.encode(waypoints)
            try await repo.updateTrackData(id: activityId, trackData: trackData, stats: stats)
            try await repo.updateRouteWaypointsData(id: activityId, data: wpData)
            // Les arrêts .stageStop deviennent de vraies étapes (métadonnées conservées par stopWaypointId).
            let existing = (try? await repo.fetchStages(activityId: activityId)) ?? []
            let derived = Stage.derive(activityId: activityId, from: waypoints, points: raw, existing: existing)
            try await repo.replaceStages(activityId: activityId, with: derived)
            libraryRevision += 1
            // 2) Altitude/D+ enrichis EN ARRIÈRE-PLAN (non bloquant) ; mise à jour si la géométrie n'a pas changé entre-temps.
            enrichElevationInBackground(activityId: activityId, raw: raw, waypointsData: wpData)
            return true
        } catch {
            importError = "Échec du routage : \(error.localizedDescription)"
            return false
        }
    }

    private func enrichElevationInBackground(activityId: UUID, raw: [TrackPoint], waypointsData: Data?) {
        elevationTask?.cancel()
        elevationTask = Task { [weak self] in
            let enriched = await ElevationEnricher.shared.enrich(points: raw).points
            guard !Task.isCancelled, let self, let repo = self.coreDataRepository,
                  let current = try? await repo.fetchRouteWaypointsData(id: activityId), current == waypointsData else { return }
            let stats = ActivityStatsCalculator.compute(points: enriched)
            guard let td = try? TrackPointCodec.encode(enriched) else { return }
            try? await repo.updateTrackData(id: activityId, trackData: td, stats: stats)
            self.libraryRevision += 1
        }
    }

    /// Points de passage initiaux : ceux stockés, sinon dérivés du tracé (simplifié en ancrages maniables).
    func initialWaypoints(activityId: UUID) async -> [RouteWaypoint] {
        guard let repo = coreDataRepository else { return [] }
        if let data = try? await repo.fetchRouteWaypointsData(id: activityId) {
            let stored = RouteWaypointCodec.decode(data)
            if !stored.isEmpty { return stored }
        }
        guard let td = try? await repo.fetchTrackData(id: activityId),
              let pts = try? TrackPointCodec.decode(td), pts.count >= 2 else { return [] }
        return RouteWaypoint.derivedAnchors(from: pts)
    }

    /// Raccord (route + altitude IGN) du point `from` (sur le tracé) vers `to` (hors-trace), renvoyé en `[TrackPoint]`.
    func buildConnector(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [TrackPoint] {
        let profile = RouteProfile(rawValue: UserDefaults.standard.string(forKey: "routeProfile") ?? "") ?? .car
        var coords = await ConnectorRouter.route(from: from, to: to, profile: profile).coords
        if coords.count < 2 { coords = [from, to] }
        let raw = coords.map { TrackPoint(latitude: $0.latitude, longitude: $0.longitude) }
        return await ElevationEnricher.shared.enrich(points: raw).points
    }
}
