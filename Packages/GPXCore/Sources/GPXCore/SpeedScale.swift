import Foundation

/// Catégorie de vitesse (5 niveaux), avec couleur canonique (du plus lent au plus rapide).
public enum SpeedCategory: Int, Sendable, CaseIterable {
    case c1, c2, c3, c4, c5

    /// Couleur canonique RGB (0–1), bleu (lent) → rouge (rapide).
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .c1: return (0.23, 0.51, 0.96) // bleu
        case .c2: return (0.13, 0.77, 0.37) // vert
        case .c3: return (0.92, 0.70, 0.03) // jaune
        case .c4: return (0.98, 0.45, 0.09) // orange
        case .c5: return (0.94, 0.27, 0.27) // rouge
        }
    }
}

/// Échelle de classement de la vitesse en bandes, dans l'unité d'affichage de l'activité (km/h ou nœuds).
/// `bounds` = N bornes croissantes → N+1 bandes.
public struct SpeedScale: Sendable, Equatable {
    public let bounds: [Double]
    public let unitLabel: String

    public init(bounds: [Double], unitLabel: String) {
        self.bounds = bounds
        self.unitLabel = unitLabel
    }

    public func category(for speed: Double) -> SpeedCategory {
        for (i, b) in bounds.enumerated() where speed < b { return SpeedCategory.allCases[i] }
        return SpeedCategory.allCases[bounds.count]
    }

    public var categories: [SpeedCategory] {
        Array(SpeedCategory.allCases.prefix(bounds.count + 1))
    }

    public func label(for category: SpeedCategory) -> String {
        guard let idx = SpeedCategory.allCases.firstIndex(of: category) else { return "" }
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.0f", v) }
        if idx == 0 { return "< \(n(bounds[0])) \(unitLabel)" }
        if idx >= bounds.count { return "> \(n(bounds[bounds.count - 1])) \(unitLabel)" }
        return "\(n(bounds[idx - 1]))–\(n(bounds[idx])) \(unitLabel)"
    }
}

public extension ActivityType {
    /// Voile : vitesse en nœuds et distances en milles nautiques.
    var usesNauticalUnits: Bool { self == .sailing }

    var speedUnitLabel: String { usesNauticalUnits ? "nœuds" : "km/h" }

    /// Échelle de couleur de vitesse adaptée à l'activité (bornes dans l'unité d'affichage).
    var speedScale: SpeedScale {
        let unit = speedUnitLabel
        switch self {
        case .walking, .hiking, .snowshoe, .mountaineering:
            return SpeedScale(bounds: [3, 4.5, 6, 7.5], unitLabel: unit)
        case .running, .trailRunning, .virtualRun:
            return SpeedScale(bounds: [7, 9, 11, 13], unitLabel: unit)
        case .cyclingRoad, .cyclingGravel, .eBike, .virtualRide, .velomobile, .handcycle:
            return SpeedScale(bounds: [12, 20, 28, 36], unitLabel: unit)
        case .cyclingMTB, .eMountainBike:
            return SpeedScale(bounds: [8, 14, 20, 26], unitLabel: unit)
        case .motorcycle:
            return SpeedScale(bounds: [40, 70, 100, 130], unitLabel: unit)
        case .skiingAlpine, .skiingFreeride:
            return SpeedScale(bounds: [15, 30, 45, 60], unitLabel: unit)
        case .skiingTouring, .skiingNordic, .rollerSki, .snowboard:
            return SpeedScale(bounds: [8, 16, 24, 32], unitLabel: unit)
        case .sailing:
            return SpeedScale(bounds: [3, 6, 10, 15], unitLabel: unit) // nœuds
        case .windsurf, .kitesurf, .surfing, .canoeing, .kayaking, .standUpPaddling, .rowing, .virtualRow:
            return SpeedScale(bounds: [5, 10, 18, 25], unitLabel: unit)
        default:
            return SpeedScale(bounds: [10, 20, 30, 40], unitLabel: unit)
        }
    }
}
