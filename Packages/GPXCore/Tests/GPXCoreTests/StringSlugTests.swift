import XCTest
@testable import GPXCore

final class StringSlugTests: XCTestCase {
    func testBasicLowercase() {
        XCTAssertEqual("Col du Galibier".slugified, "col-du-galibier")
    }

    func testAccentsRemoved() {
        XCTAssertEqual("Été à Niçoise".slugified, "ete-a-nicoise")
    }

    func testMultipleSeparators() {
        XCTAssertEqual("foo --bar___baz".slugified, "foo-bar-baz")
    }

    func testTrailingPunctuation() {
        XCTAssertEqual("!!!Hello!!!".slugified, "hello")
    }

    func testEmptyFallback() {
        XCTAssertEqual("".slugified, "untitled")
        XCTAssertEqual("###".slugified, "untitled")
    }

    func testNumbersPreserved() {
        XCTAssertEqual("100km Audax 2025".slugified, "100km-audax-2025")
    }
}
