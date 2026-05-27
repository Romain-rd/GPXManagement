import XCTest
@testable import GPXCore

final class FileStorageServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var container: ICloudContainer!
    private let pattern = OrganizationPattern.default

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("GPXCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        container = ICloudContainer(identifier: "test", overrideRoot: tempRoot)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.iso8601UTC.date(from: c)!
    }

    private func writeSource(_ contents: String = "fake gpx") throws -> URL {
        let url = tempRoot.appendingPathComponent("source-\(UUID().uuidString).gpx")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testStoreRoundTrip() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let source = try writeSource()
        let descriptor = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "Col d'Èze", sourceFileFormat: .gpx)

        let relative = try await service.store(sourceFile: source, for: descriptor)
        XCTAssertEqual(relative, "2025/07/2025-07-14_velo_col-d-eze.gpx")

        let url = try await service.url(forRelativePath: relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fake gpx")
    }

    func testStoreSourceNotFound() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let missing = tempRoot.appendingPathComponent("nope.gpx")
        let descriptor = ActivityDescriptor(id: UUID(), startDate: date(2025, 1, 1), activityType: .cyclingRoad, title: "X", sourceFileFormat: .gpx)
        do {
            _ = try await service.store(sourceFile: missing, for: descriptor)
            XCTFail("expected throw")
        } catch let error as FileStorageError {
            XCTAssertEqual(error, .sourceNotFound)
        }
    }

    func testCollisionSuffixed() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let a = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "Col d'Èze", sourceFileFormat: .gpx)
        let b = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "Col d'Èze", sourceFileFormat: .gpx)

        let src1 = try writeSource("A")
        let src2 = try writeSource("B")

        let p1 = try await service.store(sourceFile: src1, for: a)
        let p2 = try await service.store(sourceFile: src2, for: b)

        XCTAssertEqual(p1, "2025/07/2025-07-14_velo_col-d-eze.gpx")
        XCTAssertEqual(p2, "2025/07/2025-07-14_velo_col-d-eze_2.gpx")

        let url2 = try await service.url(forRelativePath: p2)
        XCTAssertEqual(try String(contentsOf: url2, encoding: .utf8), "B")
    }

    func testReStoreSameActivityReplacesInPlace() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let a = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "Col d'Èze", sourceFileFormat: .gpx)

        let src1 = try writeSource("v1")
        let p1 = try await service.store(sourceFile: src1, for: a)

        let src2 = try writeSource("v2")
        let p2 = try await service.store(sourceFile: src2, for: a, existingRelativePath: p1)
        XCTAssertEqual(p1, p2)
        let url = try await service.url(forRelativePath: p2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "v2")
    }

    func testDelete() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let a = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "Col d'Èze", sourceFileFormat: .gpx)
        let src = try writeSource()
        let path = try await service.store(sourceFile: src, for: a)
        let url = try await service.url(forRelativePath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try await service.delete(relativePath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteMissingFails() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        do {
            try await service.delete(relativePath: "ghost.gpx")
            XCTFail("expected throw")
        } catch let error as FileStorageError {
            XCTAssertEqual(error, .fileNotFound)
        }
    }

    func testReorganizeDryRunDoesNotMove() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let a = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "A", sourceFileFormat: .gpx)
        let pathA = try await service.store(sourceFile: try writeSource(), for: a)

        let newPattern = try OrganizationPattern(template: OrganizationPattern.presets[1].template)
        let entries = [ReorganizationEntry(descriptor: a, currentRelativePath: pathA)]
        let moves = try await service.reorganize(entries, to: newPattern, dryRun: true)

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].from, pathA)
        XCTAssertEqual(moves[0].to, "velo/2025/07/2025-07-14_a.gpx")

        let oldURL = try await service.url(forRelativePath: pathA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        let newURL = try await service.url(forRelativePath: moves[0].to)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testReorganizeRealMovesFiles() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let a = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "A", sourceFileFormat: .gpx)
        let b = ActivityDescriptor(id: UUID(), startDate: date(2025, 8, 2), activityType: .skiingTouring, title: "B", sourceFileFormat: .gpx)
        let pathA = try await service.store(sourceFile: try writeSource("A"), for: a)
        let pathB = try await service.store(sourceFile: try writeSource("B"), for: b)

        let newPattern = try OrganizationPattern(template: OrganizationPattern.presets[1].template)
        let entries = [
            ReorganizationEntry(descriptor: a, currentRelativePath: pathA),
            ReorganizationEntry(descriptor: b, currentRelativePath: pathB)
        ]
        let moves = try await service.reorganize(entries, to: newPattern, dryRun: false)

        XCTAssertEqual(moves.count, 2)
        for move in moves {
            let oldURL = try await service.url(forRelativePath: move.from)
            let newURL = try await service.url(forRelativePath: move.to)
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path), "old should be gone: \(move.from)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "new should exist: \(move.to)")
        }
    }

    func testReorganizeIdentityNoMove() async throws {
        let service = FileStorageService(container: container, pattern: pattern)
        let a = ActivityDescriptor(id: UUID(), startDate: date(2025, 7, 14), activityType: .cyclingRoad, title: "A", sourceFileFormat: .gpx)
        let pathA = try await service.store(sourceFile: try writeSource(), for: a)
        let moves = try await service.reorganize([ReorganizationEntry(descriptor: a, currentRelativePath: pathA)], to: pattern, dryRun: false)
        XCTAssertEqual(moves.count, 0)
    }
}
