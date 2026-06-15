import Foundation

/// Regroupement des types d'activité pour les menus (ordre des catégories volontairement fixe).
public enum ActivityCategory: String, CaseIterable, Sendable {
    case cycling
    case motorcycle
    case walkingRunning
    case mountain
    case snow
    case skating
    case water
    case fitness
    case ballRacket
    case other

    public var displayName: String {
        switch self {
        case .cycling:        return "Vélo"
        case .motorcycle:     return "Moto"
        case .walkingRunning: return "Marche & course"
        case .mountain:       return "Montagne"
        case .snow:           return "Ski & neige"
        case .skating:        return "Glisse & roule"
        case .water:          return "Nautique"
        case .fitness:        return "Salle & fitness"
        case .ballRacket:     return "Sports & raquettes"
        case .other:          return "Autre"
        }
    }
}

public extension ActivityType {
    var category: ActivityCategory {
        switch self {
        case .cyclingRoad, .cyclingMTB, .cyclingGravel, .eBike, .eMountainBike, .virtualRide, .velomobile, .handcycle:
            return .cycling
        case .motorcycle:
            return .motorcycle
        case .walking, .hiking, .running, .trailRunning, .virtualRun:
            return .walkingRunning
        case .mountaineering, .climbing:
            return .mountain
        case .skiingAlpine, .skiingNordic, .skiingTouring, .skiingFreeride, .rollerSki, .snowboard, .snowshoe:
            return .snow
        case .iceSkate, .inlineSkate, .skateboard:
            return .skating
        case .swimming, .rowing, .virtualRow, .canoeing, .kayaking, .standUpPaddling, .surfing, .kitesurf, .windsurf, .sailing:
            return .water
        case .strengthTraining, .crossfit, .elliptical, .stairStepper, .hiit, .pilates, .yoga, .workout:
            return .fitness
        case .golf, .wheelchair, .badminton, .tennis, .tableTennis, .pickleball, .racquetball, .squash, .soccer:
            return .ballRacket
        case .other:
            return .other
        }
    }

    /// Types groupés par catégorie (ordre des catégories fixe), triés alphabétiquement dans chaque catégorie.
    static var groupedByCategory: [(category: ActivityCategory, types: [ActivityType])] {
        ActivityCategory.allCases.compactMap { category in
            let types = ActivityType.allCases
                .filter { $0.category == category }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            return types.isEmpty ? nil : (category, types)
        }
    }
}
