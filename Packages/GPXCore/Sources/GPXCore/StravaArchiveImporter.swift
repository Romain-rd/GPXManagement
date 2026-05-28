import Foundation

public struct StravaArchiveResult: Sendable {
    public let extractedFiles: [URL]
    public let workingDirectory: URL
    public let unsupportedCount: Int
    public let failedCount: Int
}

/// Extrait les traces d'une archive « Bulk Export » Strava (.zip).
/// Le dossier `activities/` contient des `.gpx`/`.fit` éventuellement gzippés (`.gpx.gz`, `.fit.gz`).
/// Les fichiers `.tcx` ne sont pas pris en charge par les parseurs et sont comptés comme ignorés.
public actor StravaArchiveImporter {
    public init() {}

    public func extract(zipURL: URL) throws -> StravaArchiveResult {
        let didAccess = zipURL.startAccessingSecurityScopedResource()
        defer { if didAccess { zipURL.stopAccessingSecurityScopedResource() } }

        let archive = try ZipArchive(url: zipURL)
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("strava-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        var extracted: [URL] = []
        var unsupported = 0
        var failed = 0

        for entry in archive.entries where !entry.isDirectory {
            let isGz = entry.path.lowercased().hasSuffix(".gz")
            let logicalName = isGz ? String(entry.path.dropLast(3)) : entry.path
            let ext = (logicalName as NSString).pathExtension.lowercased()

            switch ext {
            case "gpx", "fit":
                do {
                    var bytes = try archive.extract(entry)
                    if isGz { bytes = try Gzip.decompress(bytes) }
                    let outName = (logicalName as NSString).lastPathComponent
                    let outURL = workDir.appendingPathComponent(outName)
                    try bytes.write(to: outURL)
                    extracted.append(outURL)
                } catch {
                    failed += 1
                }
            case "tcx":
                unsupported += 1
            default:
                break
            }
        }

        return StravaArchiveResult(
            extractedFiles: extracted,
            workingDirectory: workDir,
            unsupportedCount: unsupported,
            failedCount: failed
        )
    }
}
