import Foundation
import GPXCore

// MARK: - Réorganisation des fichiers selon le modèle d'organisation

extension AppServices {
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
}
