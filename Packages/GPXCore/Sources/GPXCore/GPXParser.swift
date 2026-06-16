import Foundation

/// Marqueur `<wpt>` d'un GPX (départ/arrivée, POI, col, refuge) : n'appartient pas au tracé dense.
public struct ParsedWaypoint: Sendable, Equatable {
    public let name: String?
    public let latitude: Double
    public let longitude: Double
    public let type: String?
    public let symbol: String?

    public init(name: String?, latitude: Double, longitude: Double, type: String? = nil, symbol: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.type = type
        self.symbol = symbol
    }
}

public struct ParsedTrack: Sendable, Equatable {
    public let name: String?
    public let activityHint: String?
    public let startDate: Date?
    public let endDate: Date?
    public let points: [TrackPoint]
    /// Marqueurs `<wpt>` du fichier (POI, refuges…), conservés pour les parcours. Vide pour FIT/TCX.
    public let waypoints: [ParsedWaypoint]
    /// Mesures capteurs horodatées des échantillons SANS position (FC, altitude…) — sinon perdues.
    /// Vide pour une activité GPS (les capteurs sont déjà dans `points`).
    public let sensorSamples: [SensorSample]
    public let summary: Summary?
    /// Chaîne brute de l'application/appareil source (creator GPX, fabricant FIT, Author/Creator TCX).
    public let creator: String?

    public struct Summary: Sendable, Equatable {
        public let startDate: Date?
        public let duration: Double?
        public let distance: Double?
        public let avgSpeed: Double?       // m/s
        public let maxSpeed: Double?       // m/s
        public let avgHeartRate: Double?
        public let maxHeartRate: Double?
        public let elevationGain: Double?
        public let elevationLoss: Double?

        public init(startDate: Date?, duration: Double?, distance: Double?,
                    avgSpeed: Double? = nil, maxSpeed: Double? = nil,
                    avgHeartRate: Double? = nil, maxHeartRate: Double? = nil,
                    elevationGain: Double? = nil, elevationLoss: Double? = nil) {
            self.startDate = startDate
            self.duration = duration
            self.distance = distance
            self.avgSpeed = avgSpeed
            self.maxSpeed = maxSpeed
            self.avgHeartRate = avgHeartRate
            self.maxHeartRate = maxHeartRate
            self.elevationGain = elevationGain
            self.elevationLoss = elevationLoss
        }
    }

    public init(name: String?, activityHint: String?, startDate: Date?, endDate: Date?, points: [TrackPoint], waypoints: [ParsedWaypoint] = [], sensorSamples: [SensorSample] = [], summary: Summary? = nil, creator: String? = nil) {
        self.name = name
        self.activityHint = activityHint
        self.startDate = startDate
        self.endDate = endDate
        self.points = points
        self.waypoints = waypoints
        self.sensorSamples = sensorSamples
        self.summary = summary
        self.creator = creator
    }
}

public enum GPXParseError: Error, Equatable {
    case xmlError(String)
    case noTracks
    case malformedCoordinates(String)
}

