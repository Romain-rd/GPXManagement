import Foundation

public enum ActivityType: String, Codable, CaseIterable, Sendable {
    case cyclingRoad = "cycling.road"
    case cyclingMTB = "cycling.mtb"
    case cyclingGravel = "cycling.gravel"
    case motorcycle = "motorcycle"
    case walking = "walking"
    case hiking = "hiking"
    case skiingAlpine = "skiing.alpine"
    case skiingNordic = "skiing.nordic"
    case skiingTouring = "skiing.touring"
    case skiingFreeride = "skiing.freeride"
}

public enum ActivityOrigin: String, Codable, CaseIterable, Sendable {
    case manualImport = "manual_import"
    case strava = "strava"
}

public enum SourceFileFormat: String, Codable, CaseIterable, Sendable {
    case gpx
    case fit
}
