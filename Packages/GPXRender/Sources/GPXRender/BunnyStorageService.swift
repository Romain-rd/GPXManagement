import Foundation

public enum BunnyStorageError: Error, LocalizedError {
    case notConfigured
    case zoneLookupFailed(status: Int)
    case requestFailed(path: String, status: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Bunny n'est pas configuré (renseigner BUNNY_API_KEY et BUNNY_STORAGE_ZONE_ID dans Secrets.xcconfig)."
        case let .zoneLookupFailed(status):
            return "Impossible de récupérer la zone de stockage Bunny (HTTP \(status)) — vérifier la clé API de compte et l'ID de zone."
        case let .requestFailed(path, status):
            return "Échec de l'envoi vers Bunny (\(path) — HTTP \(status))."
        }
    }
}

/// Publication d'une page (dossier de fichiers) sur Bunny Storage.
/// La clé API de compte (générique) et l'ID de zone sont lus dans Info.plist (injectés depuis
/// Secrets.xcconfig, non versionnés). Le nom de zone, le mot de passe Storage et le host régional
/// sont résolus à la volée via l'API de management — pas de mot de passe Storage à stocker.
public enum BunnyStorageService {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    private static var apiKey: String { info("BunnyApiKey") }
    private static var zoneId: String { info("BunnyStorageZoneId") }

    public static var isConfigured: Bool {
        !apiKey.isEmpty && apiKey != "TODO" && !zoneId.isEmpty && zoneId != "TODO"
    }

    private struct ResolvedZone {
        let name: String
        let password: String
        let host: String
    }

    private struct ZoneInfo: Decodable {
        let name: String
        let password: String
        let storageHostname: String?
        enum CodingKeys: String, CodingKey {
            case name = "Name", password = "Password", storageHostname = "StorageHostname"
        }
    }

    /// Envoie tous les fichiers (clé = chemin relatif) sous `folder/`, après suppression du dossier existant.
    public static func publish(files: [String: Data], folder: String, onProgress: ((Double, String) -> Void)? = nil) async throws {
        guard isConfigured else { throw BunnyStorageError.notConfigured }
        let zone = try await resolveZone()
        try? await deleteFolder(folder, zone: zone)
        let total = max(files.count, 1)
        var done = 0
        for (rel, data) in files {
            try await put(path: "\(folder)/\(rel)", data: data, zone: zone)
            done += 1
            onProgress?(Double(done) / Double(total), "Envoi \(done)/\(total)…")
        }
        onProgress?(1, "Invalidation du cache…")
        await purgeCache(folder: folder)
    }

    private static let publicBase = "https://www.gpxmanagement.net/"

    /// Purge le cache CDN de la pull zone pour le dossier publié (sinon l'ancienne version reste servie).
    private static func purgeCache(folder: String) async {
        let target = "\(publicBase)\(folder)/*"
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.bunny.net/purge?url=\(encoded)&async=false") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "AccessKey")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func resolveZone() async throws -> ResolvedZone {
        guard let url = URL(string: "https://api.bunny.net/storagezone/\(zoneId)") else {
            throw BunnyStorageError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw BunnyStorageError.zoneLookupFailed(status: status) }
        let info = try JSONDecoder().decode(ZoneInfo.self, from: data)
        let host = (info.storageHostname?.isEmpty == false) ? info.storageHostname! : "storage.bunnycdn.com"
        return ResolvedZone(name: info.name, password: info.password, host: host)
    }

    private static func put(path: String, data: Data, zone: ResolvedZone) async throws {
        guard let url = URL(string: "https://\(zone.host)/\(zone.name)/\(path)") else {
            throw BunnyStorageError.requestFailed(path: path, status: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(zone.password, forHTTPHeaderField: "AccessKey")
        request.setValue(contentType(for: path), forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw BunnyStorageError.requestFailed(path: path, status: status)
        }
    }

    private static func deleteFolder(_ folder: String, zone: ResolvedZone) async throws {
        guard let url = URL(string: "https://\(zone.host)/\(zone.name)/\(folder)/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(zone.password, forHTTPHeaderField: "AccessKey")
        _ = try await URLSession.shared.data(for: request)
    }

    private static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "css":  return "text/css"
        case "js":   return "application/javascript"
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        default:     return "application/octet-stream"
        }
    }
}
