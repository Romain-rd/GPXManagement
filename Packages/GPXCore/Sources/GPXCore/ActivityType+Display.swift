import Foundation
import GPXCore

public extension ActivityType {
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

public extension ActivityType {
    /// Emoji textuel (titres de Calendrier, partages) — regroupé par famille.
    var emoji: String {
        switch self {
        case .cyclingRoad, .cyclingGravel, .virtualRide, .velomobile, .eBike: return "🚴"
        case .cyclingMTB, .eMountainBike:  return "🚵"
        case .handcycle, .wheelchair:      return "🦽"
        case .motorcycle:                  return "🏍️"
        case .walking:                     return "🚶"
        case .hiking, .mountaineering:     return "🥾"
        case .running, .virtualRun, .trailRunning: return "🏃"
        case .skiingAlpine, .skiingFreeride: return "⛷️"
        case .skiingNordic, .skiingTouring, .rollerSki: return "🎿"
        case .snowboard:                   return "🏂"
        case .snowshoe:                    return "🥾"
        case .iceSkate:                    return "⛸️"
        case .inlineSkate, .skateboard:    return "🛹"
        case .swimming:                    return "🏊"
        case .rowing, .virtualRow, .canoeing, .kayaking: return "🚣"
        case .standUpPaddling, .surfing:   return "🏄"
        case .kitesurf, .windsurf, .sailing: return "⛵"
        case .climbing:                    return "🧗"
        case .strengthTraining:            return "🏋️"
        case .crossfit, .hiit, .workout, .elliptical, .stairStepper: return "💪"
        case .pilates, .yoga:              return "🧘"
        case .golf:                        return "⛳"
        case .badminton:                   return "🏸"
        case .tennis, .tableTennis, .pickleball, .racquetball, .squash: return "🎾"
        case .soccer:                      return "⚽"
        case .other:                       return "📍"
        }
    }

    var symbolName: String {
        switch self {
        case .cyclingRoad, .cyclingGravel, .virtualRide, .velomobile: return "bicycle"
        case .cyclingMTB:                  return "bicycle.circle"
        case .eBike, .eMountainBike:       return "bicycle.circle.fill"
        case .handcycle:                   return "figure.roll"
        case .motorcycle:                  return "motorcycle"
        case .walking:                     return "figure.walk"
        case .hiking:                      return "figure.hiking"
        case .running, .virtualRun:        return "figure.run"
        case .trailRunning:                return "figure.run.square.stack"
        case .mountaineering:              return "mountain.2.fill"
        case .skiingAlpine:                return "figure.skiing.downhill"
        case .skiingNordic:                return "figure.skiing.crosscountry"
        case .skiingTouring:               return "mountain.2"
        case .skiingFreeride:              return "snowflake"
        case .rollerSki:                   return "figure.skiing.crosscountry"
        case .snowboard:                   return "figure.snowboarding"
        case .snowshoe:                    return "snow"
        case .iceSkate:                    return "figure.ice.skating"
        case .inlineSkate:                 return "figure.roll"
        case .skateboard:                  return "skateboard"
        case .swimming:                    return "figure.pool.swim"
        case .rowing, .virtualRow:         return "figure.rower"
        case .canoeing, .kayaking:         return "figure.outdoor.rowing"
        case .standUpPaddling:             return "figure.surfing"
        case .surfing:                     return "figure.surfing"
        case .kitesurf, .windsurf:         return "wind"
        case .sailing:                     return "sailboat"
        case .climbing:                    return "figure.climbing"
        case .strengthTraining:            return "dumbbell"
        case .crossfit, .hiit:             return "figure.highintensity.intervaltraining"
        case .elliptical:                  return "figure.elliptical"
        case .stairStepper:                return "figure.stairs"
        case .pilates:                     return "figure.pilates"
        case .yoga:                        return "figure.yoga"
        case .workout:                     return "figure.mixed.cardio"
        case .golf:                        return "figure.golf"
        case .wheelchair:                  return "figure.roll"
        case .badminton:                   return "figure.badminton"
        case .tennis:                      return "figure.tennis"
        case .tableTennis:                 return "figure.table.tennis"
        case .pickleball:                  return "figure.pickleball"
        case .racquetball:                 return "figure.racquetball"
        case .squash:                      return "figure.squash"
        case .soccer:                      return "figure.soccer"
        case .other:                       return "questionmark.circle"
        }
    }
}
