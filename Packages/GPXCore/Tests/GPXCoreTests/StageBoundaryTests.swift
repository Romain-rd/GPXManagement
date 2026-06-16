import XCTest
@testable import GPXCore

final class StageBoundaryTests: XCTestCase {
    private func makePoints(count: Int) -> [TrackPoint] {
        (0..<count).map { TrackPoint(latitude: 45.0 + Double($0) * 0.001, longitude: 6.0, altitude: 1000) }
    }

    private func stage(order: Int, stopId: UUID? = nil) -> Stage {
        Stage(activityId: UUID(), order: order, name: "Étape \(order + 1)", startIndex: 0, endIndex: 0, stopWaypointId: stopId)
    }

    func testSyncThenAssignRoundTrip() {
        let points = makePoints(count: 100)
        // 3 étapes ⇒ 2 frontières internes (aux indices 30 et 60).
        var stages = [stage(order: 0), stage(order: 1), stage(order: 2)]
        stages[0].endIndex = 30
        stages[1].startIndex = 30; stages[1].endIndex = 60
        stages[2].startIndex = 60; stages[2].endIndex = 99

        let (waypoints, withStops) = Stage.syncStops(stages, into: [], points: points)
        XCTAssertEqual(waypoints.filter { $0.role == .stageStop }.count, 2)
        XCTAssertNotNil(withStops[0].stopWaypointId)
        XCTAssertNotNil(withStops[1].stopWaypointId)
        XCTAssertNil(withStops[2].stopWaypointId, "la dernière étape n'a pas de stop d'arrivée")

        let resolved = Stage.assignBoundaries(withStops, from: waypoints, points: points)
        XCTAssertEqual(resolved.map(\.startIndex), [0, 30, 60])
        XCTAssertEqual(resolved.map(\.endIndex), [30, 60, 99])
    }

    func testBoundariesSurviveTrackRewrite() {
        // Tracé re-routé : 2× plus dense. Le stop (lat/lon) reste valide, l'indice est recalculé.
        let original = makePoints(count: 100)
        var stages = [stage(order: 0), stage(order: 1)]
        stages[0].endIndex = 40
        stages[1].startIndex = 40; stages[1].endIndex = 99
        let (waypoints, withStops) = Stage.syncStops(stages, into: [], points: original)

        // Même étendue (lat 45.000→45.099) mais 2× plus de points : le stop (lat 45.040) tombe vers l'indice 80.
        let dense = (0..<200).map { TrackPoint(latitude: 45.0 + Double($0) * (0.099 / 199), longitude: 6.0, altitude: 1000) }
        let resolved = Stage.assignBoundaries(withStops, from: waypoints, points: dense)
        XCTAssertEqual(resolved[0].endIndex, 80)
        XCTAssertEqual(resolved[1].startIndex, 80)
        XCTAssertEqual(resolved[1].endIndex, 199)
    }

    func testSyncPreservesOtherWaypointsAndStopNames() {
        let points = makePoints(count: 100)
        let poi = RouteWaypoint(latitude: 45.05, longitude: 6.0, name: "Lac", role: .poi)
        let existingStopId = UUID()
        let namedStop = RouteWaypoint(id: existingStopId, latitude: 45.03, longitude: 6.0, name: "Refuge", role: .stageStop)
        var stages = [stage(order: 0, stopId: existingStopId), stage(order: 1)]
        stages[0].endIndex = 30
        stages[1].startIndex = 30; stages[1].endIndex = 99

        let (waypoints, _) = Stage.syncStops(stages, into: [poi, namedStop], points: points)
        XCTAssertTrue(waypoints.contains { $0.role == .poi && $0.name == "Lac" }, "le POI est préservé")
        XCTAssertEqual(waypoints.first { $0.role == .stageStop }?.name, "Refuge", "le nom du stop est conservé")
    }

    func testSingleStageHasNoStops() {
        let points = makePoints(count: 50)
        var only = [stage(order: 0)]
        only[0].endIndex = 49
        let (waypoints, withStops) = Stage.syncStops(only, into: [], points: points)
        XCTAssertTrue(waypoints.filter { $0.role == .stageStop }.isEmpty)
        XCTAssertNil(withStops[0].stopWaypointId)
        let resolved = Stage.assignBoundaries(withStops, from: waypoints, points: points)
        XCTAssertEqual(resolved[0].startIndex, 0)
        XCTAssertEqual(resolved[0].endIndex, 49)
    }
}
