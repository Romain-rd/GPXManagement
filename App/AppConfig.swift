import Foundation

enum AppConfig {
    static let iCloudContainerIdentifier = "iCloud.com.demoustier.GPXManagement"

    /// Numéro de build (CFBundleVersion), affiché dans le bandeau alpha.
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    /// Page de la version alpha, ouverte au clic sur le bandeau.
    static let alphaURL = URL(string: "https://www.gpxmanagement.net/alpha/")!
}
