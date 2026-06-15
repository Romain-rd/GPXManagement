import XCTest
@testable import GPXCore

final class TrackOperationsTests: XCTestCase {
    private func p(_ lat: Double, _ lon: Double, alt: Double? = nil, t: Double? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, altitude: alt, timestamp: t.map { Date(timeIntervalSince1970: $0) })
    }

    func testSplitPivotInBothHalves() {
        let pts = (0..<10).map { p(45 + Double($0) * 0.001, 6) }
        let result = TrackOperations.split(points: pts, at: 4)
        XCTAssertEqual(result.left.count + result.right.count, pts.count + 1)
        XCTAssertEqual(result.left.last, result.right.first)
        XCTAssertEqual(result.left.count, 5)
        XCTAssertEqual(result.right.count, 6)
    }

    func testMergeChronologicalNoDuplicateTimestamps() {
        let a = [p(45, 6, t: 0), p(45, 6, t: 10), p(45, 6, t: 20)]
        let b = [p(45, 6, t: 5), p(45, 6, t: 15)]
        let c = [p(45, 6, t: 10), p(45, 6, t: 25)] // t=10 chevauche a
        let merged = TrackOperations.merge([a, b, c])
        let times = merged.compactMap { $0.timestamp?.timeIntervalSince1970 }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count, "aucun horodatage en double")
        XCTAssertEqual(times, [0, 5, 10, 15, 20, 25])
    }

    func testCleanOutliersRemovesSyntheticJumps() {
        var pts = (0..<25).map { p(45 + Double($0) * 0.0001, 6.0, t: Double($0)) } // ~11 m/s, normal
        let outlierIndices = [3, 8, 12, 18, 22]
        for idx in outlierIndices {
            pts[idx] = p(55.0, 6.0, t: Double(idx)) // saut ≈ 1110 km en 1 s
        }
        let result = TrackOperations.cleanOutliers(points: pts)
        XCTAssertEqual(result.removedIndices, outlierIndices)
        XCTAssertEqual(result.cleaned.count, pts.count - outlierIndices.count)
    }

    func testSimplifyToleranceZeroReturnsInput() {
        let pts = (0..<10).map { p(45 + Double($0) * 0.001, 6 + Double($0) * 0.0005) }
        XCTAssertEqual(TrackOperations.simplify(points: pts, tolerance: 0), pts)
    }

    func testSimplifyLargeToleranceKeepsExtremes() {
        let pts = (0..<50).map { p(45 + Double($0) * 0.0002, 6 + sin(Double($0)) * 0.0001) }
        let simplified = TrackOperations.simplify(points: pts, tolerance: 1000) // 1 km → quasi droite
        XCTAssertEqual(simplified.first, pts.first)
        XCTAssertEqual(simplified.last, pts.last)
        XCTAssertLessThan(simplified.count, pts.count)
        XCTAssertGreaterThanOrEqual(simplified.count, 2)
    }
}
