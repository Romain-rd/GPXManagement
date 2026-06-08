import Foundation

public enum ActivityTypeDetector {
    public static func detect(hint: String?, fileFormat: SourceFileFormat) -> ActivityType? {
        guard let hint, !hint.isEmpty else { return nil }
        let normalized = hint.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")

        switch fileFormat {
        case .gpx:  return detectGPX(normalized)
        case .fit:  return detectFIT(normalized)
        case .tcx:  return detectTCX(normalized)
        }
    }

    /// Type déduit de l'application source, pour les apps mono-usage dont les fichiers ne portent pas
    /// de type d'activité fiable (ex. Scenic, dédiée moto).
    public static func detect(source: ActivitySource) -> ActivityType? {
        switch source {
        case .scenic:   return .motorcycle
        case .redpoint: return .climbing
        default:        return nil
        }
    }

    private static func detectGPX(_ s: String) -> ActivityType? {
        switch s {
        case "cycling", "ride", "road_cycling", "cyclingroad":             return .cyclingRoad
        case "mountainbiking", "mountain_biking", "mtb", "cyclingmtb":      return .cyclingMTB
        case "gravelcycling", "gravel_cycling", "gravel", "cyclinggravel":  return .cyclingGravel
        case "running", "run":                                              return .walking
        case "walking", "walk":                                             return .walking
        case "hike", "hiking":                                              return .hiking
        case "alpineski", "alpine_skiing", "skiing":                        return .skiingAlpine
        case "backcountryski", "backcountry_skiing", "ski_touring",
             "ski_rando", "skitouring":                                     return .skiingTouring
        case "crosscountryskiing", "cross_country_skiing", "nordicski",
             "nordic_skiing", "xcski":                                      return .skiingNordic
        case "freerideskiing", "freeride":                                  return .skiingFreeride
        case "motorcycling", "motorcycle", "moto":                          return .motorcycle
        default:                                                            return nil
        }
    }

    private static func detectFIT(_ s: String) -> ActivityType? {
        switch s {
        case "cycling":                                                     return .cyclingRoad
        case "mountain_biking":                                             return .cyclingMTB
        case "gravel_cycling":                                              return .cyclingGravel
        case "running", "walking":                                          return .walking
        case "hiking":                                                      return .hiking
        case "alpine_skiing":                                               return .skiingAlpine
        case "cross_country_skiing":                                        return .skiingNordic
        case "backcountry_skiing", "ski_touring":                           return .skiingTouring
        case "motorcycling":                                                return .motorcycle
        case "rock_climbing", "floor_climbing", "indoor_climbing":          return .climbing
        case "training", "fitness_equipment":                               return .strengthTraining
        case "swimming":                                                    return .swimming
        case "mountaineering":                                              return .mountaineering
        case "rowing":                                                      return .rowing
        case "surfing":                                                     return .surfing
        default:                                                            return nil
        }
    }

    private static func detectTCX(_ s: String) -> ActivityType? {
        switch s {
        case "biking", "cycling", "road_biking":  return .cyclingRoad
        case "mountain_biking":                   return .cyclingMTB
        case "running", "run", "walking":         return .walking
        case "hiking":                            return .hiking
        default:                                  return nil
        }
    }
}
