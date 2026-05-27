import XCTest
@testable import GPXCore

final class TrackPointCodecTests: XCTestCase {
    func testRoundTripSinglePoint() throws {
        let p = TrackPoint(latitude: 45.5, longitude: 6.1, altitude: 1200.0, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try TrackPointCodec.encode([p])
        let decoded = try TrackPointCodec.decode(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].latitude, 45.5, accuracy: 1e-9)
        XCTAssertEqual(decoded[0].longitude, 6.1, accuracy: 1e-9)
        XCTAssertEqual(decoded[0].altitude, 1200.0)
        let ts = try XCTUnwrap(decoded[0].timestamp).timeIntervalSince1970
        XCTAssertEqual(ts, 1_700_000_000, accuracy: 1e-6)
        XCTAssertNil(decoded[0].heartRate)
    }

    func testRoundTripEmpty() throws {
        let data = try TrackPointCodec.encode([])
        let decoded = try TrackPointCodec.decode(data)
        XCTAssertEqual(decoded.count, 0)
    }

    func testRoundTrip100Points() throws {
        var points: [TrackPoint] = []
        points.reserveCapacity(100)
        for i in 0..<100 {
            let d = Double(i)
            points.append(TrackPoint(
                latitude: 45.0 + d * 0.0001,
                longitude: 6.0 + d * 0.0001,
                altitude: 1000.0 + d,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + d),
                heartRate: 140.0 + Double(i % 30),
                cadence: 80.0,
                power: 200.0 + d
            ))
        }
        let data = try TrackPointCodec.encode(points)
        let decoded = try TrackPointCodec.decode(data)
        XCTAssertEqual(decoded.count, 100)
        XCTAssertEqual(decoded.first?.latitude, points.first?.latitude)
        XCTAssertEqual(decoded.last?.power, points.last?.power)
    }

    func testRoundTrip50_000Points() throws {
        var points: [TrackPoint] = []
        points.reserveCapacity(50_000)
        for i in 0..<50_000 {
            let d = Double(i)
            points.append(TrackPoint(
                latitude: 45.0 + d * 1e-6,
                longitude: 6.0 + d * 1e-6,
                altitude: 1000.0 + sin(d * 0.001) * 50,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + d),
                heartRate: 140.0,
                cadence: 80.0,
                power: 200.0
            ))
        }
        let data = try TrackPointCodec.encode(points)
        let decoded = try TrackPointCodec.decode(data)
        XCTAssertEqual(decoded.count, 50_000)
        XCTAssertEqual(decoded[12345].latitude, points[12345].latitude, accuracy: 1e-9)
        let tsLast = try XCTUnwrap(decoded[49_999].timestamp).timeIntervalSince1970
        let tsExpected = try XCTUnwrap(points[49_999].timestamp).timeIntervalSince1970
        XCTAssertEqual(tsLast, tsExpected, accuracy: 1e-6)
    }

    func testNilFieldsArePreserved() throws {
        let p1 = TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 1000.0, timestamp: Date(timeIntervalSince1970: 100), heartRate: 140.0)
        let p2 = TrackPoint(latitude: 45.1, longitude: 6.1, altitude: nil, timestamp: nil, heartRate: nil)
        let data = try TrackPointCodec.encode([p1, p2])
        let decoded = try TrackPointCodec.decode(data)
        XCTAssertEqual(decoded[0].altitude, 1000.0)
        XCTAssertEqual(decoded[0].heartRate, 140.0)
        XCTAssertNil(decoded[1].altitude)
        XCTAssertNil(decoded[1].timestamp)
        XCTAssertNil(decoded[1].heartRate)
    }

    func testNoOptionalFlagsWhenAllNil() throws {
        var points: [TrackPoint] = []
        for i in 0..<10 {
            points.append(TrackPoint(latitude: 45.0 + Double(i), longitude: 6.0))
        }
        let data = try TrackPointCodec.encode(points)
        let decoded = try TrackPointCodec.decode(data)
        XCTAssertEqual(decoded.count, 10)
        XCTAssertNil(decoded.first?.altitude)
        XCTAssertNil(decoded.first?.timestamp)
    }

    func testDecodeRejectsTruncatedData() {
        let truncated = Data([0x47, 0x50])
        XCTAssertThrowsError(try TrackPointCodec.decode(truncated))
    }

    func testCompressionReducesSize() throws {
        var points: [TrackPoint] = []
        for i in 0..<5_000 {
            points.append(TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 1000.0, timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        let compressed = try TrackPointCodec.encode(points)
        let rawSize = 10 + 5_000 * 4 * 8
        XCTAssertLessThan(compressed.count, rawSize)
    }
}
