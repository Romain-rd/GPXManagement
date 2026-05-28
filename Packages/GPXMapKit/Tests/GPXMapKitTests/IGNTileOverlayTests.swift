import XCTest
import MapKit
@testable import GPXMapKit

final class IGNTileOverlayTests: XCTestCase {
    func testPlanV2URL() {
        let url = IGNTileOverlay.buildURL(layerIdentifier: "GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2", format: "image/png", z: 10, x: 525, y: 370)
        XCTAssertEqual(url.host, "data.geopf.fr")
        XCTAssertEqual(url.path, "/wmts")
        XCTAssertTrue(url.query?.contains("LAYER=GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2") ?? false)
        XCTAssertTrue(url.query?.contains("TILEMATRIX=10") ?? false)
        XCTAssertTrue(url.query?.contains("TILEROW=370") ?? false)
        XCTAssertTrue(url.query?.contains("TILECOL=525") ?? false)
        XCTAssertTrue(url.query?.contains("TILEMATRIXSET=PM") ?? false)
        XCTAssertTrue(url.query?.contains("STYLE=normal") ?? false)
        XCTAssertTrue(url.query?.contains("REQUEST=GetTile") ?? false)
        XCTAssertFalse(url.query?.contains("apikey") ?? true)
    }

    func testOrthophotosJPEG() {
        let url = IGNTileOverlay.buildURL(layerIdentifier: "ORTHOIMAGERY.ORTHOPHOTOS", format: "image/jpeg", z: 12, x: 2104, y: 1483)
        XCTAssertTrue(url.query?.contains("FORMAT=image/jpeg") ?? false)
    }

    func testSlopesURL() {
        let url = IGNTileOverlay.buildURL(layerIdentifier: "GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN", format: "image/png", z: 10, x: 525, y: 370)
        XCTAssertTrue(url.query?.contains("LAYER=GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN") ?? false)
    }

    func testScan25UsesPrivateEndpointWithKey() {
        let url = IGNTileOverlay.buildURL(layerIdentifier: "GEOGRAPHICALGRIDSYSTEMS.MAPS.SCAN25TOUR", format: "image/jpeg", apiKey: "ign_scan_ws", z: 15, x: 16830, y: 11862)
        XCTAssertEqual(url.path, "/private/wmts")
        XCTAssertTrue(url.query?.contains("apikey=ign_scan_ws") ?? false)
        XCTAssertTrue(url.query?.contains("LAYER=GEOGRAPHICALGRIDSYSTEMS.MAPS.SCAN25TOUR") ?? false)
        XCTAssertTrue(url.query?.contains("FORMAT=image/jpeg") ?? false)
    }

    func testScan25LayerProperties() {
        XCTAssertTrue(MapLayer.ignScan25.isIGN)
        XCTAssertEqual(MapLayer.ignScan25.wmtsLayerIdentifier, "GEOGRAPHICALGRIDSYSTEMS.MAPS.SCAN25TOUR")
        XCTAssertEqual(MapLayer.ignScan25.discoveryAPIKey, "ign_scan_ws")
        XCTAssertEqual(MapLayer.ignScan25.wmtsFormat, "image/jpeg")
        XCTAssertEqual(MapLayer.ignScan25.maxZoom, 16)
        XCTAssertNil(MapLayer.ignPlanV2.discoveryAPIKey)
    }

    func testMapLayerProperties() {
        XCTAssertTrue(MapLayer.ignPlanV2.isIGN)
        XCTAssertFalse(MapLayer.mapkitStandard.isIGN)
        XCTAssertEqual(MapLayer.ignPlanV2.wmtsLayerIdentifier, "GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2")
        XCTAssertEqual(MapLayer.ignTopoModern.wmtsLayerIdentifier, "GEOGRAPHICALGRIDSYSTEMS.MAPS.BDUNI.J1")
        XCTAssertEqual(MapLayer.ignSlopes.wmtsLayerIdentifier, "GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN")
        XCTAssertEqual(MapLayer.ignOrthophotos.wmtsLayerIdentifier, "ORTHOIMAGERY.ORTHOPHOTOS")
        XCTAssertNil(MapLayer.mapkitStandard.wmtsLayerIdentifier)
    }

    func testOrthophotosFormatIsJpeg() {
        XCTAssertEqual(MapLayer.ignOrthophotos.wmtsFormat, "image/jpeg")
        XCTAssertEqual(MapLayer.ignPlanV2.wmtsFormat, "image/png")
    }
}
