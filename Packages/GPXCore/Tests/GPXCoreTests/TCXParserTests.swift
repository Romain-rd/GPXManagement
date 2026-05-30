import XCTest
@testable import GPXCore

final class TCXParserTests: XCTestCase {
    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <TrainingCenterDatabase><Activities><Activity Sport="Biking">
      <Id>2025-07-14T08:00:00Z</Id>
      <Lap StartTime="2025-07-14T08:00:00Z"><Track>
        <Trackpoint>
          <Time>2025-07-14T08:00:00Z</Time>
          <Position><LatitudeDegrees>43.700</LatitudeDegrees><LongitudeDegrees>7.262</LongitudeDegrees></Position>
          <AltitudeMeters>50.0</AltitudeMeters>
          <HeartRateBpm><Value>110</Value></HeartRateBpm>
          <Cadence>85</Cadence>
        </Trackpoint>
        <Trackpoint>
          <Time>2025-07-14T08:10:00Z</Time>
          <Position><LatitudeDegrees>43.715</LatitudeDegrees><LongitudeDegrees>7.270</LongitudeDegrees></Position>
          <AltitudeMeters>120.0</AltitudeMeters>
          <HeartRateBpm><Value>140</Value></HeartRateBpm>
          <Extensions><TPX><Watts>220</Watts></TPX></Extensions>
        </Trackpoint>
        <Trackpoint>
          <Time>2025-07-14T08:20:00Z</Time>
        </Trackpoint>
      </Track></Lap>
      <Creator xsi:type="Device_t"><Name>Garmin Edge 530</Name></Creator>
    </Activity></Activities>
    <Author xsi:type="Application_t"><Name>Strava</Name></Author>
    </TrainingCenterDatabase>
    """

    func testParsesTrackpointsAndSensors() throws {
        let parsed = try TCXParser().parse(data: Data(sample.utf8))

        // Le 3e point sans position est ignoré.
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.activityHint, "Biking")
        // Le <Creator> (appareil) prime sur l'<Author> (application d'export).
        XCTAssertEqual(parsed.creator, "Garmin Edge 530")
        XCTAssertEqual(ActivitySource(rawCreator: parsed.creator), .garmin)

        let first = parsed.points[0]
        XCTAssertEqual(first.latitude, 43.700, accuracy: 1e-6)
        XCTAssertEqual(first.longitude, 7.262, accuracy: 1e-6)
        XCTAssertEqual(first.altitude, 50.0)
        XCTAssertEqual(first.heartRate, 110)
        XCTAssertEqual(first.cadence, 85)
        XCTAssertNil(first.power)

        let second = parsed.points[1]
        XCTAssertEqual(second.power, 220)
        XCTAssertEqual(second.heartRate, 140)

        XCTAssertNotNil(parsed.startDate)
        XCTAssertNotNil(parsed.endDate)
        XCTAssertEqual(parsed.startDate, parsed.points.first?.timestamp)
    }

    func testSportMapsToActivityType() {
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "Biking", fileFormat: .tcx), .cyclingRoad)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: "Running", fileFormat: .tcx), .walking)
        XCTAssertNil(ActivityTypeDetector.detect(hint: "Other", fileFormat: .tcx))
    }

    func testEmptyDocumentThrows() {
        XCTAssertThrowsError(try TCXParser().parse(data: Data("<TrainingCenterDatabase/>".utf8)))
    }
}
