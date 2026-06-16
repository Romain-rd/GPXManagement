import XCTest
@testable import GPXCore

final class ImportWaypointSeedTests: XCTestCase {
    /// Tracé en zigzag (amplitude ~240 m) pour que Douglas-Peucker conserve des ancrages intermédiaires.
    private func zigzag(count: Int) -> [TrackPoint] {
        (0..<count).map { i in
            TrackPoint(latitude: 45.0 + Double(i) * 0.001,
                       longitude: 6.0 + (i % 2 == 0 ? 0.0 : 0.003),
                       altitude: 1000)
        }
    }

    private func parsed(points: [TrackPoint], waypoints: [ParsedWaypoint]) -> ParsedTrack {
        ParsedTrack(name: "P", activityHint: nil, startDate: nil, endDate: nil, points: points, waypoints: waypoints)
    }

    func testWaypointNearStartOrEndBecomesStageStopOthersPoi() {
        let pts = zigzag(count: 40)
        let waypoints = [
            ParsedWaypoint(name: "Départ", latitude: pts.first!.latitude, longitude: pts.first!.longitude),
            ParsedWaypoint(name: "Col", latitude: pts[20].latitude, longitude: pts[20].longitude),
            ParsedWaypoint(name: "Arrivée", latitude: pts.last!.latitude, longitude: pts.last!.longitude)
        ]
        let result = ImportService.routeWaypoints(from: parsed(points: pts, waypoints: waypoints))
        let named = result.filter { $0.role != .shaping }
        XCTAssertEqual(named.map(\.name), ["Départ", "Col", "Arrivée"])
        XCTAssertEqual(named.map(\.role), [.stageStop, .poi, .stageStop])
    }

    func testStageStopTypeHintForcesStageStop() {
        let pts = zigzag(count: 40)
        let waypoints = [ParsedWaypoint(name: "Refuge", latitude: pts[20].latitude, longitude: pts[20].longitude, type: "stage-stop")]
        let result = ImportService.routeWaypoints(from: parsed(points: pts, waypoints: waypoints))
        XCTAssertEqual(result.first { $0.role != .shaping }?.role, .stageStop)
    }

    func testMiddleWaypointWithoutHintIsPoi() {
        let pts = zigzag(count: 40)
        let waypoints = [ParsedWaypoint(name: "Lac", latitude: pts[18].latitude, longitude: pts[18].longitude)]
        let result = ImportService.routeWaypoints(from: parsed(points: pts, waypoints: waypoints))
        XCTAssertEqual(result.first { $0.role != .shaping }?.role, .poi)
    }

    func testAnchorsAreMergedWithPoisInTrackOrder() {
        let pts = zigzag(count: 40)
        let waypoints = [ParsedWaypoint(name: "Col", latitude: pts[20].latitude, longitude: pts[20].longitude)]
        let result = ImportService.routeWaypoints(from: parsed(points: pts, waypoints: waypoints))
        XCTAssertTrue(result.contains { $0.role == .shaping }, "Les ancrages dérivés du tracé sont conservés")
        XCTAssertEqual(result.filter { $0.role == .poi }.count, 1)
        // Le POI est bien inséré entre des ancrages (ni premier ni dernier de la liste).
        let poiPos = result.firstIndex { $0.role == .poi }!
        XCTAssertGreaterThan(poiPos, 0)
        XCTAssertLessThan(poiPos, result.count - 1)
    }

    func testNoTrackFallsBackToPoisOnly() {
        let waypoints = [ParsedWaypoint(name: "Col", latitude: 45.5, longitude: 6.5)]
        let result = ImportService.routeWaypoints(from: parsed(points: [], waypoints: waypoints))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.role, .poi)
    }
}
