import XCTest
@testable import GPXCore

final class ActivityTypeDetectorTests: XCTestCase {
    func testGPXCyclingHints() {
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "cycling", fileFormat: .gpx), .cyclingRoad)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "Ride", fileFormat: .gpx), .cyclingRoad)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "MountainBiking", fileFormat: .gpx), .cyclingMTB)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "mountain-biking", fileFormat: .gpx), .cyclingMTB)
    }

    func testGPXSkiingHints() {
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "AlpineSki", fileFormat: .gpx), .skiingAlpine)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "BackcountrySki", fileFormat: .gpx), .skiingTouring)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "ski_touring", fileFormat: .gpx), .skiingTouring)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "ski-rando", fileFormat: .gpx), .skiingTouring)
    }

    func testGPXOther() {
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "Hiking", fileFormat: .gpx), .hiking)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "Motorcycling", fileFormat: .gpx), .motorcycle)
    }

    func testFITSports() {
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "cycling", fileFormat: .fit), .cyclingRoad)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "mountain_biking", fileFormat: .fit), .cyclingMTB)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "alpine_skiing", fileFormat: .fit), .skiingAlpine)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "cross_country_skiing", fileFormat: .fit), .skiingNordic)
    }

    func testUnknownHintReturnsNil() {
        XCTAssertNil(ActivityTypeDetector.detect(hint: "underwater_basket_weaving", fileFormat: .gpx))
        XCTAssertNil(ActivityTypeDetector.detect(hint: nil, fileFormat: .gpx))
        XCTAssertNil(ActivityTypeDetector.detect(hint: "", fileFormat: .fit))
    }

    func testRedpointSourceDefaultsToClimbing() {
        // Le creator Redpoint (GPX ou FIT) → source Redpoint → escalade par défaut.
        XCTAssertEqual(ActivitySource(rawCreator: "Redpoint with Barometer"), .redpoint)
        XCTAssertEqual(ActivitySource(rawCreator: "Redpoint Climbing Tracker App with Barometer"), .redpoint)
        XCTAssertEqual(ActivityTypeDetector.detect(source: .redpoint), .climbing)
    }
}
