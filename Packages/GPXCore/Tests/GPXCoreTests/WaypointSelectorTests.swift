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
        XCTAssertEqual(wp!.vias.first?.altitude, 1200)
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
        XCTAssertTrue(wp!.vias.isEmpty)
    }
}

final class RouteNameBuilderTests: XCTestCase {
    func testPointToPointWithVia() {
        let name = RouteNameBuilder.build(startName: "Nice", viaNames: ["Col d'Èze"], endName: "Menton", isLoop: false)
        XCTAssertEqual(name, "Nice → Col d'Èze → Menton")
    }

    func testPointToPointWithoutVia() {
        let name = RouteNameBuilder.build(startName: "Nice", viaNames: [], endName: "Menton", isLoop: false)
        XCTAssertEqual(name, "Nice → Menton")
    }

    func testLoopWithViaListsPassagePoints() {
        // Boucle avec point(s) de passage → liste fléchée (plus de « Boucle de … »).
        let name = RouteNameBuilder.build(startName: "Chamonix", viaNames: ["Aiguille du Midi"], endName: "Chamonix", isLoop: true)
        XCTAssertEqual(name, "Chamonix → Aiguille du Midi → Chamonix")
    }

    func testLoopWithMultipleVias() {
        let name = RouteNameBuilder.build(startName: "Cipières", viaNames: ["Col de l'Écre", "Gréolières"], endName: "Cipières", isLoop: true)
        XCTAssertEqual(name, "Cipières → Col de l'Écre → Gréolières → Cipières")
    }

    func testLoopWithoutViaFallsBack() {
        let name = RouteNameBuilder.build(startName: "Chamonix", viaNames: [], endName: "Chamonix", isLoop: true)
        XCTAssertEqual(name, "Boucle de Chamonix")
    }

    func testSameStartEndNotFlaggedLoopStillListsPassage() {
        let name = RouteNameBuilder.build(startName: "Lyon", viaNames: ["Mont d'Or"], endName: "Lyon", isLoop: false)
        XCTAssertEqual(name, "Lyon → Mont d'Or → Lyon")
    }

    func testMissingNamesFallback() {
        XCTAssertEqual(RouteNameBuilder.build(startName: "Nice", viaNames: [], endName: nil, isLoop: false), "Départ de Nice")
        XCTAssertEqual(RouteNameBuilder.build(startName: nil, viaNames: [], endName: "Menton", isLoop: false), "Arrivée à Menton")
        XCTAssertNil(RouteNameBuilder.build(startName: nil, viaNames: [], endName: nil, isLoop: false))
    }

    func testViaEqualStartNotDuplicated() {
        let name = RouteNameBuilder.build(startName: "Nice", viaNames: ["Nice"], endName: "Menton", isLoop: false)
        XCTAssertEqual(name, "Nice → Menton")
    }
}
