import XCTest
@testable import GPXCore

final class GPXParserTests: XCTestCase {
    private let parser = GPXParser()

    func testParseMinimalGPX10() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.0" creator="test">
          <trk>
            <name>Test Track</name>
            <trkseg>
              <trkpt lat="45.0" lon="6.0"><ele>100.0</ele><time>2025-07-14T08:00:00Z</time></trkpt>
              <trkpt lat="45.001" lon="6.001"><ele>102.0</ele><time>2025-07-14T08:00:10Z</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let parsed = try parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(parsed.name, "Test Track")
        XCTAssertNil(parsed.activityHint)
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[0].latitude, 45.0)
        XCTAssertEqual(parsed.points[0].altitude, 100.0)
        XCTAssertEqual(parsed.startDate, ISO8601DateFormatter().date(from: "2025-07-14T08:00:00Z"))
    }

    func testParseGPX11WithTypeAndExtensions() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Garmin Connect"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <trk>
            <name>Tour des Alpes</name>
            <type>cycling</type>
            <trkseg>
              <trkpt lat="45.5" lon="6.5">
                <ele>1200.5</ele>
                <time>2024-08-10T07:30:00.500Z</time>
                <extensions>
                  <gpxtpx:TrackPointExtension>
                    <gpxtpx:hr>145</gpxtpx:hr>
                    <gpxtpx:cad>82</gpxtpx:cad>
                  </gpxtpx:TrackPointExtension>
                </extensions>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let parsed = try parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(parsed.name, "Tour des Alpes")
        XCTAssertEqual(parsed.activityHint, "cycling")
        XCTAssertEqual(parsed.points.count, 1)
        XCTAssertEqual(parsed.points[0].heartRate, 145)
        XCTAssertEqual(parsed.points[0].cadence, 82)
        XCTAssertEqual(parsed.points[0].altitude, 1200.5)
    }

    func testParseMultiSegment() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1">
          <trk>
            <name>Multi</name>
            <trkseg>
              <trkpt lat="45.0" lon="6.0"><time>2025-01-01T10:00:00Z</time></trkpt>
            </trkseg>
            <trkseg>
              <trkpt lat="45.1" lon="6.1"><time>2025-01-01T10:05:00Z</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let parsed = try parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.startDate, ISO8601DateFormatter().date(from: "2025-01-01T10:00:00Z"))
        XCTAssertEqual(parsed.endDate, ISO8601DateFormatter().date(from: "2025-01-01T10:05:00Z"))
    }

    func testParseRejectsEmpty() {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1"><trk><name>Empty</name></trk></gpx>
        """
        XCTAssertThrowsError(try parser.parse(data: xml.data(using: .utf8)!)) { error in
            XCTAssertEqual(error as? GPXParseError, .noTracks)
        }
    }

    func testParseRejectsMalformedCoordinates() {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1">
          <trk><trkseg>
            <trkpt lat="bad" lon="6.0"></trkpt>
          </trkseg></trk>
        </gpx>
        """
        XCTAssertThrowsError(try parser.parse(data: xml.data(using: .utf8)!))
    }

    func testParseRejectsInvalidXML() {
        let xml = "not xml at all"
        XCTAssertThrowsError(try parser.parse(data: xml.data(using: .utf8)!))
    }
}
