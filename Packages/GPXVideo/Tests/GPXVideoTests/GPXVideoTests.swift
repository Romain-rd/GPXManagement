import XCTest
import AppKit
@testable import GPXVideo

final class GPXVideoTests: XCTestCase {
    // L'encodeur H.264 exige des dimensions paires.
    func testVideoFormatDimensionsAreEven() {
        for format in VideoFormat.allCases {
            for quality in VideoQuality.allCases {
                let d = format.dimensions(base: quality.base)
                XCTAssertEqual(d.width % 2, 0, "\(format) \(quality) : largeur impaire")
                XCTAssertEqual(d.height % 2, 0, "\(format) \(quality) : hauteur impaire")
            }
        }
        XCTAssertEqual(VideoFormat.landscape.dimensions(base: 720).height, 720)
        let square = VideoFormat.square.dimensions(base: 1080)
        XCTAssertEqual(square.width, 1080)
        XCTAssertEqual(square.height, 1080)
        XCTAssertEqual(VideoFormat.portrait.dimensions(base: 1080).width, 1080)
    }

    func testDefaultLayoutsStayWithinFrame() {
        for format in VideoFormat.allCases {
            let layout = VideoLayout.defaultLayout(for: format)
            for zone in [layout.trace, layout.media, layout.profile].compactMap({ $0 }) {
                XCTAssertGreaterThanOrEqual(zone.x, 0)
                XCTAssertGreaterThanOrEqual(zone.y, 0)
                XCTAssertLessThanOrEqual(zone.x + zone.w, 1.0001, "\(format) : zone hors cadre en X")
                XCTAssertLessThanOrEqual(zone.y + zone.h, 1.0001, "\(format) : zone hors cadre en Y")
            }
        }
    }

    // Les modèles utilisateurs sont stockés en JSON (@AppStorage + iCloud KVS) : un JSON créé par une
    // ancienne version (sans transition/showHeartRate/…) doit se décoder avec les valeurs par défaut.
    func testVideoTemplateDecodingBackwardCompatible() throws {
        let legacy = """
        {"id":"user.1","name":"Mon modèle","quality":"hd720","format":"landscape",
         "layout":{"trace":{"x":0,"y":0,"w":1,"h":1},"media":{"x":0,"y":0,"w":1,"h":1}}}
        """
        let t = try JSONDecoder().decode(VideoTemplate.self, from: Data(legacy.utf8))
        XCTAssertEqual(t.id, "user.1")
        XCTAssertFalse(t.builtin)
        XCTAssertEqual(t.transition, .fade)
        XCTAssertTrue(t.showHeartRate)
        XCTAssertTrue(t.showIntro)
        XCTAssertTrue(t.showOutro)
        XCTAssertEqual(t.mapLayerRaw, "ign_scan25")
        XCTAssertNil(t.layout.profile)
    }

    func testBuiltinTemplatesHaveUniqueIds() {
        let ids = VideoTemplate.builtins.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(VideoTemplate.builtins.allSatisfy(\.builtin))
    }

    func testFittedTextShrinksToMaxWidth() {
        // Réduction en une passe proportionnelle : approximative (la largeur n'est pas
        // strictement linéaire avec la taille de police), tolérance ~15 %.
        let long = String(repeating: "GPXManagement ", count: 20)
        let unfitted = NSAttributedString(string: long, attributes: [.font: NSFont.systemFont(ofSize: 48, weight: .bold)])
        let fitted = VideoRendering.fittedText(long, baseSize: 48, weight: .bold, color: .white, maxWidth: 300)
        XCTAssertLessThan(fitted.size().width, unfitted.size().width / 2)
        XCTAssertLessThanOrEqual(fitted.size().width, 300 * 1.15)
        let short = VideoRendering.fittedText("Col d'Èze", baseSize: 48, weight: .bold, color: .white, maxWidth: 1000)
        XCTAssertEqual(short.size().width, NSAttributedString(string: "Col d'Èze", attributes: [.font: NSFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.white]).size().width, accuracy: 0.5)
    }

    func testPixelBufferWithoutPoolReturnsNil() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        var rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        XCTAssertNil(VideoRendering.pixelBuffer(from: cg, pool: nil, width: 4, height: 4))
    }
}
