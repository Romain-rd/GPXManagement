import AppKit
import CloudKit
import CoreData
import GPXCore

/// Partage d'un parcours avec un autre utilisateur de l'app via CloudKit (CKShare). Crée (ou récupère)
/// le partage du parcours — étapes incluses grâce à la relation `Activity.stages` — et présente l'UI
/// système macOS pour diffuser le lien d'invitation.
@MainActor
final class ParcoursSharingController: NSObject {
    static let shared = ParcoursSharingController()

    enum ShareError: LocalizedError {
        case notFound
        case noWindow
        case noShareURL

        var errorDescription: String? {
            switch self {
            case .notFound:    return "Parcours introuvable."
            case .noWindow:    return "Aucune fenêtre disponible pour présenter le partage."
            case .noShareURL:  return "Le lien de partage n'a pas pu être créé. Vérifiez votre connexion iCloud puis réessayez."
            }
        }
    }

    var lastError: String?

    private var persistence: PersistenceController { AppServices.shared.persistence }

    func shareParcours(activityId: UUID) async {
        lastError = nil
        let container = persistence.container
        let context = container.viewContext
        guard let activity = fetchActivity(activityId, in: context) else {
            present(error: ShareError.notFound); return
        }
        linkOrphanStages(to: activity, activityId: activityId, in: context)

        // Partage déjà existant : on rouvre l'UI dessus plutôt que d'en recréer un.
        if let existing = (try? container.fetchShares(matching: [activity.objectID]))?[activity.objectID] {
            present(share: existing)
            return
        }

        do {
            let share = try await makeShare(for: activity, container: container)
            share[CKShare.SystemFieldKey.title] = (activity.value(forKey: "title") as? String) as? CKRecordValueProtocol
            // Lien ouvert : tout destinataire disposant du lien peut accepter et collaborer sur le parcours.
            share.publicPermission = .readWrite
            if let store = persistence.privateStore {
                try? await persistUpdated(share, in: store, container: container)
            }
            present(share: share)
        } catch {
            present(error: error)
        }
    }

    // MARK: - CloudKit

    private func makeShare(for activity: NSManagedObject, container: NSPersistentCloudKitContainer) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            container.share([activity], to: nil) { _, share, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let share {
                    continuation.resume(returning: share)
                } else {
                    continuation.resume(throwing: ShareError.notFound)
                }
            }
        }
    }

    private func persistUpdated(_ share: CKShare, in store: NSPersistentStore, container: NSPersistentCloudKitContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.persistUpdatedShare(share, in: store) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    // MARK: - Présentation

    private func present(share: CKShare) {
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            present(error: ShareError.noWindow); return
        }
        guard let url = share.url else {
            present(error: ShareError.noShareURL); return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    private func present(error: Error) {
        lastError = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "Partage impossible"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Core Data

    private func fetchActivity(_ id: UUID, in context: NSManagedObjectContext) -> NSManagedObject? {
        let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
        fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetch.fetchLimit = 1
        return (try? context.fetch(fetch))?.first
    }

    /// Rattache à l'activité les étapes créées avant l'introduction de la relation `Activity.stages`
    /// (parcours existants), pour qu'elles soient incluses dans le partage.
    private func linkOrphanStages(to activity: NSManagedObject, activityId: UUID, in context: NSManagedObjectContext) {
        let fetch = NSFetchRequest<NSManagedObject>(entityName: "Stage")
        fetch.predicate = NSPredicate(format: "activityId == %@ AND activity == nil", activityId as CVarArg)
        guard let orphans = try? context.fetch(fetch), !orphans.isEmpty else { return }
        for stage in orphans { stage.setValue(activity, forKey: "activity") }
        try? context.save()
    }
}
