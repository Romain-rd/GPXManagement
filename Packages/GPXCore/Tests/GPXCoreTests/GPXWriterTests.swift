import XCTest
@testable import GPXCore

final class GPXWriterTests: XCTestCase {
    func testWriteValidXML() throws {
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 100, timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            TrackPoint(latitude: 45.001, longitude: 6.001, altitude: 102, timestamp: Date(timeIntervalSince1970: 1_700_000_010))
        ]
        let data = try GPXWriter.write(name: "Test", activityType: .cyclingRoad, points: pts)
        let xml = String(data: data, encoding: .utf8)!
        XCTAssertTrue(xml.contains("<?xml version="))
        XCTAssertTrue(xml.contains("<name>Test</name>"))
        XCTAssertTrue(xml.contains("<type>cycling.road</type>"))
        XCTAssertTrue(xml.contains("lat=\"45.0000000\""))
        XCTAssertTrue(xml.contains("<ele>100.0</ele>"))
        XCTAssertTrue(xml.contains("</gpx>"))
    }

    func testWriteWithExtensions() throws {
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: nil, timestamp: nil, heartRate: 140, cadence: 80, power: 220)
        ]
        let data = try GPXWriter.write(name: "X", activityType: nil, points: pts)
        let xml = String(data: data, encoding: .utf8)!
        XCTAssertTrue(xml.contains("<gpxtpx:hr>140</gpxtpx:hr>"))
        XCTAssertTrue(xml.contains("<gpxtpx:cad>80</gpxtpx:cad>"))
        XCTAssertTrue(xml.contains("<gpxtpx:power>220</gpxtpx:power>"))
    }

    func testRoundTrip() throws {
        let originalPts = [
            TrackPoint(latitude: 43.700, longitude: 7.262, altitude: 50, timestamp: Date(timeIntervalSince1970: 1_700_000_000), heartRate: 140),
            TrackPoint(latitude: 43.715, longitude: 7.270, altitude: 120, timestamp: Date(timeIntervalSince1970: 1_700_000_600), heartRate: 145)
        ]
        let written = try GPXWriter.write(name: "Round", activityType: .cyclingRoad, points: originalPts)
        let parser = GPXParser()
        let parsed = try parser.parse(data: written)

        XCTAssertEqual(parsed.name, "Round")
        XCTAssertEqual(parsed.activityHint, "cycling.road")
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[0].latitude, 43.700, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(parsed.points[0].altitude), 50, accuracy: 0.1)
        XCTAssertEqual(parsed.points[1].heartRate, 145)
    }

    func testEscapingTitle() throws {
        let pts = [TrackPoint(latitude: 0, longitude: 0)]
        let data = try GPXWriter.write(name: "Col d'<Èze> & co", activityType: nil, points: pts)
        let xml = String(data: data, encoding: .utf8)!
        XCTAssertTrue(xml.contains("Col d&apos;&lt;Èze&gt; &amp; co"))
    }
}
