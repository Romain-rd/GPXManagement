import Foundation

public enum TCXParseError: Error, Equatable {
    case xmlError(String)
    case noTracks
}

public struct TCXParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> ParsedTrack {
        let delegate = TCXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw TCXParseError.xmlError(message)
        }
        if let pendingError = delegate.pendingError {
            throw pendingError
        }
        guard !delegate.points.isEmpty else { throw TCXParseError.noTracks }
        return delegate.build()
    }

    public func parse(url: URL) throws -> ParsedTrack {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }
}

private final class TCXParserDelegate: NSObject, XMLParserDelegate {
    var sport: String?
    var points: [TrackPoint] = []
    var pendingError: TCXParseError?
    private var authorName: String?
    private var deviceName: String?

    private var elementStack: [String] = []
    private var textBuffer: String = ""

    private var inTrackpoint = false
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
            name: nil,
            activityHint: sport,
            startDate: timestamps.first,
            endDate: timestamps.last,
            points: points,
            creator: deviceName ?? authorName
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let local = stripNamespace(elementName)
        elementStack.append(local)
        textBuffer = ""

        switch local {
        case "Activity", "Course":
            if sport == nil { sport = attributeDict["Sport"] }
        case "Trackpoint":
            inTrackpoint = true
            currentLat = nil
            currentLon = nil
            currentEle = nil
            currentTime = nil
            currentHR = nil
            currentCadence = nil
            currentPower = nil
        default:
            break
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

        // <Creator>/<Author> sont hors trackpoints : capter ici, avant le guard.
        if local == "Name", !raw.isEmpty {
            let ancestors = elementStack.dropLast()
            if ancestors.contains("Creator"), deviceName == nil { deviceName = raw }
            else if ancestors.contains("Author"), authorName == nil { authorName = raw }
        }

        guard inTrackpoint else {
            if local == "Trackpoint" { inTrackpoint = false }
            return
        }

        switch local {
        case "LatitudeDegrees":
            currentLat = Double(raw)
        case "LongitudeDegrees":
            currentLon = Double(raw)
        case "AltitudeMeters":
            currentEle = Double(raw)
        case "Time":
            if let date = Self.parseISO8601(raw) { currentTime = date }
        case "Value":
            if elementStack.dropLast().contains("HeartRateBpm") { currentHR = Double(raw) }
        case "Cadence":
            currentCadence = Double(raw)
        case "Watts":
            currentPower = Double(raw)
        case "Trackpoint":
            inTrackpoint = false
            guard let lat = currentLat, let lon = currentLon else { return }
            points.append(TrackPoint(
                latitude: lat,
                longitude: lon,
                altitude: currentEle,
                timestamp: currentTime,
                heartRate: currentHR,
                cadence: currentCadence,
                power: currentPower
            ))
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
