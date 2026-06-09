import XCTest
@testable import GPXRender
import GPXCore

final class GPXRenderTests: XCTestCase {
    // Le JSON de WebExportOptions est persisté en base (webPublishConfig) pour la republication :
    // le round-trip doit être stable, sinon « Republier » perd les réglages d'origine.
    func testWebExportOptionsRoundTrip() throws {
        var options = WebExportOptions()
        options.map = .staticImage
        options.profile = .interactive
        options.output = .publishBunny
        options.includePhotos = false
        options.includeNotes = true

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(WebExportOptions.self, from: data)
        XCTAssertEqual(decoded.map, .staticImage)
        XCTAssertEqual(decoded.profile, .interactive)
        XCTAssertEqual(decoded.output, .publishBunny)
        XCTAssertFalse(decoded.includePhotos)
        XCTAssertTrue(decoded.includeNotes)
    }

    func testWebExportOptionsDefaults() {
        let options = WebExportOptions()
        XCTAssertEqual(options.map, .interactive)
        XCTAssertEqual(options.profile, .interactive)
        XCTAssertEqual(options.output, .folder)
        XCTAssertTrue(options.includePhotos)
        XCTAssertTrue(options.includeNotes)
    }

    // La couleur SwiftUI doit suivre la palette canonique rgb de GPXCore (source unique app/PDF/web).
    func testSlopeCategoryColorMatchesCanonicalPalette() {
        for category in [SlopeCategory.gentle, .moderate, .steep, .veryStep, .descent] {
            let resolved = category.color.resolve(in: .init())
            XCTAssertEqual(Double(resolved.red), category.rgb.r, accuracy: 0.35)
            XCTAssertEqual(Double(resolved.green), category.rgb.g, accuracy: 0.35)
            XCTAssertEqual(Double(resolved.blue), category.rgb.b, accuracy: 0.35)
        }
    }
}
