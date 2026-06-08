import XCTest
@testable import GPXCore

final class ClimbCounterTests: XCTestCase {
    /// Construit un profil : `n` montées de `height` m (montée puis redescente), avec du bruit léger.
    private func profile(climbs: Int, height: Double) -> [Double] {
        var alts: [Double] = [0]
        for _ in 0..<climbs {
            for h in stride(from: 0.0, through: height, by: 0.5) { alts.append(h) }
            for h in stride(from: height, through: 0.0, by: -0.5) { alts.append(h) }
        }
        return alts
    }

    func testCountsDistinctClimbs() {
        XCTAssertEqual(ClimbCounter.count(altitudes: profile(climbs: 5, height: 4)), 5)
        XCTAssertEqual(ClimbCounter.count(altitudes: profile(climbs: 3, height: 9)), 3)
    }

    func testFlatProfileHasNoClimbs() {
        XCTAssertEqual(ClimbCounter.count(altitudes: Array(repeating: 0.0, count: 100)), 0)
    }

    func testNoiseBelowThresholdIgnored() {
        // Oscillations de ±0,5 m : sous le seuil 1,5 m → 0 montée.
        let noisy = (0..<200).map { $0 % 2 == 0 ? 0.0 : 0.5 }
        XCTAssertEqual(ClimbCounter.count(altitudes: noisy), 0)
    }

    func testEmptyOrSinglePoint() {
        XCTAssertEqual(ClimbCounter.count(altitudes: []), 0)
        XCTAssertEqual(ClimbCounter.count(altitudes: [3.0]), 0)
    }

    func testThresholdSelectsClimbs() {
        let p = profile(climbs: 2, height: 2.5)
        XCTAssertEqual(ClimbCounter.count(altitudes: p, thresholdMeters: 2.0), 2)
        XCTAssertEqual(ClimbCounter.count(altitudes: p, thresholdMeters: 3.0), 0) // montées trop basses
    }
}
