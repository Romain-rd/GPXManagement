import XCTest
@testable import GPXCore

final class FITParserTests: XCTestCase {
    private let parser = FITParser()
    private let fitEpoch: TimeInterval = 631_065_600

    func testParseMinimalRecordMessages() throws {
        let data = makeFIT(records: [
            (lat: 45.0, lon: 6.0, timestamp: 100),
            (lat: 45.001, lon: 6.001, timestamp: 110)
        ])
        let parsed = try parser.parse(data: data)
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[0].latitude, 45.0, accuracy: 1e-5)
        XCTAssertEqual(parsed.points[0].longitude, 6.0, accuracy: 1e-5)
        let ts = try XCTUnwrap(parsed.points[1].timestamp).timeIntervalSince1970
        XCTAssertEqual(ts, fitEpoch + 110, accuracy: 0.5)
    }

    func testInvalidSignatureRejected() {
        var bytes = makeFITHeader(dataSize: 0)
        bytes[8] = 0x00
        let data = Data(bytes) + Data([0, 0])
        XCTAssertThrowsError(try parser.parse(data: data)) { error in
            XCTAssertEqual(error as? FITParseError, .invalidSignature)
        }
    }

    func testHeaderTooShort() {
        XCTAssertThrowsError(try parser.parse(data: Data([0, 1, 2])))
    }

    func testTruncatedBodyRejected() {
        var bytes = makeFITHeader(dataSize: 100)
        bytes += [0, 0]
        XCTAssertThrowsError(try parser.parse(data: Data(bytes)))
    }

    func testSportHintRecognized() throws {
        let data = makeFITWithSport(sport: 2, subSport: 30, lat: 45.0, lon: 6.0, timestamp: 200)
        let parsed = try parser.parse(data: data)
        XCTAssertEqual(parsed.activityHint, "gravel_cycling")
        XCTAssertEqual(parsed.points.count, 1)
    }

    func testSessionWithoutRecordsProducesSummary() throws {
        let data = makeFITSession(sport: 31, startTime: 1000, elapsedRaw: 3_600_000, distanceRaw: 0)
        let parsed = try parser.parse(data: data)
        XCTAssertTrue(parsed.points.isEmpty)
        XCTAssertEqual(parsed.activityHint, "rock_climbing")
        XCTAssertEqual(parsed.summary?.duration, 3600)
        XCTAssertEqual(parsed.summary?.startDate?.timeIntervalSince1970 ?? 0, fitEpoch + 1000, accuracy: 0.5)
        XCTAssertEqual(ActivityTypeDetector.detect(hint: parsed.activityHint, fileFormat: .fit), .climbing)
    }

    func testNewSportHintsMapToTypes() {
        let cases: [(UInt8, ActivityType)] = [
            (5, .swimming), (10, .strengthTraining), (4, .strengthTraining),
            (15, .rowing), (16, .mountaineering), (38, .surfing), (48, .climbing)
        ]
        for (code, expected) in cases {
            let parsed = try? parser.parse(data: makeFITSession(sport: code, startTime: 0, elapsedRaw: 1000, distanceRaw: 0))
            XCTAssertEqual(ActivityTypeDetector.detect(hint: parsed?.activityHint, fileFormat: .fit), expected, "sport \(code)")
        }
    }

    private func makeFITSession(sport: UInt8, startTime: UInt32, elapsedRaw: UInt32, distanceRaw: UInt32) -> Data {
        var body: [UInt8] = []
        body.append(0x40); body.append(0); body.append(0)
        body.append(18); body.append(0)
        body.append(4)
        body.append(2); body.append(4); body.append(0x86)
        body.append(5); body.append(1); body.append(0x00)
        body.append(7); body.append(4); body.append(0x86)
        body.append(9); body.append(4); body.append(0x86)
        body.append(0x00)
        appendUInt32LE(&body, startTime)
        body.append(sport)
        appendUInt32LE(&body, elapsedRaw)
        appendUInt32LE(&body, distanceRaw)
        var bytes = makeFITHeader(dataSize: UInt32(body.count))
        bytes += body
        bytes += [0, 0]
        return Data(bytes)
    }

    private func makeFITHeader(dataSize: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(12)
        bytes.append(0x10)
        bytes.append(0)
        bytes.append(0)
        bytes.append(UInt8(dataSize & 0xFF))
        bytes.append(UInt8((dataSize >> 8) & 0xFF))
        bytes.append(UInt8((dataSize >> 16) & 0xFF))
        bytes.append(UInt8((dataSize >> 24) & 0xFF))
        bytes.append(0x2E)
        bytes.append(0x46)
        bytes.append(0x49)
        bytes.append(0x54)
        return bytes
    }

    private func makeFIT(records: [(lat: Double, lon: Double, timestamp: UInt32)]) -> Data {
        var body: [UInt8] = []
        body.append(0x40)
        body.append(0)
        body.append(0)
        body.append(20); body.append(0)
        body.append(3)
        body.append(0); body.append(4); body.append(0x85)
        body.append(1); body.append(4); body.append(0x85)
        body.append(253); body.append(4); body.append(0x86)

        for r in records {
            body.append(0x00)
            appendInt32LE(&body, semicircles(r.lat))
            appendInt32LE(&body, semicircles(r.lon))
            appendUInt32LE(&body, r.timestamp)
        }

        var bytes = makeFITHeader(dataSize: UInt32(body.count))
        bytes += body
        bytes += [0, 0]
        return Data(bytes)
    }

    private func makeFITWithSport(sport: UInt8, subSport: UInt8, lat: Double, lon: Double, timestamp: UInt32) -> Data {
        var body: [UInt8] = []

        body.append(0x40)
        body.append(0); body.append(0)
        body.append(18); body.append(0)
        body.append(2)
        body.append(5); body.append(1); body.append(0x00)
        body.append(6); body.append(1); body.append(0x00)

        body.append(0x00)
        body.append(sport)
        body.append(subSport)

        body.append(0x41)
        body.append(0); body.append(0)
        body.append(20); body.append(0)
        body.append(3)
        body.append(0); body.append(4); body.append(0x85)
        body.append(1); body.append(4); body.append(0x85)
        body.append(253); body.append(4); body.append(0x86)

        body.append(0x01)
        appendInt32LE(&body, semicircles(lat))
        appendInt32LE(&body, semicircles(lon))
        appendUInt32LE(&body, timestamp)

        var bytes = makeFITHeader(dataSize: UInt32(body.count))
        bytes += body
        bytes += [0, 0]
        return Data(bytes)
    }

    private func semicircles(_ degrees: Double) -> Int32 {
        Int32(degrees * (2147483648.0 / 180.0))
    }

    private func appendInt32LE(_ bytes: inout [UInt8], _ v: Int32) {
        let u = UInt32(bitPattern: v)
        bytes.append(UInt8(u & 0xFF))
        bytes.append(UInt8((u >> 8) & 0xFF))
        bytes.append(UInt8((u >> 16) & 0xFF))
        bytes.append(UInt8((u >> 24) & 0xFF))
    }

    private func appendUInt32LE(_ bytes: inout [UInt8], _ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }
}
