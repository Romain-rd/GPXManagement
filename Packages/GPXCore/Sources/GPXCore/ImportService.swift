import Foundation
import CryptoKit

public enum ImportError: Error, Equatable {
    case unsupportedFormat(String)
    case fitNotYetSupported
    case fileNotReadable
    case noTrackData
}

public struct ImportProposal: Sendable {
    public let sourceURL: URL
    public let parsed: ParsedTrack
    public let stats: ActivityStats
    public let suggestedActivityType: ActivityType?
    public let suggestedTitle: String
    public let duplicateOfActivityId: UUID?
    public let fileSHA256: String
    public let fileFormat: SourceFileFormat
    public let origin: ActivityOrigin
    public let stravaId: String?
    public let sourceApp: String?

    public init(sourceURL: URL, parsed: ParsedTrack, stats: ActivityStats, suggestedActivityType: ActivityType?, suggestedTitle: String, duplicateOfActivityId: UUID?, fileSHA256: String, fileFormat: SourceFileFormat, origin: ActivityOrigin = .manualImport, stravaId: String? = nil, sourceApp: String? = nil) {
        self.sourceURL = sourceURL
        self.parsed = parsed
        self.stats = stats
        self.suggestedActivityType = suggestedActivityType
        self.suggestedTitle = suggestedTitle
        self.duplicateOfActivityId = duplicateOfActivityId
        self.fileSHA256 = fileSHA256
        self.fileFormat = fileFormat
        self.origin = origin
        self.stravaId = stravaId
        self.sourceApp = sourceApp
    }
}

public struct ActivityCreationPayload: Sendable {
    public let id: UUID
    public let title: String
    public let activityType: ActivityType
    public let origin: ActivityOrigin
    public let sourceFileName: String
    public let sourceFileFormat: SourceFileFormat
    public let sourceApp: String?
    public let startDate: Date
    public let endDate: Date
    public let stats: ActivityStats
    public let trackData: Data
    public let fileSHA256: String
    public let stravaId: String?

    public init(id: UUID, title: String, activityType: ActivityType, origin: ActivityOrigin, sourceFileName: String, sourceFileFormat: SourceFileFormat, sourceApp: String? = nil, startDate: Date, endDate: Date, stats: ActivityStats, trackData: Data, fileSHA256: String, stravaId: String? = nil) {
        self.id = id
        self.title = title
        self.activityType = activityType
        self.origin = origin
        self.sourceFileName = sourceFileName
        self.sourceFileFormat = sourceFileFormat
        self.sourceApp = sourceApp
        self.startDate = startDate
        self.endDate = endDate
        self.stats = stats
        self.trackData = trackData
        self.fileSHA256 = fileSHA256
        self.stravaId = stravaId
    }
}

public struct ReprocessResult: Sendable {
    public let stats: ActivityStats
    public let startDate: Date
    public let endDate: Date
    public let trackData: Data
    public let sourceApp: String?
    public let suggestedType: ActivityType?

    public init(stats: ActivityStats, startDate: Date, endDate: Date, trackData: Data, sourceApp: String?, suggestedType: ActivityType?) {
        self.stats = stats
        self.startDate = startDate
        self.endDate = endDate
        self.trackData = trackData
        self.sourceApp = sourceApp
        self.suggestedType = suggestedType
    }
}

public protocol ActivityRepository: Sendable {
    func findDuplicate(sha256: String, startDate: Date, distance: Double) async throws -> UUID?
    func findActivity(stravaId: String) async throws -> UUID?
    func createActivity(_ payload: ActivityCreationPayload) async throws
}

public extension ActivityRepository {
    /// Par défaut, pas de recherche par identifiant Strava (les mocks/tests n'ont pas à l'implémenter).
    func findActivity(stravaId: String) async throws -> UUID? { nil }
}

