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
    public let suggestedIsCourse: Bool

    public init(sourceURL: URL, parsed: ParsedTrack, stats: ActivityStats, suggestedActivityType: ActivityType?, suggestedTitle: String, duplicateOfActivityId: UUID?, fileSHA256: String, fileFormat: SourceFileFormat, origin: ActivityOrigin = .manualImport, stravaId: String? = nil, sourceApp: String? = nil, suggestedIsCourse: Bool = false) {
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
        self.suggestedIsCourse = suggestedIsCourse
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
    public let sensorData: Data   // série capteurs sans GPS (vide si activité GPS ou sans capteurs)
    public let fileSHA256: String
    public let stravaId: String?
    public let isCourse: Bool
    /// `true` si le parcours est modifiable (re-routage) — heuristique d'import sur la densité de points.
    public let isEditableRoute: Bool
    /// Points de passage initiaux (POI/arrêts issus des `<wpt>` d'un parcours), encodés JSON — nil si aucun.
    public let routeWaypointsData: Data?

    public init(id: UUID, title: String, activityType: ActivityType, origin: ActivityOrigin, sourceFileName: String, sourceFileFormat: SourceFileFormat, sourceApp: String? = nil, startDate: Date, endDate: Date, stats: ActivityStats, trackData: Data, sensorData: Data = Data(), fileSHA256: String, stravaId: String? = nil, isCourse: Bool = false, isEditableRoute: Bool = false, routeWaypointsData: Data? = nil) {
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
        self.sensorData = sensorData
        self.fileSHA256 = fileSHA256
        self.stravaId = stravaId
        self.isCourse = isCourse
        self.isEditableRoute = isEditableRoute
        self.routeWaypointsData = routeWaypointsData
    }
}

public struct ReprocessResult: Sendable {
    public let stats: ActivityStats
    public let startDate: Date
    public let endDate: Date
    public let trackData: Data
    public let sensorData: Data
    public let sourceApp: String?
    public let suggestedType: ActivityType?

