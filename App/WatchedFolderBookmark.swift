import Foundation

enum WatchedFolderBookmark {
    private static let defaultsKey = "watchedImportFolder.bookmark"
    private static let lastScanKey = "watchedImportFolder.lastScanDate"

    /// Date du dernier scan auto réussi : l'import auto ne propose que les fichiers plus récents.
    /// `nil` tant qu'aucun scan auto n'a eu lieu (le retard existant n'est jamais proposé en auto).
    static var lastScanDate: Date? {
        get { UserDefaults.standard.object(forKey: lastScanKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastScanKey) }
    }

    static func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                try? save(url: url)
            }
            return url
        } catch {
            NSLog("GPXManagement: failed to resolve watched folder bookmark: \(error)")
            return nil
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: lastScanKey)
    }
}
