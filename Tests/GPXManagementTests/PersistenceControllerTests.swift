import XCTest
import CoreData
@testable import GPXManagement

final class PersistenceControllerTests: XCTestCase {
    func testInMemoryStoreLoads() {
        let controller = PersistenceController(inMemory: true)
        XCTAssertNotNil(controller.container.viewContext)
        XCTAssertFalse(controller.container.persistentStoreCoordinator.persistentStores.isEmpty)
    }

    func testInsertAndFetchActivity() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let activity = NSEntityDescription.insertNewObject(forEntityName: "Activity", into: context)
        activity.setValue(UUID(), forKey: "id")
        activity.setValue("Sortie test", forKey: "title")
        activity.setValue("cycling.road", forKey: "activityType")
        activity.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "startDate")
        activity.setValue(Date(timeIntervalSince1970: 1_700_003_600), forKey: "endDate")
        activity.setValue("ride.gpx", forKey: "sourceFileName")
        activity.setValue("gpx", forKey: "sourceFileFormat")
        activity.setValue("manual_import", forKey: "origin")
        activity.setValue(45_000.0, forKey: "distance")
        activity.setValue(3_600.0, forKey: "duration")
        activity.setValue(Date(), forKey: "createdAt")
        activity.setValue(Date(), forKey: "updatedAt")

        try context.save()

        let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
        let results = try context.fetch(fetch)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].value(forKey: "title") as? String, "Sortie test")
        XCTAssertEqual(results[0].value(forKey: "distance") as? Double, 45_000.0)
    }

    func testActivityDefaultValuesSatisfyCloudKitConstraints() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let activity = NSEntityDescription.insertNewObject(forEntityName: "Activity", into: context)
        activity.setValue(UUID(), forKey: "id")
        XCTAssertNoThrow(try context.save())
    }

    func testUserPreferenceDefaults() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let pref = NSEntityDescription.insertNewObject(forEntityName: "UserPreference", into: context)
        pref.setValue(UUID(), forKey: "id")
        try context.save()

        let fetch = NSFetchRequest<NSManagedObject>(entityName: "UserPreference")
        let results = try context.fetch(fetch)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].value(forKey: "defaultMapLayer") as? String, "ign_scan25")
        XCTAssertEqual(results[0].value(forKey: "unitsSystem") as? String, "metric")
        XCTAssertEqual(results[0].value(forKey: "organizationPattern") as? String, "{year}/{month}")
    }

    func testCloudKitCompatibilityNoNonOptionalWithoutDefault() throws {
        let controller = PersistenceController(inMemory: true)
        let model = controller.container.managedObjectModel

        for entity in model.entities {
            for (name, attr) in entity.attributesByName {
                if !attr.isOptional && attr.defaultValue == nil {
                    XCTFail("Entity \(entity.name ?? "?") attribute \(name) is non-optional without default — CloudKit will reject it")
                }
            }
        }
    }
}
