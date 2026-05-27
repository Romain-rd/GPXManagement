import XCTest
@testable import GPXCore

final class OrganizationPatternTests: XCTestCase {
    private func sampleActivity(date: Date, type: ActivityType = .cyclingRoad, title: String = "Col d'Èze", format: SourceFileFormat = .gpx) -> ActivityDescriptor {
        ActivityDescriptor(
            id: UUID(),
            startDate: date,
            activityType: type,
            title: title,
            sourceFileFormat: format
        )
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12; c.minute = 0
        return Calendar.iso8601UTC.date(from: c)!
    }

    func testDefaultPattern() throws {
        let pattern = OrganizationPattern.default
        let activity = sampleActivity(date: date(2025, 7, 14))
        let path = pattern.relativePath(for: activity)
        XCTAssertEqual(path, "2025/07/2025-07-14_velo_col-d-eze.gpx")
    }

    func testActivityFirstPreset() throws {
        let pattern = try OrganizationPattern(template: OrganizationPattern.presets[1].template)
        let activity = sampleActivity(date: date(2024, 12, 1), type: .skiingTouring, title: "Pic de Bure")
        let path = pattern.relativePath(for: activity)
        XCTAssertEqual(path, "ski-rando/2024/12/2024-12-01_pic-de-bure.gpx")
    }

    func testYearThenActivityPreset() throws {
        let pattern = try OrganizationPattern(template: OrganizationPattern.presets[2].template)
        let activity = sampleActivity(date: date(2023, 3, 5), type: .motorcycle, title: "Tour des gorges")
        let path = pattern.relativePath(for: activity)
        XCTAssertEqual(path, "2023/moto/2023-03-05_tour-des-gorges.gpx")
    }

    func testSubactivityVariable() throws {
        let pattern = try OrganizationPattern(template: "{year}/{activity}-{subactivity}/{title}.{ext}")
        let activity = sampleActivity(date: date(2025, 1, 1), type: .cyclingMTB, title: "Mont Salève", format: .fit)
        let path = pattern.relativePath(for: activity)
        XCTAssertEqual(path, "2025/velo-vtt/mont-saleve.fit")
    }

    func testUnknownVariableRejected() {
        XCTAssertThrowsError(try OrganizationPattern(template: "{foo}/{ext}")) { error in
            XCTAssertEqual(error as? OrganizationPatternError, .unknownVariable("foo"))
        }
    }

    func testEmptyTemplateRejected() {
        XCTAssertThrowsError(try OrganizationPattern(template: "")) { error in
            XCTAssertEqual(error as? OrganizationPatternError, .emptyTemplate)
        }
    }

    func testMissingExtRejected() {
        XCTAssertThrowsError(try OrganizationPattern(template: "{year}/{title}")) { error in
            XCTAssertEqual(error as? OrganizationPatternError, .missingExtensionToken)
        }
    }

    func testFitExtensionUsed() throws {
        let pattern = OrganizationPattern.default
        let activity = sampleActivity(date: date(2025, 6, 10), format: .fit)
        let path = pattern.relativePath(for: activity)
        XCTAssertTrue(path.hasSuffix(".fit"))
    }
}