public struct GPXParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> ParsedTrack {
        do {
            return try parseStrict(data: data)
        } catch let error as GPXParseError {
            // Blindage : certains exports (gpx.py/gpxpy) écrivent les extensions avec l'URI de namespace
            // en guise de nom de balise (<http://…/v1:hr>), ce qui est du XML invalide. On répare ces
            // noms (→ <hr>, <cad>… : FC/cadence préservées) puis on réessaie une fois.
            if case .xmlError = error, let repaired = Self.repairNamespacedTagNames(data) {
                return try parseStrict(data: repaired)
            }
            throw error
        }
    }

    private func parseStrict(data: Data) throws -> ParsedTrack {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw GPXParseError.xmlError(message)
        }
        if let pendingError = delegate.pendingError {
            throw pendingError
        }
        guard !delegate.points.isEmpty else { throw GPXParseError.noTracks }
        return delegate.build()
    }

    /// Remplace les noms de balises où l'URI de namespace sert de nom (`<scheme://…:local>` → `<local>`).
    /// Ne touche pas aux balises valides (sans `://`) ni aux attributs `xmlns="http://…"`. Renvoie nil si rien à réparer.
    static func repairNamespacedTagNames(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "<(/?)[^>\\s]*://[^>\\s]*:([A-Za-z_][\\w.\\-]*)([ >])") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let repaired = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<$1$2$3")
        return repaired == text ? nil : repaired.data(using: .utf8)
    }

    public func parse(url: URL) throws -> ParsedTrack {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var trackName: String?
    var trackType: String?
    var creator: String?
    var pendingError: GPXParseError?

    /// Les waypoints (`wpt`) sont des marqueurs (départ/arrivée, POI) et n'appartiennent pas au tracé.
    /// On privilégie les points de trace (`trkpt`) ; à défaut, les points de route (`rtept`).
    private var trackPoints: [TrackPoint] = []
    private var routePoints: [TrackPoint] = []
    var points: [TrackPoint] { trackPoints.isEmpty ? routePoints : trackPoints }

    private(set) var waypoints: [ParsedWaypoint] = []
    private var inWaypoint = false
    private var currentWptLat: Double?
    private var currentWptLon: Double?
    private var currentWptName: String?
    private var currentWptType: String?
    private var currentWptSym: String?

    private enum PointKind { case track, route }
    private var currentKind: PointKind?

    private var elementStack: [String] = []
    private var textBuffer: String = ""

    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var currentHR: Double?
    private var currentCadence: Double?
    private var currentPower: Double?

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func build() -> ParsedTrack {
        let timestamps = points.compactMap(\.timestamp)
        return ParsedTrack(
            name: trackName,
            activityHint: trackType,
            startDate: timestamps.first,
            endDate: timestamps.last,
            points: points,
            waypoints: waypoints,
            creator: creator
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let local = stripNamespace(elementName)
        elementStack.append(local)
        textBuffer = ""

        if local == "gpx", creator == nil {
            let raw = attributeDict["creator"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            creator = (raw?.isEmpty == false) ? raw : nil
        }

        if local == "wpt" {
            currentKind = nil
            inWaypoint = true
            currentWptLat = attributeDict["lat"].flatMap(Double.init)
            currentWptLon = attributeDict["lon"].flatMap(Double.init)
            currentWptName = nil
            currentWptType = nil
            currentWptSym = nil
            return
        }

        if local == "trkpt" || local == "rtept" {
            guard let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
                  let lat = Double(latStr), let lon = Double(lonStr) else {
                pendingError = .malformedCoordinates(attributeDict["lat"].map { "lat=\($0)" } ?? "lat=missing")
                parser.abortParsing()
                return
            }
            currentKind = (local == "trkpt") ? .track : .route
            currentLat = lat
            currentLon = lon
            currentEle = nil
            currentTime = nil
            currentHR = nil
            currentCadence = nil
            currentPower = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = stripNamespace(elementName)
        defer {
            if elementStack.last == local { elementStack.removeLast() }
            textBuffer = ""
        }

        let raw = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "name":
            if inWaypoint {
                currentWptName = raw.isEmpty ? nil : raw
            } else if elementStack.dropLast().contains("trk"), trackName == nil {
                trackName = raw.isEmpty ? nil : raw
            }
        case "type":
            if inWaypoint {
                currentWptType = raw.isEmpty ? nil : raw
            } else if elementStack.dropLast().contains("trk"), trackType == nil {
                trackType = raw.isEmpty ? nil : raw
            }
        case "sym":
            if inWaypoint { currentWptSym = raw.isEmpty ? nil : raw }
        case "ele":
            if currentKind != nil { currentEle = Double(raw) }
        case "time":
            if currentKind != nil, let date = Self.parseISO8601(raw) {
                currentTime = date
            }
        case "hr":
            if currentKind != nil { currentHR = Double(raw) }
        case "cad":
            if currentKind != nil { currentCadence = Double(raw) }
        case "power":
            if currentKind != nil { currentPower = Double(raw) }
        case "trkpt", "rtept":
            defer { currentKind = nil }
            guard let lat = currentLat, let lon = currentLon, let kind = currentKind else { return }
            let point = TrackPoint(
                latitude: lat,
                longitude: lon,
                altitude: currentEle,
                timestamp: currentTime,
                heartRate: currentHR,
                cadence: currentCadence,
                power: currentPower
            )
            switch kind {
            case .track: trackPoints.append(point)
            case .route: routePoints.append(point)
            }
        case "wpt":
            currentKind = nil
            inWaypoint = false
            if let lat = currentWptLat, let lon = currentWptLon {
                waypoints.append(ParsedWaypoint(name: currentWptName, latitude: lat, longitude: lon,
                                                type: currentWptType, symbol: currentWptSym))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        if pendingError == nil {
            pendingError = .xmlError(parseError.localizedDescription)
        }
    }

    private func stripNamespace(_ name: String) -> String {
        if let idx = name.firstIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = iso8601Fractional.date(from: s) { return d }
        return iso8601Plain.date(from: s)
    }
}
