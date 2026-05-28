import Foundation

public struct StravaArchiveResult: Sendable {
    public let extractedFiles: [URL]
    public let workingDirectory: URL
    public let failedCount: Int
}

/// Extrait les traces d'un export « Bulk Export » Strava, fourni soit en `.zip`,
/// soit déjà décompressé (dossier). Seul le sous-dossier `activities/` est pris en compte —
/// `routes/` contient des parcours planifiés, pas des activités enregistrées.
/// Les fichiers `.gpx`/`.fit` éventuellement gzippés (`.gpx.gz`, `.fit.gz`) sont décompressés.
/// Les `.tcx` ne sont pas pris en charge par les parseurs et sont comptés comme ignorés.
public actor StravaArchiveImporter {
    public init() {}

    public func extract(zipURL: URL) throws -> StravaArchiveResult {
        let didAccess = zipURL.startAccessingSecurityScopedResource()
        defer { if didAccess { zipURL.stopAccessingSecurityScopedResource() } }

        let archive = try ZipArchive(url: zipURL)
        let workDir = try makeWorkDir()
        var ctx = ExtractContext()
        for entry in archive.entries where !entry.isDirectory {
            guard isActivityPath(entry.path) else { continue }
            process(path: entry.path, workDir: workDir, into: &ctx) {
                try archive.extract(entry)
            }
        }
        return ctx.result(workDir: workDir)
    }

    public func extract(folderURL: URL) throws -> StravaArchiveResult {
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let activitiesDir = resolveActivitiesDir(folderURL)
        let workDir = try makeWorkDir()
        var ctx = ExtractContext()
        let contents = (try? fm.contentsOfDirectory(
            at: activitiesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for fileURL in contents {
            process(path: fileURL.lastPathComponent, workDir: workDir, into: &ctx) {
                try Data(contentsOf: fileURL)
            }
        }
        return ctx.result(workDir: workDir)
    }

    private struct ExtractContext {
        var extracted: [URL] = []
        var failed = 0

        func result(workDir: URL) -> StravaArchiveResult {
            StravaArchiveResult(
                extractedFiles: extracted,
                workingDirectory: workDir,
                failedCount: failed
            )
        }
    }

    private func process(path: String, workDir: URL, into ctx: inout ExtractContext, load: () throws -> Data) {
        let isGz = path.lowercased().hasSuffix(".gz")
        let logicalName = isGz ? String(path.dropLast(3)) : path
        let ext = (logicalName as NSString).pathExtension.lowercased()

        switch ext {
        case "gpx", "fit", "tcx":
            do {
                var bytes = try load()
                if isGz { bytes = try Gzip.decompress(bytes) }
                let outName = (logicalName as NSString).lastPathComponent
                let outURL = workDir.appendingPathComponent(outName)
                try bytes.write(to: outURL)
                ctx.extracted.append(outURL)
            } catch {
                ctx.failed += 1
            }
        default:
            break
        }
    }

    private func isActivityPath(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent.hasSuffix("activities")
    }

    private func resolveActivitiesDir(_ folder: URL) -> URL {
        if folder.lastPathComponent == "activities" { return folder }
        let sub = folder.appendingPathComponent("activities", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
            return sub
        }
        return folder
    }

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("strava-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
