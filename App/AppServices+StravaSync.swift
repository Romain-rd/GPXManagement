import Foundation
import GPXCore
import GPXStrava

// MARK: - Synchronisation Strava (liste, streams, import)

extension AppServices {
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
            CloudPreferences.shared.markStravaSyncedNow()
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
}
