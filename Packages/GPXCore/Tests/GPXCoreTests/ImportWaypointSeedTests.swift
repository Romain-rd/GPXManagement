import XCTest
@testable import GPXCore

final class ImportWaypointSeedTests: XCTestCase {
    private func track() -> ParsedTrack {
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 1000),
            TrackPoint(latitude: 45.5, longitude: 6.5, altitude: 1500),
            TrackPoint(latitude: 46.0, longitude: 6.0, altitude: 1200)
        ]
        return ParsedTrack(name: "P", activityHint: nil, startDate: nil, endDate: nil, points: pts, waypoints: [])
    }

    func testWaypointNearStartOrEndBecomesStageStop() {
        let pts = track().points
        let waypoints = [
            ParsedWaypoint(name: "Départ", latitude: 45.0, longitude: 6.0),     // = point 0
            ParsedWaypoint(name: "Col", latitude: 45.5, longitude: 6.5),         // milieu
            ParsedWaypoint(name: "Arrivée", latitude: 46.0, longitude: 6.0)      // = dernier point
        ]
        let parsed = ParsedTrack(name: "P", activityHint: nil, startDate: nil, endDate: nil, points: pts, waypoints: waypoints)
        let mapped = ImportService.routeWaypoints(from: parsed)
        XCTAssertEqual(mapped.map(\.role), [.stageStop, .poi, .stageStop])
        XCTAssertEqual(mapped.map(\.name), ["Départ", "Col", "Arrivée"])
    }

    func testStageStopTypeHintForcesStageStop() {
        let pts = track().points
        let waypoints = [ParsedWaypoint(name: "Refuge", latitude: 45.5, longitude: 6.5, type: "stage-stop")]
        let parsed = ParsedTrack(name: "P", activityHint: nil, startDate: nil, endDate: nil, points: pts, waypoints: waypoints)
        XCTAssertEqual(ImportService.routeWaypoints(from: parsed).first?.role, .stageStop)
    }

    func testMiddleWaypointWithoutHintIsPoi() {
        let pts = track().points
        let waypoints = [ParsedWaypoint(name: "Lac", latitude: 45.4, longitude: 6.4)]
        let parsed = ParsedTrack(name: "P", activityHint: nil, startDate: nil, endDate: nil, points: pts, waypoints: waypoints)
        XCTAssertEqual(ImportService.routeWaypoints(from: parsed).first?.role, .poi)
    }
}