public actor ImportService {
    private let storage: FileStorageService
    private let repository: ActivityRepository
    private let gpxParser: GPXParser
    private let fitParser: FITParser
    private let tcxParser: TCXParser

    public init(storage: FileStorageService, repository: ActivityRepository) {
        self.storage = storage
        self.repository = repository
        self.gpxParser = GPXParser()
        self.fitParser = FITParser()
        self.tcxParser = TCXParser()
    }

    public func prepareImport(from url: URL) async throws -> ImportProposal {
        try await prepareImport(from: url, hintedActivityType: nil, hintedTitle: nil)
    }

    public func prepareImport(from url: URL, hintedActivityType: ActivityType?, hintedTitle: String?, origin: ActivityOrigin = .manualImport, stravaId: String? = nil) async throws -> ImportProposal {
        let format = try detectFormat(url: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.fileNotReadable
        }

        let parsed: ParsedTrack
        switch format {
        case .gpx:
            parsed = try gpxParser.parse(data: data)
        case .fit:
            parsed = try fitParser.parse(data: data)
        case .tcx:
            parsed = try tcxParser.parse(data: data)
        }

        let stats = Self.makeStats(for: parsed)
        let detectedType = ActivityTypeDetector.detect(hint: parsed.activityHint, fileFormat: format)
            ?? ActivityTypeDetector.detect(source: ActivitySource(rawCreator: parsed.creator))
        let suggestedType = hintedActivityType ?? detectedType
        let parsedTitle = parsed.name?.isEmpty == false ? parsed.name! : url.deletingPathExtension().lastPathComponent
        let title = (hintedTitle?.isEmpty == false ? hintedTitle! : parsedTitle)
        let sha = Self.sha256(of: data)
        let startDate = Self.startDate(for: parsed)
        // Déduplication : par identifiant Strava en priorité (fiable), sinon par date + distance.
        var duplicate: UUID?
        if let stravaId {
            duplicate = try await repository.findActivity(stravaId: stravaId)
        }
        if duplicate == nil {
            duplicate = try await repository.findDuplicate(sha256: sha, startDate: startDate, distance: stats.distance)
        }

        return ImportProposal(
            sourceURL: url,
            parsed: parsed,
            stats: stats,
            suggestedActivityType: suggestedType,
            suggestedTitle: title,
            duplicateOfActivityId: duplicate,
            fileSHA256: sha,
            fileFormat: format,
            origin: origin,
            stravaId: stravaId,
            sourceApp: Self.resolveSourceApp(parsedCreator: parsed.creator, origin: origin)
        )
    }

    /// Détermine l'application source à enregistrer. Les fichiers générés en interne (sync API Strava
    /// via GPXWriter) ne portent pas de creator exploitable : on retombe alors sur l'origine.
    public static func resolveSourceApp(parsedCreator: String?, origin: ActivityOrigin) -> String? {
        if let creator = parsedCreator?.trimmingCharacters(in: .whitespacesAndNewlines),
           !creator.isEmpty,
           creator.caseInsensitiveCompare("GPXManagement") != .orderedSame {
            return creator
        }
        return origin == .strava ? "Strava" : nil
    }

    /// Re-parse un fichier déjà stocké et recalcule tracé + stats (corrige les imports antérieurs,
    /// ex. tracés Scenic pollués par les waypoints départ/arrivée).
    public func reprocess(fileAt url: URL, origin: ActivityOrigin) async throws -> ReprocessResult {
        let format = try detectFormat(url: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.fileNotReadable
        }
        let parsed: ParsedTrack
        switch format {
        case .gpx: parsed = try gpxParser.parse(data: data)
        case .fit: parsed = try fitParser.parse(data: data)
        case .tcx: parsed = try tcxParser.parse(data: data)
        }
        let stats = Self.makeStats(for: parsed)
        let startDate = Self.startDate(for: parsed)
        let endDate = parsed.endDate
            ?? parsed.summary?.duration.map { startDate.addingTimeInterval($0) }
            ?? startDate
        let trackData = try TrackPointCodec.encode(parsed.points)
        return ReprocessResult(
            stats: stats,
            startDate: startDate,
            endDate: endDate,
            trackData: trackData,
            sourceApp: Self.resolveSourceApp(parsedCreator: parsed.creator, origin: origin),
            suggestedType: ActivityTypeDetector.detect(hint: parsed.activityHint, fileFormat: format)
                ?? ActivityTypeDetector.detect(source: ActivitySource(rawCreator: parsed.creator))
        )
    }

    /// Relit un fichier source déjà stocké pour en extraire l'application source (recalcul a posteriori).
    public func detectSourceApp(at url: URL, origin: ActivityOrigin) async throws -> String? {
        let format = try detectFormat(url: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.fileNotReadable
        }
        let parsed: ParsedTrack
        switch format {
        case .gpx: parsed = try gpxParser.parse(data: data)
        case .fit: parsed = try fitParser.parse(data: data)
        case .tcx: parsed = try tcxParser.parse(data: data)
        }
        return Self.resolveSourceApp(parsedCreator: parsed.creator, origin: origin)
    }

    public func confirmImport(_ proposal: ImportProposal, activityType: ActivityType, title: String) async throws -> UUID {
        let id = UUID()
        let startDate = Self.startDate(for: proposal.parsed)
        let endDate = proposal.parsed.endDate
            ?? proposal.parsed.summary?.duration.map { startDate.addingTimeInterval($0) }
            ?? startDate

        let descriptor = ActivityDescriptor(
            id: id,
            startDate: startDate,
            activityType: activityType,
            title: title,
            sourceFileFormat: proposal.fileFormat
        )

        let relativePath = try await storage.store(sourceFile: proposal.sourceURL, for: descriptor)
        let trackData = try TrackPointCodec.encode(proposal.parsed.points)

        let payload = ActivityCreationPayload(
            id: id,
            title: title,
            activityType: activityType,
            origin: proposal.origin,
            sourceFileName: relativePath,
            sourceFileFormat: proposal.fileFormat,
            sourceApp: proposal.sourceApp,
            startDate: startDate,
            endDate: endDate,
            stats: proposal.stats,
            trackData: trackData,
            fileSHA256: proposal.fileSHA256,
            stravaId: proposal.stravaId
        )

        try await repository.createActivity(payload)
        return id
    }

    private func detectFormat(url: URL) throws -> SourceFileFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "gpx": return .gpx
        case "fit": return .fit
        case "tcx": return .tcx
        default: throw ImportError.unsupportedFormat(ext)
        }
    }

    private static func startDate(for parsed: ParsedTrack) -> Date {
        parsed.startDate ?? parsed.summary?.startDate ?? Date()
    }

    private static func makeStats(for parsed: ParsedTrack) -> ActivityStats {
        guard parsed.points.isEmpty else {
            return ActivityStatsCalculator.compute(points: parsed.points)
        }
        let duration = parsed.summary?.duration ?? 0
        return ActivityStats(
            distance: parsed.summary?.distance ?? 0,
            duration: duration,
            movingDuration: duration,
            elevationGain: 0,
            elevationLoss: 0,
            avgSpeed: 0,
            maxSpeed: 0,
            maxSlope: 0,
            avgHeartRate: nil,
            maxHeartRate: nil,
            boundingBox: .zero
        )
    }

    private static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