    public init(stats: ActivityStats, startDate: Date, endDate: Date, trackData: Data, sensorData: Data = Data(), sourceApp: String?, suggestedType: ActivityType?) {
        self.stats = stats
        self.startDate = startDate
        self.endDate = endDate
        self.trackData = trackData
        self.sensorData = sensorData
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
            sourceApp: Self.resolveSourceApp(parsedCreator: parsed.creator, origin: origin),
            suggestedIsCourse: Self.detectIsCourse(parsed: parsed)
        )
    }

    /// Un parcours (préparation) est un tracé dessiné : il a des points GPS mais aucun horodatage réel.
    /// Une activité enregistrée porte toujours des timestamps par point.
    /// En-dessous de ce nombre de points, un parcours est considéré « dessiné » (modifiable) plutôt que GR fidèle.
    public static let editableRoutePointThreshold = 100

    public static func detectIsCourse(parsed: ParsedTrack) -> Bool {
        !parsed.points.isEmpty && !parsed.points.contains { $0.timestamp != nil }
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
            sensorData: Self.encodeSensors(parsed),
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

    public func confirmImport(_ proposal: ImportProposal, activityType: ActivityType, title: String, isCourse: Bool? = nil) async throws -> UUID {
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

        // Pour un parcours, on conserve les <wpt> du fichier comme points de passage (POI / arrêts d'étape).
        let resolvedIsCourse = isCourse ?? proposal.suggestedIsCourse
        // Heuristique : un parcours à peu de points est dessiné (modifiable) ; dense = GR fidèle (verrouillé).
        let isEditableRoute = resolvedIsCourse && proposal.parsed.points.count < Self.editableRoutePointThreshold
        let routeWaypointsData: Data? = (resolvedIsCourse && !proposal.parsed.waypoints.isEmpty)
            ? RouteWaypointCodec.encode(Self.routeWaypoints(from: proposal.parsed))
            : nil

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
            sensorData: Self.encodeSensors(proposal.parsed),
            fileSHA256: proposal.fileSHA256,
            stravaId: proposal.stravaId,
            isCourse: resolvedIsCourse,
            isEditableRoute: isEditableRoute,
            routeWaypointsData: routeWaypointsData
        )

        try await repository.createActivity(payload)
        return id
    }

    /// Points de passage initiaux d'un parcours : ancrages de routage dérivés du tracé (`.shaping`) FUSIONNÉS avec les
    /// `<wpt>` du fichier (POI / arrêts d'étape), insérés à leur position dans le tracé. Un `<wpt>` est `.stageStop` s'il
    /// est proche du départ/arrivée ou marqué `stage-stop` (notre export), sinon `.poi`.
    static func routeWaypoints(from parsed: ParsedTrack) -> [RouteWaypoint] {
        let points = parsed.points
        let start = points.first
        let end = points.last
        let pois: [(wp: RouteWaypoint, index: Int)] = parsed.waypoints.map { w in
            let isStop = w.type == "stage-stop" || isNear(w, start) || isNear(w, end)
            let wp = RouteWaypoint(latitude: w.latitude, longitude: w.longitude, name: w.name,
                                   role: isStop ? .stageStop : .poi)
            let idx = points.isEmpty ? 0 : RouteWaypoint.nearestIndex(latitude: w.latitude, longitude: w.longitude, in: points)
            return (wp, idx)
        }
        guard points.count >= 2 else { return pois.map(\.wp) }

        let poiIndices = pois.map(\.index)
        // Ancrages dérivés, en écartant ceux qui coïncident (à 1 point près) avec un POI pour éviter les doublons.
        let anchors: [(wp: RouteWaypoint, index: Int)] = RouteWaypoint.derivedAnchors(from: points)
            .map { ($0, RouteWaypoint.nearestIndex(latitude: $0.latitude, longitude: $0.longitude, in: points)) }
            .filter { a in !poiIndices.contains { abs($0 - a.index) <= 1 } }

        return (anchors + pois).sorted { $0.index < $1.index }.map(\.wp)
    }

    private static func isNear(_ w: ParsedWaypoint, _ p: TrackPoint?, within meters: Double = 100) -> Bool {
        guard let p else { return false }
        return GeoMath.haversine(lat1: w.latitude, lon1: w.longitude, lat2: p.latitude, lon2: p.longitude) <= meters
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

    private static func encodeSensors(_ parsed: ParsedTrack) -> Data {
        guard !parsed.sensorSamples.isEmpty else { return Data() }
        return SensorSeriesCodec.encode(SensorSeries(samples: parsed.sensorSamples)) ?? Data()
    }

    private static func makeStats(for parsed: ParsedTrack) -> ActivityStats {
        guard parsed.points.isEmpty else {
            return ActivityStatsCalculator.compute(points: parsed.points)
        }
        // Activité sans tracé GPS (ex. séance enregistrée sans position) : on reprend les stats du
        // résumé de séance (FIT), avec repli sur la série de capteurs pour la FC ; vitesse moy. calculée à défaut.
        let s = parsed.summary
        let duration = s?.duration ?? 0
        let distance = s?.distance ?? 0
        let avgSpeed = s?.avgSpeed ?? (duration > 0 ? distance / duration : 0)
        let hrStats = parsed.sensorSamples.isEmpty ? nil : SensorSeries(samples: parsed.sensorSamples).heartRateStats
        return ActivityStats(
            distance: distance,
            duration: duration,
            movingDuration: duration,
            elevationGain: s?.elevationGain ?? 0,
            elevationLoss: s?.elevationLoss ?? 0,
            avgSpeed: avgSpeed,
            maxSpeed: s?.maxSpeed ?? 0,
            maxSlope: 0,
            avgHeartRate: s?.avgHeartRate ?? hrStats?.avg,
            maxHeartRate: s?.maxHeartRate ?? hrStats?.max,
            boundingBox: .zero
        )
    }

    private static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
