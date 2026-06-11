import XCTest
@testable import GPXCore

final class TrackSegmentTests: XCTestCase {
    /// Points espacés d'environ 100 m vers le nord (0.0009° de latitude), horodatés toutes les 30 s.
    private func makePoints(count: Int) -> [TrackPoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            TrackPoint(
                latitude: 45.0 + Double(i) * 0.0009,
                longitude: 6.0,
                altitude: 1000 + Double(i),
                timestamp: start.addingTimeInterval(Double(i) * 30)
            )
        }
    }

    func testByDistanceSplitsContiguously() {
        let points = makePoints(count: 30) // ~2,9 km au total
        let segments = TrackSegmentBuilder.byDistance(points: points, every: 1_000)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first?.startIndex, 0)
        XCTAssertEqual(segments.last?.endIndex, points.count - 1)
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(a.endIndex, b.startIndex, "Les segments doivent être contigus")
        }
    }

    func testByDistanceSegmentLengthIsCloseToTarget() {
        let points = makePoints(count: 30)
        let segments = TrackSegmentBuilder.byDistance(points: points, every: 1_000)
        let stats = segments[0].stats(in: points)
        XCTAssertEqual(stats.distance, 1_000, accuracy: 150)
    }

    func testByDistanceRejectsDegenerateInput() {
        XCTAssertTrue(TrackSegmentBuilder.byDistance(points: [], every: 1_000).isEmpty)
        XCTAssertTrue(TrackSegmentBuilder.byDistance(points: makePoints(count: 1), every: 1_000).isEmpty)
        XCTAssertTrue(TrackSegmentBuilder.byDistance(points: makePoints(count: 10), every: 0).isEmpty)
    }

    func testSliceClampsOutOfBoundsIndices() {
        let points = makePoints(count: 10)
        let segment = TrackSegment(name: "Hors bornes", startIndex: 5, endIndex: 50)
        let slice = segment.slice(of: points)
        XCTAssertEqual(slice.count, 5)
        XCTAssertEqual(slice.first, points[5])
        XCTAssertEqual(slice.last, points[9])
        XCTAssertTrue(segment.slice(of: []).isEmpty)
    }

    func testInitNormalizesReversedIndices() {
        let segment = TrackSegment(name: "Inversé", startIndex: 20, endIndex: 4)
        XCTAssertEqual(segment.startIndex, 4)
        XCTAssertEqual(segment.endIndex, 20)
    }

    func testEncodeDecodeRoundTrip() {
        let segments = [
            TrackSegment(name: "Montée du col", startIndex: 0, endIndex: 120),
            TrackSegment(name: "Descente", startIndex: 120, endIndex: 300)
        ]
        let data = TrackSegment.encode(segments)
        XCTAssertNotNil(data)
        XCTAssertEqual(TrackSegment.decode(data), segments)
    }

    func testEncodeEmptyReturnsNilAndDecodeNilReturnsEmpty() {
        XCTAssertNil(TrackSegment.encode([]))
        XCTAssertTrue(TrackSegment.decode(nil).isEmpty)
        XCTAssertTrue(TrackSegment.decode(Data()).isEmpty)
    }

    func testSegmentStatsCoverDurationAndElevation() {
        let points = makePoints(count: 30)
        let segment = TrackSegment(name: "Plage", startIndex: 0, endIndex: 10)
        let stats = segment.stats(in: points)
        XCTAssertEqual(stats.duration, 300, accuracy: 0.001) // 10 intervalles de 30 s
        XCTAssertGreaterThan(stats.elevationGain, 0) // +1 m par point
    }
}
