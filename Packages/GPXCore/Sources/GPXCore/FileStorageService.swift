import Foundation

public enum FileStorageError: Error, Equatable {
    case sourceNotFound
    case fileNotFound
    case collisionUnresolvable
}

public struct ReorganizationEntry: Sendable, Equatable {
    public let descriptor: ActivityDescriptor
    public let currentRelativePath: String

    public init(descriptor: ActivityDescriptor, currentRelativePath: String) {
        self.descriptor = descriptor
        self.currentRelativePath = currentRelativePath
    }
}

public struct ReorganizationMove: Sendable, Equatable {
    public let activityId: UUID
    public let from: String
    public let to: String

    public init(activityId: UUID, from: String, to: String) {
        self.activityId = activityId
        self.from = from
        self.to = to
    }
}

public actor FileStorageService {
    private let container: ICloudContainer
    private var pattern: OrganizationPattern
    private let fileManager: FileManager

    public init(container: ICloudContainer, pattern: OrganizationPattern, fileManager: FileManager = .default) {
        self.container = container
        self.pattern = pattern
        self.fileManager = fileManager
    }

    public func updatePattern(_ newPattern: OrganizationPattern) {
        self.pattern = newPattern
    }

    /// Énumère les fichiers GPX/FIT/TCX déjà stockés, avec leur chemin relatif — pour reconstruire la
    /// bibliothèque depuis les fichiers en place (sans copier ni supprimer) après une perte des métadonnées.
    public func enumerateStoredFiles() async throws -> [(url: URL, relativePath: String)] {
        let root = try await container.rootURL()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let exts: Set<String> = ["gpx", "fit", "tcx"]
        var out: [(URL, String)] = []
        guard let en = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in en.allObjects where exts.contains(url.pathExtension.lowercased()) {
            let rel = url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
            out.append((url, rel))
        }
        return out
    }

    public func removeAllStoredFiles() async throws {
        let root = try await container.rootURL()
        let contents = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    public func store(sourceFile: URL, for activity: ActivityDescriptor, existingRelativePath: String? = nil) async throws -> String {
        guard fileManager.fileExists(atPath: sourceFile.path) else { throw FileStorageError.sourceNotFound }

        let computed = pattern.relativePath(for: activity)
        let finalRelative = try await resolveDestination(computed: computed, existing: existingRelativePath)
        let destination = try await container.relativeURL(for: finalRelative)

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let existingRelativePath, existingRelativePath != finalRelative {
            let oldURL = try await container.relativeURL(for: existingRelativePath)
            if fileManager.fileExists(atPath: oldURL.path) {
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: oldURL, to: destination)
                if sourceFile != oldURL {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.copyItem(at: sourceFile, to: destination)
                }
                return finalRelative
            }
        }

        if existingRelativePath == finalRelative, fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceFile, to: destination)
        return finalRelative
    }

    public func url(forRelativePath relativePath: String) async throws -> URL {
        try await container.relativeURL(for: relativePath)
    }

    /// Écrase le contenu d'un fichier source existant (ex. réécriture du GPX après enrichissement d'altitude).
    public func overwrite(relativePath: String, with data: Data) async throws {
        let url = try await container.relativeURL(for: relativePath)
        try data.write(to: url, options: .atomic)
    }

    public func delete(relativePath: String) async throws {
        let url = try await container.relativeURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { throw FileStorageError.fileNotFound }
        try fileManager.removeItem(at: url)
        try? pruneEmptyParents(of: url)
    }

    public func reorganize(_ entries: [ReorganizationEntry], to newPattern: OrganizationPattern, dryRun: Bool) async throws -> [ReorganizationMove] {
        var moves: [ReorganizationMove] = []
        var occupied: Set<String> = Set(entries.map(\.currentRelativePath))

        for entry in entries {
            let target = newPattern.relativePath(for: entry.descriptor)
            occupied.remove(entry.currentRelativePath)

            var finalTarget = target
            var attempt = 2
            while occupied.contains(finalTarget) {
                finalTarget = suffixed(target, with: attempt)
                attempt += 1
            }
            occupied.insert(finalTarget)

            if finalTarget == entry.currentRelativePath { continue }
            moves.append(ReorganizationMove(activityId: entry.descriptor.id, from: entry.currentRelativePath, to: finalTarget))
        }

        if !dryRun {
            for move in moves {
                let fromURL = try await container.relativeURL(for: move.from)
                let toURL = try await container.relativeURL(for: move.to)
                try fileManager.createDirectory(at: toURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: fromURL, to: toURL)
                try? pruneEmptyParents(of: fromURL)
            }
        }

        return moves
    }

    /// Applique une liste de déplacements déjà calculés (issus d'un dry-run). Renvoie ceux réellement effectués.
    public func reorganizeMoves(_ moves: [ReorganizationMove]) async throws -> [ReorganizationMove] {
        var applied: [ReorganizationMove] = []
        for move in moves {
            let fromURL = try await container.relativeURL(for: move.from)
            let toURL = try await container.relativeURL(for: move.to)
            guard fileManager.fileExists(atPath: fromURL.path) else { continue }
            try fileManager.createDirectory(at: toURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: toURL.path) else { continue }
            try fileManager.moveItem(at: fromURL, to: toURL)
            try? pruneEmptyParents(of: fromURL)
            applied.append(move)
        }
        return applied
    }

    private func resolveDestination(computed: String, existing: String?) async throws -> String {
        if existing == computed { return computed }
        var candidate = computed
        var attempt = 2
        while true {
            let url = try await container.relativeURL(for: candidate)
            if !fileManager.fileExists(atPath: url.path) { return candidate }
            if candidate == existing { return candidate }
            candidate = suffixed(computed, with: attempt)
            attempt += 1
            if attempt > 1000 { throw FileStorageError.collisionUnresolvable }
        }
    }

    private nonisolated func suffixed(_ path: String, with attempt: Int) -> String {
        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let base = nsPath.deletingPathExtension
        if ext.isEmpty { return "\(base)_\(attempt)" }
        return "\(base)_\(attempt).\(ext)"
    }

    private func pruneEmptyParents(of url: URL) throws {
        let rootDocsHint = "/Documents"
        var dir = url.deletingLastPathComponent()
        while dir.path.contains(rootDocsHint), dir.lastPathComponent != "Documents" {
            let contents = try fileManager.contentsOfDirectory(atPath: dir.path)
            let visible = contents.filter { !$0.hasPrefix(".") }
            if visible.isEmpty {
                try fileManager.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            } else {
                break
            }
        }
    }
}
