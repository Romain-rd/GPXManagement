import XCTest
@testable import GPXCore

final class ZipArchiveTests: XCTestCase {
    func testReadsStoredEntries() throws {
        let payloadA = Data("hello strava".utf8)
        let payloadB = Data("second file".utf8)
        let zip = ZipBuilder.storedZip([("a.txt", payloadA), ("nested/b.txt", payloadB)])

        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(archive.entries.map(\.path).sorted(), ["a.txt", "nested/b.txt"])

        let a = try archive.extract(archive.entries.first { $0.path == "a.txt" }!)
        let b = try archive.extract(archive.entries.first { $0.path == "nested/b.txt" }!)
        XCTAssertEqual(a, payloadA)
        XCTAssertEqual(b, payloadB)
    }

    func testInflateRawDeflateRoundTrip() throws {
        let original = Data((0..<5000).map { UInt8($0 % 251) })
        let deflated = try (original as NSData).compressed(using: .zlib) as Data
        let restored = try ZipArchive.inflateRawDeflate(deflated, expectedSize: original.count)
        XCTAssertEqual(restored, original)
    }

    func testGzipDecompress() throws {
        let original = Data("<gpx>trace de test avec accents éàü</gpx>".utf8)
        let gz = try ZipBuilder.gzip(original)
        let restored = try Gzip.decompress(gz)
        XCTAssertEqual(restored, original)
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip".utf8)))
    }
}

final class StravaArchiveImporterTests: XCTestCase {
    private let sampleGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1"><trk><name>Sortie</name><type>cycling</type><trkseg>
      <trkpt lat="43.70" lon="7.26"><ele>50</ele><time>2025-07-14T08:00:00Z</time></trkpt>
      <trkpt lat="43.71" lon="7.27"><ele>120</ele><time>2025-07-14T08:10:00Z</time></trkpt>
    </trkseg></trk></gpx>
    """

    func testExtractsGpxAndGzippedGpxAndSkipsTcx() async throws {
        let gpxData = Data(sampleGPX.utf8)
        let zip = ZipBuilder.storedZip([
            ("activities/100.gpx", gpxData),
            ("activities/200.gpx.gz", try ZipBuilder.gzip(gpxData)),
            ("activities/300.tcx", Data("<TrainingCenterDatabase/>".utf8)),
            ("activities.csv", Data("id,name\n".utf8)),
            ("media/photo.jpg", Data([0xFF, 0xD8, 0xFF])),
        ])
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("strava-test-\(UUID().uuidString).zip")
        try zip.write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let importer = StravaArchiveImporter()
        let result = try await importer.extract(zipURL: zipURL)
        defer { try? FileManager.default.removeItem(at: result.workingDirectory) }

        XCTAssertEqual(result.extractedFiles.count, 2)
        XCTAssertEqual(result.unsupportedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(Set(result.extractedFiles.map { $0.lastPathComponent }), ["100.gpx", "200.gpx"])

        for url in result.extractedFiles {
            let parsed = try GPXParser().parse(url: url)
            XCTAssertEqual(parsed.points.count, 2)
        }
    }

    func testFolderImportScansActivitiesAndIgnoresRoutes() async throws {
        let gpxData = Data(sampleGPX.utf8)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let activities = root.appendingPathComponent("activities", isDirectory: true)
        let routes = root.appendingPathComponent("routes", isDirectory: true)
        try fm.createDirectory(at: activities, withIntermediateDirectories: true)
        try fm.createDirectory(at: routes, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try gpxData.write(to: activities.appendingPathComponent("100.gpx"))
        try ZipBuilder.gzip(gpxData).write(to: activities.appendingPathComponent("200.gpx.gz"))
        try Data("<TrainingCenterDatabase/>".utf8).write(to: activities.appendingPathComponent("300.tcx"))
        // Un parcours planifié — ne doit PAS être importé.
        try gpxData.write(to: routes.appendingPathComponent("plan.gpx"))

        let importer = StravaArchiveImporter()
        let result = try await importer.extract(folderURL: root)
        defer { try? fm.removeItem(at: result.workingDirectory) }

        XCTAssertEqual(Set(result.extractedFiles.map { $0.lastPathComponent }), ["100.gpx", "200.gpx"])
        XCTAssertEqual(result.unsupportedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
    }
}

private enum ZipBuilder {
    static func storedZip(_ files: [(String, Data)]) -> Data {
        var local = Data()
        var central = Data()
        var offsets: [Int] = []

        for (name, payload) in files {
            offsets.append(local.count)
            let nameBytes = Data(name.utf8)
            appendU32(&local, 0x04034b50)
            appendU16(&local, 20)            // version needed
            appendU16(&local, 0)             // flags
            appendU16(&local, 0)             // method = stored
            appendU16(&local, 0); appendU16(&local, 0) // time, date
            appendU32(&local, 0)             // crc (ignored by reader)
            appendU32(&local, UInt32(payload.count)) // compressed
            appendU32(&local, UInt32(payload.count)) // uncompressed
            appendU16(&local, UInt16(nameBytes.count))
            appendU16(&local, 0)             // extra len
            local.append(nameBytes)
            local.append(payload)
        }

        for (i, (name, payload)) in files.enumerated() {
            let nameBytes = Data(name.utf8)
            appendU32(&central, 0x02014b50)
            appendU16(&central, 20)          // version made by
            appendU16(&central, 20)          // version needed
            appendU16(&central, 0)           // flags
            appendU16(&central, 0)           // method
            appendU16(&central, 0); appendU16(&central, 0) // time, date
            appendU32(&central, 0)           // crc
            appendU32(&central, UInt32(payload.count))
            appendU32(&central, UInt32(payload.count))
            appendU16(&central, UInt16(nameBytes.count))
            appendU16(&central, 0)           // extra
            appendU16(&central, 0)           // comment
            appendU16(&central, 0)           // disk start
            appendU16(&central, 0)           // internal attrs
            appendU32(&central, 0)           // external attrs
            appendU32(&central, UInt32(offsets[i]))
            central.append(nameBytes)
        }

        var out = local
        let cdOffset = out.count
        out.append(central)
        let cdSize = central.count

        appendU32(&out, 0x06054b50)
        appendU16(&out, 0); appendU16(&out, 0)
        appendU16(&out, UInt16(files.count))
        appendU16(&out, UInt16(files.count))
        appendU32(&out, UInt32(cdSize))
        appendU32(&out, UInt32(cdOffset))
        appendU16(&out, 0)
        return out
    }

    static func gzip(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(try (data as NSData).compressed(using: .zlib) as Data)
        appendU32(&out, 0) // crc (ignored)
        appendU32(&out, UInt32(data.count))
        return out
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
