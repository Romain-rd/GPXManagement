import XCTest
@testable import GPXCore

final class WaypointSelectorTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double, alt: Double? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, altitude: alt)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(WaypointSelector.waypoints(from: []))
        XCTAssertNil(WaypointSelector.waypoints(from: [pt(45, 6)]))
    }

    func testPointToPointDetectsViaAsHighestPoint() {
        var pts: [TrackPoint] = []
        pts.append(pt(45.0, 6.0, alt: 200))
        for i in 1...50 {
            pts.append(pt(45.0 + Double(i) * 0.001, 6.0 + Double(i) * 0.001, alt: 200 + Double(i) * 20))
        }
        for i in 1...50 {
            pts.append(pt(45.05 + Double(i) * 0.001, 6.05 + Double(i) * 0.001, alt: 1200 - Double(i) * 5))
        }
        let wp = WaypointSelector.waypoints(from: pts)
        XCTAssertNotNil(wp)
        XCTAssertFalse(wp!.isLoop)
        XCTAssertEqual(wp!.via?.altitude, 1200)
    }

    func testLoopDetectedWhenStartEqualsEnd() {
        var pts: [TrackPoint] = []
        pts.append(pt(45.0, 6.0, alt: 200))
        pts.append(pt(45.02, 6.02, alt: 800))
        pts.append(pt(45.03, 6.03, alt: 1000))
        pts.append(pt(45.0001, 6.0001, alt: 205))
        let wp = WaypointSelector.waypoints(from: pts)
        XCTAssertNotNil(wp)
        XCTAssertTrue(wp!.isLoop)
    }

    func testFlatRouteUsesFarthestPointAsVia() {
        var pts: [TrackPoint] = []
        for i in 0...100 {
            pts.append(pt(45.0 + Double(i) * 0.001, 6.0, alt: 100))
        }
        let wp = WaypointSelector.waypoints(from: pts)
        XCTAssertNotNil(wp)
        // farthest from start on a straight line == end, which is too close to end → via nil
        // but midpoints exist; farthest is the end, filtered out → nil acceptable
        XCTAssertFalse(wp!.isLoop)
    }

    func testViaFilteredWhenTooCloseToEndpoints() {
        let pts = [pt(45.0, 6.0, alt: 100), pt(45.0005, 6.0005, alt: 120), pt(45.001, 6.001, alt: 100)]
        let wp = WaypointSelector.waypoints(from: pts, minViaSeparationMeters: 500)
        XCTAssertNotNil(wp)
        XCTAssertNil(wp!.via)
    }
}

final class RouteNameBuilderTests: XCTestCase {
    func testPointToPointWithVia() {
        let name = RouteNameBuilder.build(startName: "Nice", viaName: "Col d'Èze", endName: "Menton", isLoop: false)
        XCTAssertEqual(name, "Nice → Col d'Èze → Menton")
    }

    func testPointToPointWithoutVia() {
        let name = RouteNameBuilder.build(startName: "Nice", viaName: nil, endName: "Menton", isLoop: false)
        XCTAssertEqual(name, "Nice → Menton")
    }

    func testLoopWithVia() {
        let name = RouteNameBuilder.build(startName: "Chamonix", viaName: "Aiguille du Midi", endName: "Chamonix", isLoop: true)
        XCTAssertEqual(name, "Boucle de Chamonix par Aiguille du Midi")
    }

    func testLoopWithoutVia() {
        let name = RouteNameBuilder.build(startName: "Chamonix", viaName: nil, endName: "Chamonix", isLoop: true)
        XCTAssertEqual(name, "Boucle de Chamonix")
    }

    func testSameStartEndNotFlaggedLoopStillBecomesLoop() {
        let name = RouteNameBuilder.build(startName: "Lyon", viaName: "Mont d'Or", endName: "Lyon", isLoop: false)
        XCTAssertEqual(name, "Boucle de Lyon par Mont d'Or")
    }

    func testMissingNamesFallback() {
        XCTAssertEqual(RouteNameBuilder.build(startName: "Nice", viaName: nil, endName: nil, isLoop: false), "Départ de Nice")
        XCTAssertEqual(RouteNameBuilder.build(startName: nil, viaName: nil, endName: "Menton", isLoop: false), "Arrivée à Menton")
        XCTAssertNil(RouteNameBuilder.build(startName: nil, viaName: nil, endName: nil, isLoop: false))
    }

    func testViaEqualStartNotDuplicated() {
        let name = RouteNameBuilder.build(startName: "Nice", viaName: "Nice", endName: "Menton", isLoop: false)
        XCTAssertEqual(name, "Nice → Menton")
    }
}
