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
}
