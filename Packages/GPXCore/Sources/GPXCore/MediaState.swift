import Foundation

/// État qu'on attache à une photo/vidéo d'une activité, synchronisé entre Macs (stocké dans `Activity.mediaState`).
/// Identité stable inter-appareils : nom de fichier d'origine + heure de prise (le `PHAsset.localIdentifier`
/// diffère d'un Mac à l'autre, contrairement à ces deux métadonnées qui voyagent avec la photo).
public struct MediaPlacement: Codable, Sendable, Equatable {
    public var file: String
    public var date: Double?        // creationDate en timeIntervalSince1970, nil si inconnue
    public var onMap: Bool?         // true=affiché, false=masqué, nil=valeur par défaut (préférence globale)
    public var posMeters: Double?   // position manuelle le long de la trace, nil=auto (heure→GPS)
    public var appCreated: Bool

    public init(file: String, date: Double?, onMap: Bool? = nil, posMeters: Double? = nil, appCreated: Bool = false) {
        self.file = file
        self.date = date
        self.onMap = onMap
        self.posMeters = posMeters
        self.appCreated = appCreated
    }

    public var key: String { Self.key(file: file, date: date) }

    /// Clé d'appariement inter-appareils ; l'heure est arrondie à la seconde.
    public static func key(file: String, date: Double?) -> String {
        "\(file)|\(date.map { String(Int($0)) } ?? "")"
    }

    /// Une entrée vide (tous champs par défaut) n'a pas à être conservée.
    public var isDefault: Bool { onMap == nil && posMeters == nil && !appCreated }
}

public enum MediaStateCodec {
    public static func decode(_ data: Data?) -> [String: MediaPlacement] {
        guard let data, !data.isEmpty,
              let entries = try? JSONDecoder().decode([MediaPlacement].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    public static func encode(_ placements: [String: MediaPlacement]) -> Data? {
        let kept = placements.values.filter { !$0.isDefault }.sorted { $0.key < $1.key }
        guard !kept.isEmpty else { return nil }
        return try? JSONEncoder().encode(kept)
    }
}
