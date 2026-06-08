import Foundation
import GPXCore

extension ActivityType {
    var displayName: String {
        switch self {
        case .cyclingRoad:      return "Vélo route"
        case .cyclingMTB:       return "VTT"
        case .cyclingGravel:    return "Gravel"
        case .eBike:            return "Vélo électrique"
        case .eMountainBike:    return "VTT électrique"
        case .virtualRide:      return "Vélo virtuel"
        case .velomobile:       return "Vélomobile"
        case .handcycle:        return "Handbike"
        case .motorcycle:       return "Moto"
        case .walking:          return "Marche"
        case .hiking:           return "Randonnée"
        case .running:          return "Course à pied"
        case .trailRunning:     return "Trail"
        case .virtualRun:       return "Course virtuelle"
        case .mountaineering:   return "Alpinisme"
        case .skiingAlpine:     return "Ski alpin"
        case .skiingNordic:     return "Ski nordique"
        case .skiingTouring:    return "Ski de randonnée"
        case .skiingFreeride:   return "Ski freeride"
        case .rollerSki:        return "Ski à roulettes"
        case .snowboard:        return "Snowboard"
        case .snowshoe:         return "Raquettes"
        case .iceSkate:         return "Patin à glace"
        case .inlineSkate:      return "Roller"
        case .skateboard:       return "Skateboard"
        case .swimming:         return "Natation"
        case .rowing:           return "Aviron"
        case .virtualRow:       return "Aviron virtuel"
        case .canoeing:         return "Canoë"
        case .kayaking:         return "Kayak"
        case .standUpPaddling:  return "Stand up paddle"
        case .surfing:          return "Surf"
        case .kitesurf:         return "Kitesurf"
        case .windsurf:         return "Windsurf"
        case .sailing:          return "Voile"
        case .climbing:         return "Escalade"
        case .strengthTraining: return "Musculation"
        case .crossfit:         return "Crossfit"
        case .elliptical:       return "Elliptique"
        case .stairStepper:     return "Stepper"
        case .hiit:             return "HIIT"
        case .pilates:          return "Pilates"
        case .yoga:             return "Yoga"
        case .workout:          return "Séance"
        case .golf:             return "Golf"
        case .wheelchair:       return "Fauteuil roulant"
        case .badminton:        return "Badminton"
        case .tennis:           return "Tennis"
        case .tableTennis:      return "Tennis de table"
        case .pickleball:       return "Pickleball"
        case .racquetball:      return "Racquetball"
        case .squash:           return "Squash"
        case .soccer:           return "Football"
        case .other:            return "Autre"
        }
    }

    /// Distance et vitesse ont-elles du sens ? Non pour l'escalade, la muscu, les sports de salle/raquette
    /// (sur place / sans déplacement mesurable). Les cartes correspondantes sont alors masquées.
    var tracksDistanceAndSpeed: Bool {
        switch self {
        case .climbing, .strengthTraining, .crossfit, .elliptical, .stairStepper,
             .hiit, .pilates, .yoga, .workout,
             .badminton, .tennis, .tableTennis, .pickleball, .racquetball, .squash:
            return false
        default:
            return true
        }
    }
}
