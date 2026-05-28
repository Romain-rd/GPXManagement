import Foundation

public enum AppleHealthImportError: Error, Equatable {
    case exportXMLNotFound
    case unreadable
}

public struct AppleHealthWorkout: Sendable, Equatable {
    public let id: UUID
    public let hkActivityType: String
    public let startDate: Date
    public let endDate: Date
    public let totalDistanceMeters: Double?
    public let durationSeconds: Double?
    public let gpxFileURL: URL?

    public init(id: UUID = UUID(), hkActivityType: String, startDate: Date, endDate: Date, totalDistanceMeters: Double?, durationSeconds: Double?, gpxFileURL: URL?) {
        self.id = id
        self.hkActivityType = hkActivityType
        self.startDate = startDate
        self.endDate = endDate
        self.totalDistanceMeters = totalDistanceMeters
        self.durationSeconds = durationSeconds
        self.gpxFileURL = gpxFileURL
    }

    public var suggestedActivityType: ActivityType? {
        Self.map(hkActivityType: hkActivityType)
    }

    public var suggestedTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateLabel = formatter.string(from: startDate)
        let typeLabel = suggestedActivityType?.displayLabelFR ?? Self.humanLabel(hkActivityType: hkActivityType)
        return "\(typeLabel) — \(dateLabel)"
    }

    static func map(hkActivityType raw: String) -> ActivityType? {
        switch raw {
        case "HKWorkoutActivityTypeCycling":              return .cyclingRoad
        case "HKWorkoutActivityTypeWalking":              return .walking
        case "HKWorkoutActivityTypeHiking":               return .hiking
        case "HKWorkoutActivityTypeDownhillSkiing":       return .skiingAlpine
        case "HKWorkoutActivityTypeCrossCountrySkiing":   return .skiingNordic
        case "HKWorkoutActivityTypeSnowSports":           return .skiingAlpine
        default:                                          return nil
        }
    }

    static func humanLabel(hkActivityType raw: String) -> String {
        raw.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
    }
}

private extension ActivityType {
    var displayLabelFR: String {
        switch self {
        case .cyclingRoad:    return "Vélo route"
        case .cyclingMTB:     return "VTT"
        case .cyclingGravel:  return "Gravel"
        case .motorcycle:     return "Moto"
        case .walking:        return "Marche"
        case .hiking:         return "Randonnée"
        case .skiingAlpine:   return "Ski alpin"
        case .skiingNordic:   return "Ski nordique"
        case .skiingTouring:  return "Ski de randonnée"
        case .skiingFreeride: return "Ski freeride"
        case .climbing:         return "Escalade"
        case .strengthTraining: return "Musculation"
        case .swimming:         return "Natation"
        case .mountaineering:   return "Alpinisme"
        case .rowing:           return "Aviron"
        case .surfing:          return "Surf"
        case .other:            return "Autre"
        default:                return shortName.capitalized
        }
    }
}

public actor AppleHealthImporter {
    public init() {}

    public func scan(exportRoot rootURL: URL) async throws -> [AppleHealthWorkout] {
        let resolvedRoot = try resolveActualRoot(rootURL: rootURL)
        let xmlURL = try locateExportXML(in: resolvedRoot)

        guard let parser = XMLParser(contentsOf: xmlURL) else {
            throw AppleHealthImportError.unreadable
        }
        let delegate = WorkoutXMLDelegate(rootURL: resolvedRoot)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let parsedOK = parser.parse()
        if !parsedOK && delegate.workouts.isEmpty {
            throw AppleHealthImportError.unreadable
        }
        return delegate.workouts
    }

    private func resolveActualRoot(rootURL: URL) throws -> URL {
        let fm = FileManager.default
        let nested = rootURL.appendingPathComponent("apple_health_export", isDirectory: true)
        if fm.fileExists(atPath: nested.appendingPathComponent("export.xml").path) {
            return nested
        }
        return rootURL
    }

    private func locateExportXML(in rootURL: URL) throws -> URL {
        let direct = rootURL.appendingPathComponent("export.xml")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        throw AppleHealthImportError.exportXMLNotFound
    }
}

private final class WorkoutXMLDelegate: NSObject, XMLParserDelegate {
    let rootURL: URL
    var workouts: [AppleHealthWorkout] = []

    private var inWorkout = false
    private var currentActivityType: String?
    private var currentStartDate: Date?
    private var currentEndDate: Date?
    private var currentDistance: Double?
    private var currentDuration: Double?
    private var currentGPXURL: URL?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        switch elementName {
        case "Workout":
            inWorkout = true
            currentActivityType = attrs["workoutActivityType"]
            currentStartDate = attrs["startDate"].flatMap { Self.dateFormatter.date(from: $0) }
            currentEndDate = attrs["endDate"].flatMap { Self.dateFormatter.date(from: $0) }
            currentDistance = Self.parseDistance(value: attrs["totalDistance"], unit: attrs["totalDistanceUnit"])
            currentDuration = Self.parseDuration(value: attrs["duration"], unit: attrs["durationUnit"])
            currentGPXURL = nil
        case "FileReference":
            guard inWorkout, let path = attrs["path"] else { return }
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            currentGPXURL = rootURL.appendingPathComponent(trimmed)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "Workout", inWorkout else { return }
        if let type = currentActivityType, let start = currentStartDate, let end = currentEndDate {
            workouts.append(AppleHealthWorkout(
                hkActivityType: type,
                startDate: start,
                endDate: end,
                totalDistanceMeters: currentDistance,
                durationSeconds: currentDuration,
                gpxFileURL: currentGPXURL
            ))
        }
        inWorkout = false
        currentActivityType = nil
        currentStartDate = nil
        currentEndDate = nil
        currentDistance = nil
        currentDuration = nil
        currentGPXURL = nil
    }

    private static func parseDistance(value: String?, unit: String?) -> Double? {
        guard let value, let v = Double(value) else { return nil }
        switch unit?.lowercased() {
        case "km", "kilometre", "kilometres", "kilometer", "kilometers": return v * 1000
        case "mi", "mile", "miles":                                       return v * 1609.344
        case "m", "meter", "meters", "metre", "metres":                   return v
        default:                                                          return v * 1000
        }
    }

    private static func parseDuration(value: String?, unit: String?) -> Double? {
        guard let value, let v = Double(value) else { return nil }
        switch unit?.lowercased() {
        case "h", "hour", "hours":     return v * 3600
        case "s", "second", "seconds": return v
        default:                       return v * 60
        }
    }
}
