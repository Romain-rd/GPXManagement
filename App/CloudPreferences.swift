import Foundation
import GPXCore

/// Préférences synchronisées entre les appareils de l'utilisateur via iCloud Key-Value Store
/// (mécanisme Apple préconisé pour les réglages / petit état d'app). La valeur est aussi reflétée
/// dans UserDefaults pour que les lectures existantes (AppServices.currentOrganizationPattern) restent inchangées.
@MainActor
@Observable
final class CloudPreferences {
    static let shared = CloudPreferences()

    private let store = NSUbiquitousKeyValueStore.default
    private static let patternKey = "organizationPattern"
    private static let stravaSyncKey = "stravaLastSyncRun"
    private var kvsObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    /// Clés @AppStorage synchronisées telles quelles (miroir transparent UserDefaults ↔ iCloud KVS) :
    /// préférences Général + affichage carte mémorisé + modèles vidéo créés. (État de fenêtre et
    /// appCreatedAssets — identifiants PHAsset spécifiques à la machine — restent locaux.)
    private enum Kind { case string, bool, double }
    private static let mirroredKeys: [(key: String, kind: Kind)] = [
        ("defaultMapLayer", .string),
        ("photosSelectedByDefault", .bool),
        ("photosOnMapEnabled", .bool),
        ("trackColorMode", .string),
        ("slopeOverlayEnabled", .bool),
        ("slopeOverlayOpacity", .double),
        ("videoUserTemplates", .string),
        ("videoSelectedTemplate", .string),
        ("pauseThresholdMinutes", .double),
        ("pauseRadiusMeters", .double),
    ]

    /// Modèle d'organisation iCloud — unique pour tous les appareils (dernière modification gagne).
    var organizationPattern: String {
        didSet {
            guard organizationPattern != oldValue else { return }
            store.set(organizationPattern, forKey: Self.patternKey)
            UserDefaults.standard.set(organizationPattern, forKey: Self.patternKey) // miroir pour les lectures existantes
        }
    }

    /// Horodatage (timeIntervalSince1970) de la dernière synchro Strava, 0 si jamais. Partagé entre appareils.
    var stravaLastSyncRun: Double {
        didSet {
            guard stravaLastSyncRun != oldValue else { return }
            store.set(stravaLastSyncRun, forKey: Self.stravaSyncKey)
            UserDefaults.standard.set(stravaLastSyncRun, forKey: Self.stravaSyncKey)
        }
    }

    var stravaLastSyncDate: Date? { stravaLastSyncRun > 0 ? Date(timeIntervalSince1970: stravaLastSyncRun) : nil }

    private init() {
        let pattern = store.string(forKey: Self.patternKey)
            ?? UserDefaults.standard.string(forKey: Self.patternKey)
            ?? OrganizationPattern.default.template
        // Au premier lancement on ne perd pas un run local plus récent que ce qui est dans iCloud.
        let strava = max(store.double(forKey: Self.stravaSyncKey), UserDefaults.standard.double(forKey: Self.stravaSyncKey))

        organizationPattern = pattern
        stravaLastSyncRun = strava
        // Pousse les valeurs locales vers iCloud au premier lancement et garde UserDefaults à jour.
        store.set(pattern, forKey: Self.patternKey); UserDefaults.standard.set(pattern, forKey: Self.patternKey)
        store.set(strava, forKey: Self.stravaSyncKey); UserDefaults.standard.set(strava, forKey: Self.stravaSyncKey)

        // Miroir initial des clés @AppStorage : iCloud gagne s'il a la valeur, sinon on pousse la valeur locale.
        for (key, kind) in Self.mirroredKeys {
            if store.object(forKey: key) != nil { pull(key, kind) }
            else if UserDefaults.standard.object(forKey: key) != nil { push(key, kind) }
        }

        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.adoptRemoteValues(note) }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushLocalChanges() }
        }
        store.synchronize()
    }

    func markStravaSyncedNow() { stravaLastSyncRun = Date().timeIntervalSince1970 }
    func resetStravaSync() { stravaLastSyncRun = 0 }

    // MARK: Miroir UserDefaults ↔ iCloud KVS (clés @AppStorage)

    private func push(_ key: String, _ kind: Kind) {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return }
        switch kind {
        case .string: store.set(d.string(forKey: key) ?? "", forKey: key)
        case .bool:   store.set(d.bool(forKey: key), forKey: key)
        case .double: store.set(d.double(forKey: key), forKey: key)
        }
    }

    private func pull(_ key: String, _ kind: Kind) {
        guard store.object(forKey: key) != nil else { return }
        switch kind {
        case .string: UserDefaults.standard.set(store.string(forKey: key), forKey: key)
        case .bool:   UserDefaults.standard.set(store.bool(forKey: key), forKey: key)
        case .double: UserDefaults.standard.set(store.double(forKey: key), forKey: key)
        }
    }

    private func differs(_ key: String, _ kind: Kind) -> Bool {
        let d = UserDefaults.standard
        switch kind {
        case .string: return (d.string(forKey: key) ?? "") != (store.string(forKey: key) ?? "")
        case .bool:   return d.bool(forKey: key) != store.bool(forKey: key)
        case .double: return d.double(forKey: key) != store.double(forKey: key)
        }
    }

    /// Une préférence locale a changé → on la pousse vers iCloud (les valeurs déjà identiques sont ignorées).
    private func pushLocalChanges() {
        for (key, kind) in Self.mirroredKeys where differs(key, kind) { push(key, kind) }
    }

    /// Un autre appareil a modifié une valeur → on adopte uniquement les clés réellement changées.
    private func adoptRemoteValues(_ note: Notification) {
        let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        if changed.contains(Self.patternKey), let remote = store.string(forKey: Self.patternKey), remote != organizationPattern {
            organizationPattern = remote
        }
        if changed.contains(Self.stravaSyncKey) {
            let remote = store.double(forKey: Self.stravaSyncKey)
            if remote != stravaLastSyncRun { stravaLastSyncRun = remote }
        }
        for (key, kind) in Self.mirroredKeys where changed.contains(key) { pull(key, kind) }
    }
}
