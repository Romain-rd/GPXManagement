import CoreData
import Foundation

public final class PersistenceController {
    nonisolated(unsafe) public static let shared = PersistenceController()

    nonisolated(unsafe) public static let preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()

    public let container: NSPersistentCloudKitContainer

    public init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "GPXManagement")

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("PersistenceController: no persistent store description")
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
            description.cloudKitContainerOptions = nil
        } else {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.demoustier.GPXManagement"
            )
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("PersistenceController: failed to load store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }
}
