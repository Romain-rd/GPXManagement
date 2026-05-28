import Foundation

public extension ActivityType {
    var shortName: String {
        switch self {
        case .cyclingRoad, .cyclingMTB, .cyclingGravel, .virtualRide: return "velo"
        case .eBike, .eMountainBike:                                  return "velo-elec"
        case .velomobile:                                             return "velomobile"
        case .handcycle:                                              return "handbike"
        case .motorcycle:                                             return "moto"
        case .walking:                                                return "marche"
        case .hiking:                                                 return "rando"
        case .running, .trailRunning, .virtualRun:                    return "course"
        case .mountaineering:                                         return "alpinisme"
        case .skiingAlpine, .skiingNordic, .skiingFreeride, .rollerSki: return "ski"
        case .skiingTouring:                                          return "ski-rando"
        case .snowboard:                                              return "snowboard"
        case .snowshoe:                                               return "raquettes"
        case .iceSkate:                                               return "patinage"
        case .inlineSkate:                                            return "roller"
        case .skateboard:                                             return "skate"
        case .swimming:                                               return "natation"
        case .rowing, .virtualRow:                                    return "aviron"
        case .canoeing:                                               return "canoe"
        case .kayaking:                                               return "kayak"
        case .standUpPaddling:                                        return "sup"
        case .surfing:                                                return "surf"
        case .kitesurf:                                               return "kitesurf"
        case .windsurf:                                               return "windsurf"
        case .sailing:                                                return "voile"
        case .climbing:                                               return "escalade"
        case .strengthTraining:                                       return "muscu"
        case .crossfit:                                               return "crossfit"
        case .elliptical:                                             return "elliptique"
        case .stairStepper:                                           return "stepper"
        case .hiit:                                                   return "hiit"
        case .pilates:                                                return "pilates"
        case .yoga:                                                   return "yoga"
        case .workout:                                                return "seance"
        case .golf:                                                   return "golf"
        case .wheelchair:                                             return "fauteuil"
        case .badminton:                                              return "badminton"
        case .tennis:                                                 return "tennis"
        case .tableTennis:                                            return "tennis-table"
        case .pickleball:                                             return "pickleball"
        case .racquetball:                                            return "racquetball"
        case .squash:                                                 return "squash"
        case .soccer:                                                 return "foot"
        case .other:                                                  return "autre"
        }
    }

    var subactivityName: String {
        switch self {
        case .cyclingRoad: return "route"
        case .cyclingMTB:  return "vtt"
        case .cyclingGravel: return "gravel"
        case .skiingAlpine: return "alpin"
        case .skiingNordic: return "nordique"
        case .skiingFreeride: return "freerando"
        default: return ""
        }
    }
}
