import Foundation

public enum ActivityType: String, Codable, CaseIterable, Sendable {
    // Vélo
    case cyclingRoad = "cycling.road"
    case cyclingMTB = "cycling.mtb"
    case cyclingGravel = "cycling.gravel"
    case eBike = "ebike"
    case eMountainBike = "ebike.mtb"
    case virtualRide = "cycling.virtual"
    case velomobile = "velomobile"
    case handcycle = "handcycle"
    // Moto
    case motorcycle = "motorcycle"
    // Marche / course / rando
    case walking = "walking"
    case hiking = "hiking"
    case running = "running"
    case trailRunning = "trail_running"
    case virtualRun = "virtual_run"
    case mountaineering = "mountaineering"
    // Ski / neige
    case skiingAlpine = "skiing.alpine"
    case skiingNordic = "skiing.nordic"
    case skiingTouring = "skiing.touring"
    case skiingFreeride = "skiing.freeride"
    case rollerSki = "roller_ski"
    case snowboard = "snowboard"
    case snowshoe = "snowshoe"
    // Glisse / roule
    case iceSkate = "ice_skate"
    case inlineSkate = "inline_skate"
    case skateboard = "skateboard"
    // Eau
    case swimming = "swimming"
    case rowing = "rowing"
    case virtualRow = "virtual_row"
    case canoeing = "canoeing"
    case kayaking = "kayaking"
    case standUpPaddling = "sup"
    case surfing = "surfing"
    case kitesurf = "kitesurf"
    case windsurf = "windsurf"
    case sailing = "sailing"
    // Montagne / grimpe
    case climbing = "climbing"
    // Salle / fitness
    case strengthTraining = "strength"
    case crossfit = "crossfit"
    case elliptical = "elliptical"
    case stairStepper = "stair_stepper"
    case hiit = "hiit"
    case pilates = "pilates"
    case yoga = "yoga"
    case workout = "workout"
    // Sports de balle / raquette / divers
    case golf = "golf"
    case wheelchair = "wheelchair"
    case badminton = "badminton"
    case tennis = "tennis"
    case tableTennis = "table_tennis"
    case pickleball = "pickleball"
    case racquetball = "racquetball"
    case squash = "squash"
    case soccer = "soccer"
    // Catch-all
    case other = "other"

    /// Identifiant Strava sport_type correspondant (pour l'import / l'export Strava).
    public var stravaSportType: String? {
        switch self {
        case .cyclingRoad:       return "Ride"
        case .cyclingMTB:        return "MountainBikeRide"
        case .cyclingGravel:     return "GravelRide"
        case .eBike:             return "EBikeRide"
        case .eMountainBike:     return "EMountainBikeRide"
        case .virtualRide:       return "VirtualRide"
        case .velomobile:        return "Velomobile"
        case .handcycle:         return "Handcycle"
        case .walking:           return "Walk"
        case .hiking:            return "Hike"
        case .running:           return "Run"
        case .trailRunning:      return "TrailRun"
        case .virtualRun:        return "VirtualRun"
        case .skiingAlpine:      return "AlpineSki"
        case .skiingNordic:      return "NordicSki"
        case .skiingTouring:     return "BackcountrySki"
        case .rollerSki:         return "RollerSki"
        case .snowboard:         return "Snowboard"
        case .snowshoe:          return "Snowshoe"
        case .iceSkate:          return "IceSkate"
        case .inlineSkate:       return "InlineSkate"
        case .skateboard:        return "Skateboard"
        case .swimming:          return "Swim"
        case .rowing:            return "Rowing"
        case .virtualRow:        return "VirtualRow"
        case .canoeing:          return "Canoeing"
        case .kayaking:          return "Kayaking"
        case .standUpPaddling:   return "StandUpPaddling"
        case .surfing:           return "Surfing"
        case .kitesurf:          return "Kitesurf"
        case .windsurf:          return "Windsurf"
        case .sailing:           return "Sail"
        case .climbing:          return "RockClimbing"
        case .strengthTraining:  return "WeightTraining"
        case .crossfit:          return "Crossfit"
        case .elliptical:        return "Elliptical"
        case .stairStepper:      return "StairStepper"
        case .hiit:              return "HighIntensityIntervalTraining"
        case .pilates:           return "Pilates"
        case .yoga:              return "Yoga"
        case .workout:           return "Workout"
        case .golf:              return "Golf"
        case .wheelchair:        return "Wheelchair"
        case .badminton:         return "Badminton"
        case .tennis:            return "Tennis"
        case .tableTennis:       return "TableTennis"
        case .pickleball:        return "Pickleball"
        case .racquetball:       return "Racquetball"
        case .squash:            return "Squash"
        case .soccer:            return "Soccer"
        case .motorcycle, .skiingFreeride, .mountaineering, .other:
            return nil
        }
    }

    /// ActivityType correspondant à un sport_type Strava (ex. "TrailRun" → .trailRunning).
    public static func fromStravaSportType(_ raw: String) -> ActivityType? {
        allCases.first { $0.stravaSportType == raw }
    }

    /// Échelle de couleur de pente (en %, identique pour toutes les activités).
    public var slopeScale: SlopeScale { .percent }

    /// Activités sur neige, pour lesquelles la pente du terrain (IGN) est pertinente.
    public var isSnow: Bool {
        switch self {
        case .skiingTouring, .skiingFreeride, .skiingAlpine, .skiingNordic, .snowboard, .snowshoe:
            return true
        default:
            return false
        }
    }
}

public enum ActivityOrigin: String, Codable, CaseIterable, Sendable {
    case manualImport = "manual_import"
    case strava = "strava"
}

public enum SourceFileFormat: String, Codable, CaseIterable, Sendable {
    case gpx
    case fit
    case tcx
}
