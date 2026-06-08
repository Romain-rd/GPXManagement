import Foundation

/// Compte les « montées » (voies / blocs) dans un profil d'altitude barométrique : chaque montée est
/// un cycle de remontée d'au moins `thresholdMeters` suivi d'une redescente d'au moins `thresholdMeters`
/// (hystérésis, pour ignorer le bruit du capteur). Calibré sur les exports Redpoint.
public enum ClimbCounter {
    /// Calibré sur deux sessions Redpoint (réel 5 et 7 → 3,0 m donne 5 et 7 ; en dessous, sur-compte).
    public static let defaultThresholdMeters: Double = 3.0

    public static func count(points: [TrackPoint], thresholdMeters: Double = defaultThresholdMeters) -> Int {
        count(altitudes: points.compactMap(\.altitude), thresholdMeters: thresholdMeters)
    }

    public static func count(altitudes: [Double], thresholdMeters: Double = defaultThresholdMeters) -> Int {
        guard let first = altitudes.first, thresholdMeters > 0 else { return 0 }
        var bottom = first
        var top = first
        var climbing = false
        var climbs = 0
        for e in altitudes {
            if climbing {
                if e > top { top = e }
                if top - e >= thresholdMeters { climbs += 1; climbing = false; bottom = e }
            } else {
                if e < bottom { bottom = e }
                if e - bottom >= thresholdMeters { climbing = true; top = e }
            }
        }
        return climbs
    }
}
