import XCTest
@testable import GPXCore

final class GPXWaypointPreservationTests: XCTestCase {
    private let gpxWithWaypoints = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="Komoot" xmlns="http://www.topografix.com/GPX/1/1">
      <wpt lat="45.1000" lon="6.1000"><name>Départ</name><type>start</type></wpt>
      <wpt lat="45.2000" lon="6.2000"><name>Col du Galibier</name><sym>Summit</sym></wpt>
      <wpt lat="45.3000" lon="6.3000"></wpt>
      <trk>
        <name>Étape 1</name>
        <type>hiking</type>
        <trkseg>
          <trkpt lat="45.1000" lon="6.1000"><ele>1000</ele></trkpt>
          <trkpt lat="45.2000" lon="6.2000"><ele>2640</ele></trkpt>
          <trkpt lat="45.3000" lon="6.3000"><ele>1500</ele></trkpt>
        </trkseg>
      </trk>
    </gpx>
    """

    func testParserKeepsWaypointsSeparateFromTrack() throws {
        let parsed = try GPXParser().parse(data: Data(gpxWithWaypoints.utf8))
        XCTAssertEqual(parsed.points.count, 3, "Les <wpt> ne doivent pas polluer le tracé")
        XCTAssertEqual(parsed.waypoints.count, 3)
        XCTAssertEqual(parsed.waypoints[0].name, "Départ")
        XCTAssertEqual(parsed.waypoints[0].type, "start")
        XCTAssertEqual(parsed.waypoints[1].name, "Col du Galibier")
        XCTAssertEqual(parsed.waypoints[1].symbol, "Summit")
        XCTAssertNil(parsed.waypoints[2].name, "Un <wpt> sans nom reste capturé")
        XCTAssertEqual(parsed.waypoints[2].latitude, 45.3, accuracy: 1e-6)
    }

    func testTrackNameNotShadowedByWaypointName() throws {
        let parsed = try GPXParser().parse(data: Data(gpxWithWaypoints.utf8))
        XCTAssertEqual(parsed.name, "Étape 1")
        XCTAssertEqual(parsed.activityHint, "hiking")
    }

    func testWriterEmitsWptForPoiAndStageStopOnly() throws {
        let pts = [TrackPoint(latitude: 45, longitude: 6, altitude: 100)]
        let waypoints = [
            RouteWaypoint(latitude: 45.1, longitude: 6.1, name: "Refuge", role: .stageStop),
            RouteWaypoint(latitude: 45.2, longitude: 6.2, name: "Col", role: .poi),
            RouteWaypoint(latitude: 45.15, longitude: 6.15, role: .shaping)
        ]
        let xml = String(data: try GPXWriter.write(name: "P", activityType: .hiking, points: pts, waypoints: waypoints), encoding: .utf8)!
        XCTAssertEqual(xml.components(separatedBy: "<wpt").count - 1, 2, "Seuls poi/stageStop sont écrits, pas shaping")
        XCTAssertTrue(xml.contains("<name>Refuge</name>"))
        XCTAssertTrue(xml.contains("<type>stage-stop</type>"))
        XCTAssertTrue(xml.contains("<name>Col</name>"))
        // Les <wpt> précèdent <trk>.
        XCTAssertLessThan(xml.range(of: "<wpt")!.lowerBound, xml.range(of: "<trk>")!.lowerBound)
    }

    func testWriteThenParseRoundTripPreservesPoi() throws {
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 100),
            TrackPoint(latitude: 45.5, longitude: 6.5, altitude: 200)
        ]
        let waypoints = [
            RouteWaypoint(latitude: 45.1, longitude: 6.1, name: "Refuge", role: .stageStop),
            RouteWaypoint(latitude: 45.2, longitude: 6.2, name: "Col", role: .poi)
        ]
        let written = try GPXWriter.write(name: "Parcours", activityType: .hiking, points: pts, waypoints: waypoints)
        let parsed = try GPXParser().parse(data: written)
        XCTAssertEqual(parsed.waypoints.map(\.name), ["Refuge", "Col"])
        XCTAssertEqual(parsed.waypoints[0].type, "stage-stop")
        XCTAssertEqual(parsed.points.count, 2)
    }
}
