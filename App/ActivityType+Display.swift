import Foundation
import GPXCore

extension ActivityType {
    var displayName: String {
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
        }
    }
}
