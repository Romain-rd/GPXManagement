import XCTest
import CoreData
import GPXCore
@testable import GPXManagement

final class CoreDataActivityRepositoryTests: XCTestCase {
    private var persistence: PersistenceController!
    private var repository: CoreDataActivityRepository!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
        repository = CoreDataActivityRepository(persistence: persistence)
    }

    private func samplePayload(id: UUID = UUID(), title: String = "Sortie test", startDate: Date = Date(timeIntervalSince1970: 1_700_000_000), distance: Double = 45_000, stravaId: String? = nil) -> ActivityCreationPayload {
        let stats = ActivityStats(
            distance: distance,
            duration: 3600,
            movingDuration: 3500,
            elevationGain: 500,
            elevationLoss: 480,
            avgSpeed: 12.5,
            maxSpeed: 18.0,
            avgHeartRate: 145,
            maxHeartRate: 168,
            boundingBox: BoundingBox(minLatitude: 45.0, maxLatitude: 45.5, minLongitude: 6.0, maxLongitude: 6.5)
        )
        return ActivityCreationPayload(
            id: id,
            title: title,
            activityType: .cyclingRoad,
            origin: .manualImport,
            sourceFileName: "2025/07/test.gpx",
            sourceFileFormat: .gpx,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            stats: stats,
            trackData: Data([0x47, 0x50, 0x58, 0x50]),
            fileSHA256: "abc123",
            stravaId: stravaId
        )
    }

    func testFindActivityByStravaId() async throws {
        let id = UUID()
        try await repository.createActivity(samplePayload(id: id, stravaId: "123456789"))
        let found = try await repository.findActivity(stravaId: "123456789")
        XCTAssertEqual(found, id)
        let missing = try await repository.findActivity(stravaId: "999")
        XCTAssertNil(missing)
    }

    func testStravaActivityIdFromFilename() {
        XCTAssertEqual(AppServices.stravaActivityId(fromArchiveFile: URL(fileURLWithPath: "/tmp/activities/123456.gpx")), "123456")
        XCTAssertEqual(AppServices.stravaActivityId(fromArchiveFile: URL(fileURLWithPath: "/tmp/987654.fit")), "987654")
        XCTAssertNil(AppServices.stravaActivityId(fromArchiveFile: URL(fileURLWithPath: "/tmp/route.gpx")))
    }

    func testCreateAndFetch() async throws {
        let payload = samplePayload()
        try await repository.createActivity(payload)

        let context = persistence.container.viewContext
        let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
        let results = try context.fetch(fetch)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].value(forKey: "title") as? String, "Sortie test")
        XCTAssertEqual(results[0].value(forKey: "distance") as? Double, 45_000)
        XCTAssertEqual(results[0].value(forKey: "activityType") as? String, "cycling.road")
        XCTAssertEqual(results[0].value(forKey: "origin") as? String, "manual_import")
    }

    func testFindDuplicateNoMatch() async throws {
        let result = try await repository.findDuplicate(sha256: "any", startDate: Date(), distance: 10_000)
        XCTAssertNil(result)
    }

    func testFindDuplicateMatchesWithinTolerance() async throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.createActivity(samplePayload(id: id, startDate: date, distance: 10_000))

        let close = try await repository.findDuplicate(sha256: "abc", startDate: date.addingTimeInterval(1), distance: 10_050)
        XCTAssertEqual(close, id)

        let tooFar = try await repository.findDuplicate(sha256: "abc", startDate: date.addingTimeInterval(10), distance: 10_000)
        XCTAssertNil(tooFar)

        let differentDistance = try await repository.findDuplicate(sha256: "abc", startDate: date, distance: 12_000)
        XCTAssertNil(differentDistance)
    }
}
