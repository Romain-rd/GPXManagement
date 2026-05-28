import XCTest
@testable import GPXCore

private actor MockRepository: ActivityRepository {
    var duplicatesBySHA: [String: UUID] = [:]
    var created: [ActivityCreationPayload] = []

    func setDuplicate(_ sha: String, id: UUID) {
        duplicatesBySHA[sha] = id
    }

    func findDuplicate(sha256: String, startDate: Date, distance: Double) async throws -> UUID? {
        duplicatesBySHA[sha256]
    }

    func createActivity(_ payload: ActivityCreationPayload) async throws {
        created.append(payload)
    }
}

final class ImportServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var container: ICloudContainer!
    private var storage: FileStorageService!
    private var repository: MockRepository!
    private var service: ImportService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        container = ICloudContainer(identifier: "test", overrideRoot: tempRoot)
        storage = FileStorageService(container: container, pattern: .default)
        repository = MockRepository()
        service = ImportService(storage: storage, repository: repository)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    private func writeGPX(_ content: String, name: String = "ride.gpx") throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let sampleGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1">
      <trk>
        <name>Col d'Èze</name>
        <type>cycling</type>
        <trkseg>
          <trkpt lat="43.700" lon="7.262"><ele>50.0</ele><time>2025-07-14T08:00:00Z</time></trkpt>
          <trkpt lat="43.715" lon="7.270"><ele>120.0</ele><time>2025-07-14T08:10:00Z</time></trkpt>
          <trkpt lat="43.720" lon="7.275"><ele>180.0</ele><time>2025-07-14T08:20:00Z</time></trkpt>
        </trkseg>
      </trk>
    </gpx>
    """

    func testPrepareImportFromGPX() async throws {
        let url = try writeGPX(sampleGPX)
        let proposal = try await service.prepareImport(from: url)

        XCTAssertEqual(proposal.suggestedTitle, "Col d'Èze")
        XCTAssertEqual(proposal.suggestedActivityType, .cyclingRoad)
        XCTAssertEqual(proposal.fileFormat, .gpx)
        XCTAssertNil(proposal.duplicateOfActivityId)
        XCTAssertGreaterThan(proposal.stats.distance, 1000)
        XCTAssertEqual(proposal.parsed.points.count, 3)
        XCTAssertEqual(proposal.fileSHA256.count, 64)
    }

    func testPrepareImportDetectsDuplicate() async throws {
        let url = try writeGPX(sampleGPX)
        let firstProposal = try await service.prepareImport(from: url)
        let knownId = UUID()
        await repository.setDuplicate(firstProposal.fileSHA256, id: knownId)

        let second = try await service.prepareImport(from: url)
        XCTAssertEqual(second.duplicateOfActivityId, knownId)
    }

    func testConfirmImportCreatesActivityAndStoresFile() async throws {
        let url = try writeGPX(sampleGPX)
        let proposal = try await service.prepareImport(from: url)
        let id = try await service.confirmImport(proposal, activityType: .cyclingRoad, title: "Mon col d'Èze")

        let created = await repository.created
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].id, id)
        XCTAssertEqual(created[0].title, "Mon col d'Èze")
        XCTAssertEqual(created[0].activityType, .cyclingRoad)
        XCTAssertEqual(created[0].origin, .manualImport)
        XCTAssertTrue(created[0].sourceFileName.hasSuffix(".gpx"))
        XCTAssertGreaterThan(created[0].trackData.count, 0)

        let storedURL = try await storage.url(forRelativePath: created[0].sourceFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        let decoded = try TrackPointCodec.decode(created[0].trackData)
        XCTAssertEqual(decoded.count, 3)
    }

    func testTracklessFITImportsWithSessionMetadata() async throws {
        // Session FIT (msg 18) sport=31 (escalade), 0 record GPS, durée 1h.
        var body: [UInt8] = [0x40, 0, 0, 18, 0, 4,
                             2, 4, 0x86, 5, 1, 0x00, 7, 4, 0x86, 9, 4, 0x86,
                             0x00]
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        body += u32(1000) + [31] + u32(3_600_000) + u32(0)
        var header: [UInt8] = [12, 0x10, 0, 0]
        header += u32(UInt32(body.count))
        header += [0x2E, 0x46, 0x49, 0x54]
        let url = tempRoot.appendingPathComponent("climb.fit")
        try Data(header + body + [0, 0]).write(to: url)

        let proposal = try await service.prepareImport(from: url)
        XCTAssertTrue(proposal.parsed.points.isEmpty)
        XCTAssertEqual(proposal.suggestedActivityType, .climbing)
        XCTAssertEqual(proposal.stats.duration, 3600)

        let id = try await service.confirmImport(proposal, activityType: .climbing, title: "Séance escalade")
        let created = await repository.created
        let activity = try XCTUnwrap(created.first { $0.id == id })
        XCTAssertEqual(activity.activityType, .climbing)
        XCTAssertEqual(activity.trackData.count, try TrackPointCodec.encode([]).count)
        // Date issue de la session (FIT epoch + 1000), pas la date d'import.
        XCTAssertEqual(activity.startDate.timeIntervalSince1970, 631_065_600 + 1000, accuracy: 0.5)
    }

    func testFITMalformedRejected() async throws {
        let url = tempRoot.appendingPathComponent("broken.fit")
        try Data([0, 1, 2, 3]).write(to: url)
        do {
            _ = try await service.prepareImport(from: url)
            XCTFail("expected throw")
        } catch is FITParseError {
            // ok
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnsupportedExtensionRejected() async throws {
        let url = tempRoot.appendingPathComponent("ride.kml")
        try Data().write(to: url)
        do {
            _ = try await service.prepareImport(from: url)
            XCTFail("expected throw")
        } catch let error as ImportError {
            if case .unsupportedFormat = error { /* ok */ } else { XCTFail("wrong error: \(error)") }
        }
    }

    func testTitleFallsBackToFileName() async throws {
        let noNameGPX = """
        <?xml version="1.0"?>
        <gpx version="1.1"><trk><trkseg>
          <trkpt lat="45.0" lon="6.0"><time>2025-01-01T10:00:00Z</time></trkpt>
          <trkpt lat="45.001" lon="6.001"><time>2025-01-01T10:00:10Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let url = try writeGPX(noNameGPX, name: "my-fancy-trace.gpx")
        let proposal = try await service.prepareImport(from: url)
        XCTAssertEqual(proposal.suggestedTitle, "my-fancy-trace")
    }
}
