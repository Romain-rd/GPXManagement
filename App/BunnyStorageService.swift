import Foundation

enum BunnyStorageError: Error, LocalizedError {
    case notConfigured
    case requestFailed(path: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Bunny n'est pas configuré (renseigner BUNNY_STORAGE_ZONE et BUNNY_STORAGE_KEY dans Secrets.xcconfig)."
        case let .requestFailed(path, status):
            return "Échec de l'envoi vers Bunny (\(path) — HTTP \(status))."
        }
    }
}

/// Publication d'une page (dossier de fichiers) sur Bunny Storage. Identifiants lus dans Info.plist
/// (injectés depuis Secrets.xcconfig, non versionnés).
enum BunnyStorageService {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    private static var zone: String { info("BunnyStorageZone") }
    private static var key: String { info("BunnyStorageKey") }
    private static var region: String { info("BunnyStorageRegion") }

    static var isConfigured: Bool {
        !zone.isEmpty && zone != "TODO" && !key.isEmpty && key != "TODO"
    }

    private static var host: String {
        region.isEmpty ? "storage.bunnycdn.com" : "\(region).storage.bunnycdn.com"
    }

    /// Envoie tous les fichiers (clé = chemin relatif) sous `folder/`, après suppression du dossier existant.
    static func publish(files: [String: Data], folder: String) async throws {
        guard isConfigured else { throw BunnyStorageError.notConfigured }
        try? await deleteFolder(folder)
        for (rel, data) in files {
            try await put(path: "\(folder)/\(rel)", data: data)
        }
    }

    private static func put(path: String, data: Data) async throws {
        guard let url = URL(string: "https://\(host)/\(zone)/\(path)") else {
            throw BunnyStorageError.requestFailed(path: path, status: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(key, forHTTPHeaderField: "AccessKey")
        request.setValue(contentType(for: path), forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw BunnyStorageError.requestFailed(path: path, status: status)
        }
    }

    private static func deleteFolder(_ folder: String) async throws {
        guard let url = URL(string: "https://\(host)/\(zone)/\(folder)/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "AccessKey")
        _ = try await URLSession.shared.data(for: request)
    }

    private static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "css":  return "text/css"
        case "js":   return "application/javascript"
        default:     return "application/octet-stream"
        }
    }
}
