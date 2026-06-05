import XCTest
@testable import GPXCore

final class ElevationProfileBuilderTests: XCTestCase {
    func testEmptyReturnsEmpty() {
        let profile = ElevationProfileBuilder.build(points: [])
        XCTAssertTrue(profile.isEmpty)
    }

    func testSingleAltitudePointReturnsEmpty() {
        let p = TrackPoint(latitude: 45, longitude: 6, altitude: 100)
        XCTAssertTrue(ElevationProfileBuilder.build(points: [p]).isEmpty)
    }

    func testTimeByCategoryAccumulatesPerSlope() {
        let start = Date(timeIntervalSince1970: 0)
        var pts: [TrackPoint] = []
        // Montée raide (~10%) sur 100 points espacés de 10s, puis plat.
        for i in 0..<100 {
            let d = Double(i)
            pts.append(TrackPoint(
                latitude: 45.0 + d * 0.0001, longitude: 6.0,
                altitude: 1000 + d * 1.0,
                timestamp: start.addingTimeInterval(d * 10)
            ))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        let times = ElevationProfileBuilder.timeByCategory(profile)
        let total = times.values.reduce(0, +)
        XCTAssertGreaterThan(total, 0)
        // L'essentiel du temps doit être dans des catégories de montée, pas en descente.
        XCTAssertEqual(times[.descent] ?? 0, 0, accuracy: 1)
    }

    func testTimeByCategoryIgnoresGaps() {
        let start = Date(timeIntervalSince1970: 0)
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 100, timestamp: start),
            TrackPoint(latitude: 45.001, longitude: 6.0, altitude: 101, timestamp: start.addingTimeInterval(10)),
            // Gros gap (1h) → ignoré.
            TrackPoint(latitude: 45.002, longitude: 6.0, altitude: 102, timestamp: start.addingTimeInterval(3610)),
        ]
        let profile = ElevationProfileBuilder.build(points: pts)
        let times = ElevationProfileBuilder.timeByCategory(profile)
        XCTAssertEqual(times.values.reduce(0, +), 10, accuracy: 1)
    }

    func testMovementTimeSeparatesMovingAndPaused() {
        let start = Date(timeIntervalSince1970: 0)
        var pts: [TrackPoint] = []
        // 50 points en mouvement (~5 m/s), espacés de 5s.
        for i in 0..<50 {
            let d = Double(i)
            pts.append(TrackPoint(latitude: 45.0 + d * 0.0002, longitude: 6.0, altitude: 100 + d,
                                  timestamp: start.addingTimeInterval(d * 5)))
        }
        // 30 points immobiles (même position), espacés de 5s → pause.
        let pauseStart = start.addingTimeInterval(50 * 5)
        for i in 0..<30 {
            pts.append(TrackPoint(latitude: 45.01, longitude: 6.0, altitude: 150,
                                  timestamp: pauseStart.addingTimeInterval(Double(i) * 5)))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        let (moving, paused) = ElevationProfileBuilder.movementTime(profile)
        XCTAssertGreaterThan(moving, 0)
        XCTAssertGreaterThan(paused, 0)
        XCTAssertGreaterThan(paused, 100)
    }

    func testMonotonicAscentProducesPositiveSlope() {
        var pts: [TrackPoint] = []
        for i in 0..<200 {
            let d = Double(i)
            pts.append(TrackPoint(
                latitude: 45.0 + d * 0.00001,
                longitude: 6.0,
                altitude: 1000 + d * 0.5
            ))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        XCTAssertEqual(profile.count, 200)
        let slopes = profile.dropFirst(30).dropLast(30).map(\.slope)
        XCTAssertGreaterThan(slopes.first ?? 0, 0)
        XCTAssertLessThan(slopes.max() ?? 0, 100)
    }

    func testFlatTerrainHasZeroSlope() {
        var pts: [TrackPoint] = []
        for i in 0..<100 {
            pts.append(TrackPoint(latitude: 45.0 + Double(i) * 1e-5, longitude: 6.0, altitude: 1000))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        for p in profile.dropFirst(10).dropLast(10) {
            XCTAssertEqual(p.slope, 0, accuracy: 0.1)
        }
    }

    func testGPSNoiseDoesNotProduceExcessiveSlope() {
        var pts: [TrackPoint] = []
        for i in 0..<300 {
            let noise = Double.random(in: -2...2)
            pts.append(TrackPoint(
                latitude: 45.0 + Double(i) * 1e-5,
                longitude: 6.0,
                altitude: 1000 + noise
            ))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        for p in profile {
            XCTAssertLessThan(abs(p.slope), 80, "noise alone shouldn't produce >80% slope")
        }
    }

    func testDecimationReducesPoints() {
        var profile: [ElevationProfilePoint] = []
        for i in 0..<10_000 {
            let d = Double(i)
            profile.append(ElevationProfilePoint(distanceFromStart: d, altitude: 1000 + sin(d * 0.01) * 50, slope: 0))
        }
        let decimated = ElevationProfileBuilder.decimate(profile, tolerance: 1.0, maxPoints: 5_000)
        XCTAssertLessThan(decimated.count, profile.count)
        XCTAssertEqual(decimated.first?.distanceFromStart, profile.first?.distanceFromStart)
        XCTAssertEqual(decimated.last?.distanceFromStart, profile.last?.distanceFromStart)
    }

    func testSlopeCategoryRanges() {
        XCTAssertEqual(SlopeCategory.category(for: 0), .gentle)
        XCTAssertEqual(SlopeCategory.category(for: 3.9), .gentle)
        XCTAssertEqual(SlopeCategory.category(for: 6), .moderate)
        XCTAssertEqual(SlopeCategory.category(for: 10), .steep)
        XCTAssertEqual(SlopeCategory.category(for: 15), .veryStep)
        XCTAssertEqual(SlopeCategory.category(for: -5), .descent)
    }

    func testSlopeCategoryRangesStep8() {
        XCTAssertEqual(SlopeCategory.category(for: 6, step: 8), .gentle)
        XCTAssertEqual(SlopeCategory.category(for: 10, step: 8), .moderate)
        XCTAssertEqual(SlopeCategory.category(for: 18, step: 8), .steep)
        XCTAssertEqual(SlopeCategory.category(for: 30, step: 8), .veryStep)
        XCTAssertEqual(SlopeCategory.category(for: -6, step: 8), .gentle)
        XCTAssertEqual(SlopeCategory.category(for: -10, step: 8), .descent)
    }

    func testSlopeColorStepByActivityType() {
        XCTAssertEqual(ActivityType.skiingTouring.slopeColorStep, 8)
        XCTAssertEqual(ActivityType.cyclingRoad.slopeColorStep, 4)
        XCTAssertEqual(ActivityType.skiingAlpine.slopeColorStep, 4)
    }
}
