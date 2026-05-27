import Foundation

public extension ActivityType {
    var shortName: String {
        switch self {
        case .cyclingRoad, .cyclingMTB, .cyclingGravel: return "velo"
        case .motorcycle: return "moto"
        case .walking: return "marche"
        case .hiking: return "rando"
        case .skiingAlpine, .skiingNordic, .skiingFreeride: return "ski"
        case .skiingTouring: return "ski-rando"
        }
    }

    var subactivityName: String {
        switch self {
        case .cyclingRoad: return "route"
        case .cyclingMTB: return "vtt"
        case .cyclingGravel: return "gravel"
        case .motorcycle: return ""
        case .walking: return ""
        case .hiking: return ""
        case .skiingAlpine: return "alpin"
        case .skiingNordic: return "nordique"
        case .skiingFreeride: return "freerando"
        case .skiingTouring: return ""
        }
    }
}
