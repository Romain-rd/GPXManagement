import XCTest
@testable import GPXMapKit

final class IGNSlopeSamplerTests: XCTestCase {
    func testWebMercatorAnchors() {
        // Zoom 0 : monde = 256 px, centre (0,0) au milieu.
        let center = WebMercator.pixel(lat: 0, lon: 0, z: 0)
        XCTAssertEqual(center.x, 128, accuracy: 0.001)
        XCTAssertEqual(center.y, 128, accuracy: 0.001)
        XCTAssertEqual(WebMercator.pixel(lat: 0, lon: 180, z: 0).x, 256, accuracy: 0.001)
        XCTAssertEqual(WebMercator.pixel(lat: 0, lon: -180, z: 0).x, 0, accuracy: 0.001)
        // Latitude positive → plus haut dans la tuile (y plus petit).
        XCTAssertLessThan(WebMercator.pixel(lat: 45, lon: 0, z: 0).y, 128)
    }

    func testWebMercatorZoomScales() {
        let z3 = WebMercator.pixel(lat: 45.9, lon: 6.95, z: 3)
        let z4 = WebMercator.pixel(lat: 45.9, lon: 6.95, z: 4)
        XCTAssertEqual(z4.x, z3.x * 2, accuracy: 0.001)
        XCTAssertEqual(z4.y, z3.y * 2, accuracy: 0.001)
    }

    func testSlopeBandClassification() {
        XCTAssertEqual(SlopeBand.classify(r: 0, g: 0, b: 0, a: 0), .below30)        // transparent
        XCTAssertEqual(SlopeBand.classify(r: 245, g: 231, b: 0, a: 255), .d30_35)   // jaune
        XCTAssertEqual(SlopeBand.classify(r: 247, g: 165, b: 30, a: 255), .d35_40)  // orange
        XCTAssertEqual(SlopeBand.classify(r: 240, g: 35, b: 0, a: 255), .d40_45)    // rouge
        XCTAssertEqual(SlopeBand.classify(r: 211, g: 158, b: 199, a: 255), .above45) // violet
        // Teinte bruitée proche du jaune reste classée jaune.
        XCTAssertEqual(SlopeBand.classify(r: 240, g: 225, b: 10, a: 255), .d30_35)
    }

    func testBelow30HasNoColor() {
        XCTAssertNil(SlopeBand.below30.color)
        XCTAssertNotNil(SlopeBand.d30_35.color)
        XCTAssertNotNil(SlopeBand.above45.color)
    }
}
