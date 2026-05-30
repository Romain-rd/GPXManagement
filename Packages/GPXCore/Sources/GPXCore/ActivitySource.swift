import Foundation

/// Application/appareil ayant généré le fichier, dérivée de la chaîne brute (`creator` GPX,
/// fabricant FIT, `Author`/`Creator` TCX). La catégorie est calculée à la volée : améliorer le
/// mapping s'applique rétroactivement sans migration de données.
public enum ActivitySource: Hashable, Sendable, Identifiable {
    case strava
    case garmin
    case komoot
    case wahoo
    case suunto
    case polar
    case coros
    case appleHealth
    case zwift
    case rideWithGPS
    case decathlon
    case bryton
    case tomtom
    case sigma
    case hammerhead
    case fitbit
    case stryd
    case scenic
    case other(String)
    case unknown

    public var id: String {
        switch self {
        case .other(let raw): return "other:\(raw)"
        default: return displayName
        }
    }

    public init(rawCreator: String?) {
        guard let trimmed = rawCreator?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            self = .unknown
            return
        }
        let needle = trimmed.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
        func has(_ s: String) -> Bool { needle.contains(s) }

        switch true {
        case has("strava"):                       self = .strava
        case has("garmin"):                       self = .garmin
        case has("komoot"):                       self = .komoot
        case has("wahoo"):                        self = .wahoo
        case has("suunto"):                       self = .suunto
        case has("polar"):                        self = .polar
        case has("coros"):                        self = .coros
        case has("apple"), has("healthfit"):      self = .appleHealth
        case has("zwift"):                        self = .zwift
        case has("ridewithgps"), has("ride with gps"): self = .rideWithGPS
        case has("decathlon"):                    self = .decathlon
        case has("bryton"):                       self = .bryton
        case has("tomtom"):                       self = .tomtom
        case has("sigma"):                        self = .sigma
        case has("hammerhead"), has("karoo"):     self = .hammerhead
        case has("fitbit"):                       self = .fitbit
        case has("stryd"):                        self = .stryd
        case has("scenic"):                       self = .scenic
        default:                                  self = .other(trimmed)
        }
    }

    public var displayName: String {
        switch self {
        case .strava:       return "Strava"
        case .garmin:       return "Garmin"
        case .komoot:       return "Komoot"
        case .wahoo:        return "Wahoo"
        case .suunto:       return "Suunto"
        case .polar:        return "Polar"
        case .coros:        return "COROS"
        case .appleHealth:  return "Apple Santé"
        case .zwift:        return "Zwift"
        case .rideWithGPS:  return "Ride with GPS"
        case .decathlon:    return "Decathlon"
        case .bryton:       return "Bryton"
        case .tomtom:       return "TomTom"
        case .sigma:        return "Sigma"
        case .hammerhead:   return "Hammerhead"
        case .fitbit:       return "Fitbit"
        case .stryd:        return "Stryd"
        case .scenic:       return "Scenic"
        case .other(let raw): return raw
        case .unknown:      return "Inconnue"
        }
    }

    public var symbolName: String {
        switch self {
        case .strava:       return "flame.fill"
        case .garmin:       return "location.circle.fill"
        case .komoot:       return "map.fill"
        case .wahoo:        return "bolt.fill"
        case .suunto:       return "mountain.2.fill"
        case .polar:        return "snowflake"
        case .coros:        return "stopwatch.fill"
        case .appleHealth:  return "heart.fill"
        case .zwift:        return "bicycle"
        case .rideWithGPS:  return "point.topleft.down.curvedto.point.bottomright.up"
        case .decathlon:    return "figure.run"
        case .scenic:       return "motorcycle"
        case .bryton, .sigma, .hammerhead, .fitbit, .stryd, .tomtom: return "speedometer"
        case .other:        return "app.dashed"
        case .unknown:      return "questionmark.circle"
        }
    }

    /// Clé de tri pour l'affichage : sources reconnues (alpha), puis « autres », puis « inconnue ».
    public var sortKey: String {
        switch self {
        case .other(let raw): return "1\(raw.lowercased())"
        case .unknown:        return "2"
        default:              return "0\(displayName.lowercased())"
        }
    }
}
