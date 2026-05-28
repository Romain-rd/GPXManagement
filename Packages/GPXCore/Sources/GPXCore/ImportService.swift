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

    public init(sourceURL: URL, parsed: ParsedTrack, stats: ActivityStats, suggestedActivityType: ActivityType?, suggestedTitle: String, duplicateOfActivityId: UUID?, fileSHA256: String, fileFormat: SourceFileFormat, origin: ActivityOrigin = .manualImport) {
        self.sourceURL = sourceURL
        self.parsed = parsed
        self.stats = stats
        self.suggestedActivityType = suggestedActivityType
        self.suggestedTitle = suggestedTitle
        self.duplicateOfActivityId = duplicateOfActivityId
        self.fileSHA256 = fileSHA256
        self.fileFormat = fileFormat
        self.origin = origin
    }
}

public struct ActivityCreationPayload: Sendable {
    public let id: UUID
    public let title: String
    public let activityType: ActivityType
    public let origin: ActivityOrigin
    public let sourceFileName: String
    public let sourceFileFormat: SourceFileFormat
    public let startDate: Date
    public let endDate: Date
    public let stats: ActivityStats
    public let trackData: Data
    public let fileSHA256: String

    public init(id: UUID, title: String, activityType: ActivityType, origin: ActivityOrigin, sourceFileName: String, sourceFileFormat: SourceFileFormat, startDate: Date, endDate: Date, stats: ActivityStats, trackData: Data, fileSHA256: String) {
        self.id = id
        self.title = title
        self.activityType = activityType
        self.origin = origin
        self.sourceFileName = sourceFileName
        self.sourceFileFormat = sourceFileFormat
        self.startDate = startDate
        self.endDate = endDate
        self.stats = stats
        self.trackData = trackData
        self.fileSHA256 = fileSHA256
    }
}

public protocol ActivityRepository: Sendable {
    func findDuplicate(sha256: String, startDate: Date, distance: Double) async throws -> UUID?
    func createActivity(_ payload: ActivityCreationPayload) async throws
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

    public func prepareImport(from url: URL, hintedActivityType: ActivityType?, hintedTitle: String?, origin: ActivityOrigin = .manualImport) async throws -> ImportProposal {
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
        let suggestedType = hintedActivityType ?? detectedType
        let parsedTitle = parsed.name?.isEmpty == false ? parsed.name! : url.deletingPathExtension().lastPathComponent
        let title = (hintedTitle?.isEmpty == false ? hintedTitle! : parsedTitle)
        let sha = Self.sha256(of: data)
        let startDate = Self.startDate(for: parsed)
        let duplicate = try await repository.findDuplicate(sha256: sha, startDate: startDate, distance: stats.distance)

        return ImportProposal(
            sourceURL: url,
            parsed: parsed,
            stats: stats,
            suggestedActivityType: suggestedType,
            suggestedTitle: title,
            duplicateOfActivityId: duplicate,
            fileSHA256: sha,
            fileFormat: format,
            origin: origin
        )
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
            startDate: startDate,
            endDate: endDate,
            stats: proposal.stats,
            trackData: trackData,
            fileSHA256: proposal.fileSHA256
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
