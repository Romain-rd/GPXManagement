import XCTest
@testable import GPXCore

final class SensorSeriesTests: XCTestCase {
    private func samples() -> [SensorSample] {
        let t0 = Date(timeIntervalSince1970: 1000)
        return [
            SensorSample(time: t0, heartRate: 100),
            SensorSample(time: t0.addingTimeInterval(1), heartRate: 110),
            SensorSample(time: t0.addingTimeInterval(2), heartRate: nil),  // trou
            SensorSample(time: t0.addingTimeInterval(3), heartRate: 120),
        ]
    }

    func testBuildDropsEmptyChannels() {
        let s = SensorSeries(samples: samples())
        XCTAssertEqual(s.t.count, 4)
        XCTAssertNotNil(s.hr)       // FC présente
        XCTAssertNil(s.alt)         // altitude jamais fournie → canal absent
        XCTAssertNil(s.cad)
        XCTAssertTrue(s.hasHeartRate)
    }

    func testHeartRatePointsSkipNils() {
        let s = SensorSeries(samples: samples())
        let pts = s.heartRatePoints
        XCTAssertEqual(pts.map(\.value), [100, 110, 120])  // le trou est sauté
    }

    func testStats() {
        let s = SensorSeries(samples: samples())
        let st = s.heartRateStats!
        XCTAssertEqual(st.avg, 110, accuracy: 0.001)
        XCTAssertEqual(st.max, 120, accuracy: 0.001)
    }

    func testRoundTrip() {
        let s = SensorSeries(samples: samples())
        let data = SensorSeriesCodec.encode(s)
        XCTAssertNotNil(data)
        let back = SensorSeriesCodec.decode(data)
        XCTAssertEqual(back, s)
    }

    func testEmptyEncodesToNil() {
        XCTAssertNil(SensorSeriesCodec.encode(SensorSeries(t: [])))
        XCTAssertNil(SensorSeriesCodec.decode(nil))
    }
}
