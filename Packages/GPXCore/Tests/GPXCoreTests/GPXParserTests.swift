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
        XCTAssertEqual(parsed.creator, "test")
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
        XCTAssertEqual(parsed.creator, "Garmin Connect")
        XCTAssertEqual(ActivitySource(rawCreator: parsed.creator), .garmin)
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
        XCTAssertNil(parsed.creator)
        XCTAssertEqual(parsed.startDate, ISO8601DateFormatter().date(from: "2025-01-01T10:00:00Z"))
        XCTAssertEqual(parsed.endDate, ISO8601DateFormatter().date(from: "2025-01-01T10:05:00Z"))
    }

    func testWaypointsExcludedFromTrack() throws {
        // Cas Scenic : waypoints départ/arrivée (sans time) AVANT la trace réelle.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Scenic Motorcycle Navigation App">
          <wpt lat="44.36" lon="6.62"><name>Start Point</name></wpt>
          <wpt lat="43.70" lon="7.24"><name>End Point</name></wpt>
          <trk><name>Track</name><trkseg>
            <trkpt lat="44.36" lon="6.62"><ele>1000</ele><time>2026-05-25T08:00:00Z</time></trkpt>
            <trkpt lat="44.30" lon="6.70"><ele>1100</ele><time>2026-05-25T09:00:00Z</time></trkpt>
            <trkpt lat="43.70" lon="7.24"><ele>10</ele><time>2026-05-25T11:00:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let parsed = try parser.parse(data: xml.data(using: .utf8)!)
        // Seuls les 3 trkpt sont retenus, pas les 2 wpt.
        XCTAssertEqual(parsed.points.count, 3)
        XCTAssertEqual(parsed.creator, "Scenic Motorcycle Navigation App")
        // Le premier/dernier point portent les vrais horodatages → durée non nulle.
        XCTAssertEqual(parsed.startDate, ISO8601DateFormatter().date(from: "2026-05-25T08:00:00Z"))
        XCTAssertEqual(parsed.endDate, ISO8601DateFormatter().date(from: "2026-05-25T11:00:00Z"))

        let stats = ActivityStatsCalculator.compute(points: parsed.points)
        XCTAssertEqual(stats.duration, 3 * 3600, accuracy: 1)
    }

    func testRoutePointsUsedWhenNoTrack() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1">
          <wpt lat="44.0" lon="6.0"><name>POI</name></wpt>
          <rte><name>R</name>
            <rtept lat="44.0" lon="6.0"></rtept>
            <rtept lat="44.1" lon="6.1"></rtept>
          </rte>
        </gpx>
        """
        let parsed = try parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(parsed.points.count, 2)
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

    /// Exports gpx.py/gpxpy : l'URI de namespace sert de nom de balise (<http://…:hr>) → XML invalide.
    /// Le blindage répare ces noms et récupère le tracé (FC/cadence préservées).
    func testParseRepairsNamespaceUriTagNames() throws {
        let ns = "http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="45.0" lon="6.0">
              <ele>2000.0</ele>
              <time>2026-04-11T04:21:56.761000Z</time>
              <extensions>
                <\(ns):TrackPointExtension>
                  <\(ns):hr>91</\(ns):hr>
                  <\(ns):cad>20</\(ns):cad>
                </\(ns):TrackPointExtension>
              </extensions>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        let parsed = try parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(parsed.points.count, 1)
        XCTAssertEqual(parsed.points.first?.latitude, 45.0)
        XCTAssertEqual(parsed.points.first?.altitude, 2000.0)
        XCTAssertEqual(parsed.points.first?.heartRate, 91)   // extension préservée après réparation
        XCTAssertEqual(parsed.points.first?.cadence, 20)
        XCTAssertNotNil(parsed.points.first?.timestamp)
    }
}
