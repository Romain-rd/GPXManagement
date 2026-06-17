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

/// Calcule un raccord piéton entre deux points (du tracé vers un point hors-trace).
/// Nommage de points via OpenStreetMap : cols/sommets (Overpass, une requête groupée) puis lieu habité (Nominatim).
enum OSMNaming {
    struct NamedPoint { let coordinate: CLLocationCoordinate2D; let name: String }

    /// Cols, sommets et lieux-dits remarquables à proximité de l'ensemble des points (une seule requête Overpass).
    static func passes(near coords: [CLLocationCoordinate2D]) async -> [NamedPoint] {
        guard !coords.isEmpty else { return [] }
        let around = coords.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let query = "[out:json][timeout:25];(" +
            "node(around:800,\(around))[mountain_pass];" +
            "node(around:800,\(around))[natural=saddle];" +
            "node(around:600,\(around))[natural=peak][name];" +
            ");out tags;"
        struct Resp: Decodable { let elements: [El]; struct El: Decodable { let lat: Double?; let lon: Double?; let tags: [String: String]? } }
        // Plusieurs miroirs publics : leur disponibilité est inégale, on bascule au premier qui répond.
        let hosts = [
            "https://overpass-api.de/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"
        ]
        for host in hosts {
            guard let url = URL(string: host) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(Resp.self, from: data) else { continue }
            return parsed.elements.compactMap { e in
                guard let lat = e.lat, let lon = e.lon, let name = e.tags?["name"], !name.isEmpty else { return nil }
                return NamedPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), name: name)
            }
        }
        return []
    }

    /// Le nom le plus proche d'une coordonnée dans une liste, si sous le seuil (mètres).
    static func nearestName(_ points: [NamedPoint], to c: CLLocationCoordinate2D, within meters: Double) -> String? {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var best: (Double, String)?
        for p in points {
            let d = CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude).distance(from: here)
            if d <= meters, best == nil || d < best!.0 { best = (d, p.name) }
        }
        return best?.1
    }

    /// Lieu habité (ville/village) via Nominatim — repli quand aucun col/sommet n'est proche.
    static func place(_ c: CLLocationCoordinate2D) async -> String? {
        var comps = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: String(format: "%.6f", c.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", c.longitude)),
            URLQueryItem(name: "zoom", value: "14"),
            URLQueryItem(name: "addressdetails", value: "1")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("GPXManagement/1.0 (rd_claude@demoustier.com)", forHTTPHeaderField: "User-Agent")
        struct Resp: Decodable { let name: String?; let address: [String: String]? }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return nil }
        let a = r.address ?? [:]
        for key in ["village", "town", "city", "hamlet", "municipality", "suburb", "locality"] {
            if let v = a[key], !v.isEmpty { return v }
        }
        if let n = r.name, !n.isEmpty { return n }
        return a["county"]
    }
}

enum ConnectorRouter {
    enum Engine: String, CaseIterable { case mapkit, trail, car, line }

    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, engine: Engine) async -> [CLLocationCoordinate2D] {
        switch engine {
        case .line:
            return [from, to]
        case .mapkit:
            // MapKit refuse les segments très longs / transfrontaliers : repli BRouter avant la ligne droite.
            if let m = await mapkitRoute(from: from, to: to, transportType: .walking) { return m }
            if let b = await trailRoute(from: from, to: to, profile: "trekking") { return b }
            return [from, to]
        case .car:
            if let m = await mapkitRoute(from: from, to: to, transportType: .automobile) { return m }
            if let b = await trailRoute(from: from, to: to, profile: "car-fast") { return b }
            return [from, to]
        case .trail:
            if let t = await trailRoute(from: from, to: to, profile: "hiking-mountain") { return t }
            if let m = await mapkitRoute(from: from, to: to, transportType: .walking) { return m }
            return [from, to]
        }
    }

    private static func mapkitRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, transportType: MKDirectionsTransportType) async -> [CLLocationCoordinate2D]? {
        // MKDirections est limité en débit (throttling) : on réessaie avec un délai croissant.
        for attempt in 0..<4 {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            request.transportType = transportType
            do {
                let response = try await MKDirections(request: request).calculate()
                guard let polyline = response.routes.first?.polyline else { return nil }
                var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
                polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
                return coords.filter { CLLocationCoordinate2DIsValid($0) }
            } catch {
                let code = (error as NSError).code
                // MKError.loadingThrottled (3) / serverFailure : on attend puis on réessaie.
                guard attempt < 3, code == MKError.loadingThrottled.rawValue || code == MKError.serverFailure.rawValue else { return nil }
                try? await Task.sleep(nanoseconds: UInt64(0.7 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        return nil
    }

    private static func trailRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: String = "hiking-mountain") async -> [CLLocationCoordinate2D]? {
        // BRouter (serveur public) → GeoJSON [[lon,lat,(ele)],…]. Pas de limite de distance, transfrontalier.
        let urlStr = "https://brouter.de/brouter?lonlats=\(from.longitude),\(from.latitude)|\(to.longitude),\(to.latitude)&profile=\(profile)&alternativeidx=0&format=geojson"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct GeoJSON: Decodable {
            let features: [Feature]
            struct Feature: Decodable { let geometry: Geometry }
            struct Geometry: Decodable { let coordinates: [[Double]] }
        }
        guard let gj = try? JSONDecoder().decode(GeoJSON.self, from: data),
              let coords = gj.features.first?.geometry.coordinates, coords.count >= 2 else { return nil }
        return coords.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
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
                let engine = ConnectorRouter.Engine(rawValue: UserDefaults.standard.string(forKey: "connectorEngine") ?? "") ?? .mapkit
                for i in 0..<(waypoints.count - 1) {
                    if i > 0, engine == .mapkit || engine == .car { try? await Task.sleep(nanoseconds: 150_000_000) }
                    let a = CLLocationCoordinate2D(latitude: waypoints[i].latitude, longitude: waypoints[i].longitude)
                    let b = CLLocationCoordinate2D(latitude: waypoints[i + 1].latitude, longitude: waypoints[i + 1].longitude)
                    var seg = await ConnectorRouter.route(from: a, to: b, engine: engine)
                    if seg.count < 2 { seg = [a, b] }
                    if !coords.isEmpty { seg.removeFirst() }
                    coords.append(contentsOf: seg)
                }
            }
            guard coords.count >= 2 else { importError = "Itinéraire vide."; return false }
            let raw = coords.map { TrackPoint(latitude: $0.latitude, longitude: $0.longitude) }
            let enriched = await ElevationEnricher.shared.enrich(points: raw).points
            let stats = ActivityStatsCalculator.compute(points: enriched)
            let trackData = try TrackPointCodec.encode(enriched)
            try await repo.updateTrackData(id: activityId, trackData: trackData, stats: stats)
            try await repo.updateRouteWaypointsData(id: activityId, data: RouteWaypointCodec.encode(waypoints))
            libraryRevision += 1
            return true
        } catch {
            importError = "Échec du routage : \(error.localizedDescription)"
            return false
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
        let engine = ConnectorRouter.Engine(rawValue: UserDefaults.standard.string(forKey: "connectorEngine") ?? "") ?? .mapkit
        var coords = await ConnectorRouter.route(from: from, to: to, engine: engine)
        if coords.count < 2 { coords = [from, to] }
        let raw = coords.map { TrackPoint(latitude: $0.latitude, longitude: $0.longitude) }
        return await ElevationEnricher.shared.enrich(points: raw).points
    }
}
