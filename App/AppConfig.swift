import Foundation

enum AppConfig {
    static let iCloudContainerIdentifier = "iCloud.com.demoustier.GPXManagement"

    /// Numéro de build (CFBundleVersion), affiché dans le bandeau alpha.
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    /// Version complète « 1.0 (4) » (version courte + build).
    static var fullVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(short) (\(buildNumber))"
    }

    /// Page de la version alpha (téléchargement), ouverte au clic sur le bandeau.
    static let alphaURL = URL(string: "https://www.gpxmanagement.net/download/")!

    /// Page d'aide du site, ouverte depuis le menu Aide.
    static let helpURL = URL(string: "https://www.gpxmanagement.net/aide/")!

    /// Date d'expiration de la version alpha : à partir de cette date, l'app refuse de s'ouvrir.
    static let alphaExpiry: Date = {
        var c = DateComponents()
        c.year = 2027; c.month = 1; c.day = 1
        return Calendar.current.date(from: c) ?? .distantFuture
    }()

    static let alphaExpiryLabel = "1ᵉʳ janvier 2027"

    static var isAlphaExpired: Bool { Date() >= alphaExpiry }
}
