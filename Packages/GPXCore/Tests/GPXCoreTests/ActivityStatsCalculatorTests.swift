import XCTest
@testable import GPXCore

final class ActivityStatsCalculatorTests: XCTestCase {
    func testLongPausesCountsOnlyStopsOver5Min() {
        func at(_ lat: Double, _ sec: Double) -> TrackPoint {
            TrackPoint(latitude: lat, longitude: 6.0, altitude: nil, timestamp: Date(timeIntervalSince1970: sec))
        }
        let pts = [
            at(45.0000, 0),    // départ
            at(45.0003, 10),   // déplacement (~33 m en 10 s)
            at(45.0003, 370),  // arrêt 360 s au même point → pause ≥ 5 min
            at(45.0006, 380),  // repart
            at(45.0006, 500),  // arrêt 120 s → trop court, pas une pause
            at(45.0009, 510),  // repart
        ]
        XCTAssertEqual(ActivityStatsCalculator.longPausesDuration(points: pts), 360)
    }

    func testEmptyPointsReturnsZero() {
        let stats = ActivityStatsCalculator.compute(points: [])
        XCTAssertEqual(stats, .zero)
    }

    func testStraightLineDistance() {
        let p1 = TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 100, timestamp: Date(timeIntervalSince1970: 0))
        let p2 = TrackPoint(latitude: 45.0, longitude: 6.001, altitude: 100, timestamp: Date(timeIntervalSince1970: 10))
        let stats = ActivityStatsCalculator.compute(points: [p1, p2])
        XCTAssertEqual(stats.distance, 78.6, accuracy: 1.0)
        XCTAssertEqual(stats.duration, 10, accuracy: 0.01)
    }

    func testMovingDurationExcludesPauses() {
        var pts: [TrackPoint] = []
        for i in 0..<10 {
            pts.append(TrackPoint(latitude: 45.0 + Double(i) * 0.0001, longitude: 6.0, altitude: 100, timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        for i in 10..<15 {
            pts.append(TrackPoint(latitude: 45.0009, longitude: 6.0, altitude: 100, timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertLessThan(stats.movingDuration, stats.duration)
        XCTAssertGreaterThan(stats.movingDuration, 0)
    }

    func testElevationGainFiltersNoise() {
        var pts: [TrackPoint] = []
        for i in 0..<100 {
            let noise = Double.random(in: -1.0...1.0)
            pts.append(TrackPoint(
                latitude: 45.0 + Double(i) * 0.0001,
                longitude: 6.0,
                altitude: 1000.0 + noise,
                timestamp: Date(timeIntervalSince1970: Double(i))
            ))
        }
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertLessThan(stats.elevationGain, 30.0, "noise around constant altitude shouldn't accumulate > 30m")
    }

    func testElevationGainSteadyClimb() {
        var pts: [TrackPoint] = []
        for i in 0..<100 {
            pts.append(TrackPoint(
                latitude: 45.0 + Double(i) * 0.0001,
                longitude: 6.0,
                altitude: 1000.0 + Double(i) * 1.0,
                timestamp: Date(timeIntervalSince1970: Double(i))
            ))
        }
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertGreaterThan(stats.elevationGain, 80.0)
        XCTAssertLessThan(stats.elevationGain, 110.0)
        XCTAssertEqual(stats.elevationLoss, 0, accuracy: 1.0)
    }

    func testHeartRateAverage() {
        var pts: [TrackPoint] = []
        for i in 0..<10 {
            pts.append(TrackPoint(
                latitude: 45.0,
                longitude: 6.0,
                altitude: 100,
                timestamp: Date(timeIntervalSince1970: Double(i)),
                heartRate: Double(140 + i)
            ))
        }
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertEqual(stats.avgHeartRate ?? 0, 144.5, accuracy: 0.01)
        XCTAssertEqual(stats.maxHeartRate, 149)
    }

    func testMaxSlopeFromSteadyGrade() {
        // Pente constante de 50 % (montée = 0,5 × distance horizontale) → maxSlope ≈ 50 %.
        let metersPerLon = 6_371_000.0 * .pi / 180 * cos(45.0 * .pi / 180)
        let stepLon = 0.0002
        let stepDist = stepLon * metersPerLon
        var pts: [TrackPoint] = []
        for i in 0..<200 {
            pts.append(TrackPoint(
                latitude: 45.0,
                longitude: 6.0 + Double(i) * stepLon,
                altitude: 1000.0 + Double(i) * stepDist * 0.5,
                timestamp: Date(timeIntervalSince1970: Double(i))
            ))
        }
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertEqual(stats.maxSlope, 50, accuracy: 3)
    }

    func testMaxSlopeFlatIsZero() {
        var pts: [TrackPoint] = []
        for i in 0..<50 {
            pts.append(TrackPoint(latitude: 45.0, longitude: 6.0 + Double(i) * 0.0002, altitude: 1000, timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertEqual(stats.maxSlope, 0, accuracy: 0.5)
    }

    func testBoundingBox() {
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0),
            TrackPoint(latitude: 45.5, longitude: 6.5),
            TrackPoint(latitude: 44.5, longitude: 5.5)
        ]
        let stats = ActivityStatsCalculator.compute(points: pts)
        XCTAssertEqual(stats.boundingBox.minLatitude, 44.5)
        XCTAssertEqual(stats.boundingBox.maxLatitude, 45.5)
        XCTAssertEqual(stats.boundingBox.minLongitude, 5.5)
        XCTAssertEqual(stats.boundingBox.maxLongitude, 6.5)
    }
}
