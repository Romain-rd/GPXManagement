import XCTest
@testable import GPXCore

final class ActivitySourceTests: XCTestCase {
    func testCategorizationFromCreator() {
        XCTAssertEqual(ActivitySource(rawCreator: "StravaGPX"), .strava)
        XCTAssertEqual(ActivitySource(rawCreator: "Garmin Connect 1.2"), .garmin)
        XCTAssertEqual(ActivitySource(rawCreator: "komoot"), .komoot)
        XCTAssertEqual(ActivitySource(rawCreator: "WAHOO ELEMNT"), .wahoo)
        XCTAssertEqual(ActivitySource(rawCreator: "Hammerhead Karoo"), .hammerhead)
        XCTAssertEqual(ActivitySource(rawCreator: "Apple Watch"), .appleHealth)
    }

    func testUnknownAndOther() {
        XCTAssertEqual(ActivitySource(rawCreator: nil), .unknown)
        XCTAssertEqual(ActivitySource(rawCreator: "   "), .unknown)
        XCTAssertEqual(ActivitySource(rawCreator: "Acme Tracker 9"), .other("Acme Tracker 9"))
    }

    func testDisplayNamePreservesRawForOther() {
        XCTAssertEqual(ActivitySource(rawCreator: "Acme Tracker").displayName, "Acme Tracker")
        XCTAssertEqual(ActivitySource.unknown.displayName, "Inconnue")
    }

    func testResolveSourceAppKeepsRealCreator() {
        XCTAssertEqual(
            ImportService.resolveSourceApp(parsedCreator: "Garmin Connect", origin: .strava),
            "Garmin Connect"
        )
    }

    func testResolveSourceAppFallsBackToStravaForInternalWriter() {
        XCTAssertEqual(
            ImportService.resolveSourceApp(parsedCreator: "GPXManagement", origin: .strava),
            "Strava"
        )
        XCTAssertEqual(
            ImportService.resolveSourceApp(parsedCreator: nil, origin: .strava),
            "Strava"
        )
    }

    func testResolveSourceAppNilForManualWithoutCreator() {
        XCTAssertNil(ImportService.resolveSourceApp(parsedCreator: nil, origin: .manualImport))
        XCTAssertNil(ImportService.resolveSourceApp(parsedCreator: "GPXManagement", origin: .manualImport))
    }

    func testScenicSourceAndMotorcycleDetection() {
        XCTAssertEqual(ActivitySource(rawCreator: "Scenic"), .scenic)
        XCTAssertEqual(ActivitySource(rawCreator: "Scenic - Motorcycle Navigation"), .scenic)
        XCTAssertEqual(ActivityTypeDetector.detect(source: .scenic), .motorcycle)
        XCTAssertNil(ActivityTypeDetector.detect(source: .garmin))
    }
}
