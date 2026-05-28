import XCTest
@testable import GPXCore

final class AppleHealthImporterTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AppleHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("workout-routes"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func writeExportXML(_ content: String) throws {
        try content.write(to: tempRoot.appendingPathComponent("export.xml"), atomically: true, encoding: .utf8)
    }

    private func writeRouteGPX(name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("workout-routes/\(name)")
        let body = """
        <?xml version="1.0"?>
        <gpx version="1.1"><trk><trkseg>
          <trkpt lat="45.0" lon="6.0"><time>2025-07-14T08:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testScanSingleCyclingWorkout() async throws {
        _ = try writeRouteGPX(name: "route_2025-07-14_8.30am.gpx")
        try writeExportXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="fr_FR">
          <Workout workoutActivityType="HKWorkoutActivityTypeCycling"
                   duration="60.0" durationUnit="min"
                   totalDistance="45.0" totalDistanceUnit="km"
                   startDate="2025-07-14 08:00:00 +0200"
                   endDate="2025-07-14 09:00:00 +0200">
            <WorkoutRoute>
              <FileReference path="/workout-routes/route_2025-07-14_8.30am.gpx"/>
            </WorkoutRoute>
          </Workout>
        </HealthData>
        """)

        let importer = AppleHealthImporter()
        let workouts = try await importer.scan(exportRoot: tempRoot)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].hkActivityType, "HKWorkoutActivityTypeCycling")
        XCTAssertEqual(workouts[0].suggestedActivityType, .cyclingRoad)
        XCTAssertEqual(try XCTUnwrap(workouts[0].totalDistanceMeters), 45_000, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(workouts[0].durationSeconds), 3_600, accuracy: 0.5)
        XCTAssertNotNil(workouts[0].gpxFileURL)
        XCTAssertTrue(workouts[0].gpxFileURL?.lastPathComponent.contains("route_2025-07-14") ?? false)
    }

    func testScanMultipleWorkoutsAndSkipUnknownActivity() async throws {
        _ = try writeRouteGPX(name: "route_a.gpx")
        _ = try writeRouteGPX(name: "route_b.gpx")
        try writeExportXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
          <Workout workoutActivityType="HKWorkoutActivityTypeHiking"
                   duration="120.0" durationUnit="min"
                   totalDistance="8.5" totalDistanceUnit="km"
                   startDate="2025-08-10 09:00:00 +0200"
                   endDate="2025-08-10 11:00:00 +0200">
            <WorkoutRoute>
              <FileReference path="/workout-routes/route_a.gpx"/>
            </WorkoutRoute>
          </Workout>
          <Workout workoutActivityType="HKWorkoutActivityTypeRunning"
                   duration="30.0" durationUnit="min"
                   totalDistance="5.0" totalDistanceUnit="km"
                   startDate="2025-08-11 08:00:00 +0200"
                   endDate="2025-08-11 08:30:00 +0200">
            <WorkoutRoute>
              <FileReference path="/workout-routes/route_b.gpx"/>
            </WorkoutRoute>
          </Workout>
        </HealthData>
        """)

        let importer = AppleHealthImporter()
        let workouts = try await importer.scan(exportRoot: tempRoot)
        XCTAssertEqual(workouts.count, 2)
        XCTAssertEqual(workouts[0].suggestedActivityType, .hiking)
        XCTAssertNil(workouts[1].suggestedActivityType)
    }

    func testMissingFileReferenceStillReturnsWorkout() async throws {
        try writeExportXML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
          <Workout workoutActivityType="HKWorkoutActivityTypeCycling"
                   duration="60.0" durationUnit="min"
                   totalDistance="20.0" totalDistanceUnit="km"
                   startDate="2025-09-01 10:00:00 +0200"
                   endDate="2025-09-01 11:00:00 +0200">
          </Workout>
        </HealthData>
        """)
        let importer = AppleHealthImporter()
        let workouts = try await importer.scan(exportRoot: tempRoot)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertNil(workouts[0].gpxFileURL)
    }

    func testMissingExportXMLRejected() async throws {
        let importer = AppleHealthImporter()
        do {
            _ = try await importer.scan(exportRoot: tempRoot.appendingPathComponent("nope"))
            XCTFail("expected throw")
        } catch let error as AppleHealthImportError {
            XCTAssertEqual(error, .exportXMLNotFound)
        }
    }

    func testNestedAppleHealthExportFolder() async throws {
        let nested = tempRoot.appendingPathComponent("apple_health_export")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("workout-routes"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <HealthData>
          <Workout workoutActivityType="HKWorkoutActivityTypeWalking"
                   duration="20.0" durationUnit="min"
                   totalDistance="1.5" totalDistanceUnit="km"
                   startDate="2025-10-01 12:00:00 +0200"
                   endDate="2025-10-01 12:20:00 +0200">
          </Workout>
        </HealthData>
        """.write(to: nested.appendingPathComponent("export.xml"), atomically: true, encoding: .utf8)

        let importer = AppleHealthImporter()
        let workouts = try await importer.scan(exportRoot: tempRoot)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].suggestedActivityType, .walking)
    }

    func testHintsAppliedDuringImport() async throws {
        let gpxURL = try writeRouteGPX(name: "route_h.gpx")
        try writeExportXML("")

        let storageTemp = tempRoot.appendingPathComponent("storage", isDirectory: true)
        let container = ICloudContainer(identifier: "test", overrideRoot: storageTemp)
        let storage = FileStorageService(container: container, pattern: .default)
        let repo = MemoryRepository()
        let importer = ImportService(storage: storage, repository: repo)

        let proposal = try await importer.prepareImport(from: gpxURL, hintedActivityType: .skiingTouring, hintedTitle: "Course du col")
        XCTAssertEqual(proposal.suggestedActivityType, .skiingTouring)
        XCTAssertEqual(proposal.suggestedTitle, "Course du col")
    }
}

private actor MemoryRepository: ActivityRepository {
    func findDuplicate(sha256: String, startDate: Date, distance: Double) async throws -> UUID? { nil }
    func createActivity(_ payload: ActivityCreationPayload) async throws { }
}
