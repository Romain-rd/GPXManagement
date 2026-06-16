import XCTest
@testable import GPXCore

final class RouteWaypointTests: XCTestCase {
    /// Points espacés d'environ 100 m vers le nord (0.0009° de latitude).
    private func makePoints(count: Int) -> [TrackPoint] {
        (0..<count).map { i in
            TrackPoint(latitude: 45.0 + Double(i) * 0.0009, longitude: 6.0, altitude: 1000 + Double(i))
        }
    }

    func testDefaultRoleIsShaping() {
        let wp = RouteWaypoint(latitude: 45, longitude: 6)
        XCTAssertEqual(wp.role, .shaping)
    }

    func testEncodeDecodeRoundTripPreservesRole() {
        let waypoints = [
            RouteWaypoint(latitude: 45, longitude: 6, name: "Départ", role: .stageStop),
            RouteWaypoint(latitude: 45.01, longitude: 6.01, role: .shaping),
            RouteWaypoint(latitude: 45.02, longitude: 6.02, name: "Col", role: .poi)
        ]
        let data = RouteWaypointCodec.encode(waypoints)
        XCTAssertNotNil(data)
        let decoded = RouteWaypointCodec.decode(data)
        XCTAssertEqual(decoded, waypoints)
        XCTAssertEqual(decoded.map(\.role), [.stageStop, .shaping, .poi])
    }

    /// Les waypoints persistés avant l'ajout de `role` (clé absente) doivent se relire en `.shaping`.
    func testDecodeLegacyJSONWithoutRole() {
        let legacy = Data(#"[{"id":"6F1C9C4E-2B7A-4E54-9C1D-000000000001","latitude":45.0,"longitude":6.0,"name":"Col"}]"#.utf8)
        let decoded = RouteWaypointCodec.decode(legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.role, .shaping)
        XCTAssertEqual(decoded.first?.name, "Col")
    }

    func testStageBoundariesSnapStopsToNearestPointInOrder() {
        let points = makePoints(count: 30)
        let waypoints = [
            RouteWaypoint(latitude: points[0].latitude, longitude: 6, role: .stageStop),
            RouteWaypoint(latitude: 45.0123, longitude: 6, role: .shaping),         // ignoré (≈ point 13-14)
            RouteWaypoint(latitude: points[10].latitude, longitude: 6, role: .stageStop),
            RouteWaypoint(latitude: points[29].latitude, longitude: 6, role: .stageStop)
        ]
        let boundaries = RouteWaypoint.stageBoundaries(waypoints, on: points)
        XCTAssertEqual(boundaries.map(\.index), [0, 10, 29])
        XCTAssertEqual(boundaries.map(\.stopId), [waypoints[0].id, waypoints[2].id, waypoints[3].id])
    }

    func testStageBoundariesEmptyWhenNoStopsOrNoPoints() {
        let points = makePoints(count: 5)
        let onlyShaping = [RouteWaypoint(latitude: 45, longitude: 6, role: .shaping)]
        XCTAssertTrue(RouteWaypoint.stageBoundaries(onlyShaping, on: points).isEmpty)
        let stop = [RouteWaypoint(latitude: 45, longitude: 6, role: .stageStop)]
        XCTAssertTrue(RouteWaypoint.stageBoundaries(stop, on: []).isEmpty)
    }

    func testEncodeEmptyReturnsNilAndDecodeNilReturnsEmpty() {
        XCTAssertNil(RouteWaypointCodec.encode([]))
        XCTAssertTrue(RouteWaypointCodec.decode(nil).isEmpty)
        XCTAssertTrue(RouteWaypointCodec.decode(Data()).isEmpty)
    }
}
