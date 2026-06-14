import XCTest
@testable import GPXCore

final class MediaStateTests: XCTestCase {
    func testKeyCombinesFileAndRoundedDate() {
        XCTAssertEqual(MediaPlacement.key(file: "IMG_5962.MOV", date: 1748349128.7), "IMG_5962.MOV|1748349128")
        XCTAssertEqual(MediaPlacement.key(file: "IMG_1.JPG", date: nil), "IMG_1.JPG|")
    }

    func testRoundTripKeepsOnlyExplicitEntries() {
        let kept = MediaPlacement(file: "A.JPG", date: 100, onMap: false, posMeters: 1200)
        let defaulted = MediaPlacement(file: "B.JPG", date: 200) // tout par défaut → écarté
        let data = MediaStateCodec.encode([kept.key: kept, defaulted.key: defaulted])
        let decoded = MediaStateCodec.decode(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[kept.key], kept)
        XCTAssertNil(decoded[defaulted.key])
    }

    func testEmptyEncodesToNil() {
        XCTAssertNil(MediaStateCodec.encode([:]))
        XCTAssertNil(MediaStateCodec.encode(["x": MediaPlacement(file: "x", date: nil)]))
        XCTAssertTrue(MediaStateCodec.decode(nil).isEmpty)
    }
}
