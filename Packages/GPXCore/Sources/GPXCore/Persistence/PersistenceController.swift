import CoreData
import Foundation

public final class PersistenceController {
    nonisolated(unsafe) public static let shared = PersistenceController()

    nonisolated(unsafe) public static let preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()

    public let container: NSPersistentCloudKitContainer

    /// Store CloudKit privé (les données propres à l'utilisateur). Renseigné après chargement.
    public private(set) var privateStore: NSPersistentStore?
    /// Store CloudKit partagé (les parcours reçus d'autres utilisateurs via CKShare). Renseigné après chargement.
    public private(set) var sharedStore: NSPersistentStore?

    public init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "GPXManagement")

        guard let privateDescription = container.persistentStoreDescriptions.first else {
            fatalError("PersistenceController: no persistent store description")
        }

        if inMemory {
            privateDescription.url = URL(fileURLWithPath: "/dev/null")
            privateDescription.cloudKitContainerOptions = nil
        } else {
            // Store privé : base CloudKit privée de l'utilisateur (sync entre ses propres appareils).
            let privateOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.demoustier.GPXManagement"
            )
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions
            configureSyncOptions(privateDescription)

            // Store partagé : reçoit les parcours qu'un autre utilisateur partage via CKShare.
            guard let privateURL = privateDescription.url else {
                fatalError("PersistenceController: private store has no URL")
            }
            let sharedURL = privateURL.deletingLastPathComponent()
                .appendingPathComponent("GPXManagement-shared.sqlite")
            let sharedDescription = NSPersistentStoreDescription(url: sharedURL)
            sharedDescription.configuration = privateDescription.configuration
            let sharedOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.demoustier.GPXManagement"
            )
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions
            configureSyncOptions(sharedDescription)
            container.persistentStoreDescriptions.append(sharedDescription)
        }

        container.loadPersistentStores { [self] description, error in
            if let error {
                fatalError("PersistenceController: failed to load store: \(error)")
            }
            guard let url = description.url else { return }
            if let store = container.persistentStoreCoordinator.persistentStore(for: url) {
                if description.cloudKitContainerOptions?.databaseScope == .shared {
                    sharedStore = store
                } else {
                    privateStore = store
                }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    private func configureSyncOptions(_ description: NSPersistentStoreDescription) {
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        // Borne le journal WAL : les checkpoints TRUNCATE échouent souvent (mirroring CloudKit
        // occupé → « Database busy ») et le WAL enflait sans limite (observé à 378 Mo).
        description.setOption(["journal_size_limit": "67108864"] as NSDictionary, forKey: NSSQLitePragmasOption)
    }
}
