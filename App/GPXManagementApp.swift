import SwiftUI
import GPXCore

@main
struct GPXManagementApp: App {
    @State private var services = AppServices.shared
    @State private var updateGate = UpdateGate.shared

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        registerUbiquityContainer()
    }

    var body: some Scene {
        WindowGroup {
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
            } else if updateGate.mustUpdate {
                UpdateRequiredView()
            } else {
                ContentView(services: services)
                    .environment(\.managedObjectContext, services.persistence.container.viewContext)
                    .updateBanner(updateGate)
                    .alphaRibbon()
                    .task { await updateGate.check() }
            }
        }
        .commands {
            AppMenuCommands(services: services)
        }

        WindowGroup(for: UUID.self) { $activityId in
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
            } else if updateGate.mustUpdate {
                UpdateRequiredView()
            } else if let activityId {
                ActivityDetailWindowView(activityId: activityId)
                    .alphaRibbon()
            }
        }

        Settings {
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
            } else {
                PreferencesView()
                    .alphaRibbon()
            }
        }
    }

    private func registerUbiquityContainer() {
        Task.detached(priority: .utility) {
            let identifier = AppConfig.iCloudContainerIdentifier
            guard let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
                NSLog("GPXManagement: ubiquity container '\(identifier)' unavailable")
                return
            }
            NSLog("GPXManagement: ubiquity container resolved at \(url.path)")
            let documents = url.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let marker = documents.appendingPathComponent(".initialized")
            try? "GPXManagement initialized\n".write(to: marker, atomically: true, encoding: .utf8)
        }
    }
}

extension View {
    /// Filigrane discret « ALPHA x.y (build) » dans le coin bas-gauche, non bloquant (ne capte pas les clics).
    func alphaRibbon() -> some View {
        overlay(alignment: .bottomLeading) {
            Text("ALPHA \(AppConfig.fullVersion)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.red.opacity(0.6))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.background.opacity(0.4), in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Fenêtre autonome (double-clic sur une trace) affichant le détail d'une activité.
struct ActivityDetailWindowView: View {
    let activityId: UUID
    @State private var model: WindowModel
    @State private var detailFullscreen = false

    init(activityId: UUID) {
        self.activityId = activityId
        let repo = (AppServices.shared.repository as? CoreDataActivityRepository) ?? CoreDataActivityRepository(persistence: AppServices.shared.persistence)
        _model = State(initialValue: WindowModel(repository: repo))
    }

    var body: some View {
        Group {
            if let activity = model.listVM.allActivities.first(where: { $0.id == activityId }),
               let repo = AppServices.shared.repository as? CoreDataActivityRepository {
                ActivityDetailView(activity: activity, listVM: model.listVM, repository: repo, windowModel: model, isStandaloneWindow: true, fullscreenMap: $detailFullscreen)
                    .navigationTitle(detailFullscreen ? "" : activity.title)
            } else if model.listVM.allActivities.isEmpty {
                ProgressView("Chargement…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Trace introuvable", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(minWidth: 720, minHeight: 640)
        .environment(\.managedObjectContext, AppServices.shared.persistence.container.viewContext)
        .task { await model.listVM.reload() }
    }
}

/// Contrôle des mises à jour : relève une version cible sur le serveur (politique de MàJ) et, au passage,
/// transmet un identifiant d'installation **anonyme** + le build + la version macOS — de quoi reconstituer
/// l'historique des installations côté serveur. Bloque l'app sous `minimumBuild` (parc homogène).
@MainActor @Observable
final class UpdateGate {
    static let shared = UpdateGate()
    private static let installIDKey = "updateInstallID"
    private static let lastMinKey = "updateLastKnownMinimumBuild"

    static var currentBuild: Int { Int(AppConfig.buildNumber) ?? 0 }

    /// UUID aléatoire, anonyme, généré une fois par installation.
    let installID: String
    private(set) var latestBuild: Int?
    private(set) var downloadURL: URL = AppConfig.alphaURL
    /// `true` si le build installé est sous le plancher imposé (confirmé en ligne ou connu d'un appel précédent).
    var mustUpdate: Bool
    var bannerDismissed = false

    var updateAvailable: Bool { (latestBuild ?? 0) > Self.currentBuild }

    private init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: Self.installIDKey) {
            installID = id
        } else {
            let id = UUID().uuidString
            d.set(id, forKey: Self.installIDKey)
            installID = id
        }
        // Blocage immédiat hors-ligne si un appel précédent a déjà confirmé que ce build est trop vieux.
        let lastMin = d.integer(forKey: Self.lastMinKey)
        mustUpdate = lastMin > 0 && Self.currentBuild < lastMin
    }

    func check() async {
        guard var comps = URLComponents(url: AppConfig.versionFeedURL, resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [
            URLQueryItem(name: "build", value: String(Self.currentBuild)),
            URLQueryItem(name: "id", value: installID),
            URLQueryItem(name: "os", value: ProcessInfo.processInfo.operatingSystemVersionString),
            URLQueryItem(name: "v", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let feed = try? JSONDecoder().decode(VersionFeed.self, from: data) else { return }
        latestBuild = feed.latestBuild
        if let raw = feed.downloadURL, let u = URL(string: raw) { downloadURL = u }
        UserDefaults.standard.set(feed.minimumBuild, forKey: Self.lastMinKey)
        mustUpdate = Self.currentBuild < feed.minimumBuild
    }
}

private struct VersionFeed: Decodable {
    let latestBuild: Int
    let minimumBuild: Int
    let downloadURL: String?
}

extension View {
    /// Bandeau discret « nouvelle version disponible » (non bloquant), réutilisable sur le contenu principal.
    func updateBanner(_ gate: UpdateGate) -> some View {
        overlay(alignment: .bottom) {
            if gate.updateAvailable && !gate.mustUpdate && !gate.bannerDismissed {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text("Une nouvelle version est disponible.").font(.callout)
                    Button("Mettre à jour") { NSWorkspace.shared.open(gate.downloadURL) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button { gate.bannerDismissed = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .shadow(radius: 10, y: 3)
                .padding(.bottom, 18)
            }
        }
    }
}

/// Écran de blocage imposant la mise à jour quand le build est sous le plancher (`minimumBuild`).
struct UpdateRequiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Mise à jour requise")
                .font(.title.bold())
            Text("Cette version de GPXManagement est trop ancienne pour continuer.\nMerci d'installer la dernière version pour poursuivre.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Télécharger la dernière version") {
                NSWorkspace.shared.open(UpdateGate.shared.downloadURL)
            }
            .controlSize(.large)
            Text("Build \(AppConfig.buildNumber)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 320)
    }
}

/// Écran de blocage affiché lorsque la version alpha a expiré : l'app refuse de fonctionner.
struct AlphaExpiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 52))
                .foregroundStyle(.red)
            Text("Version alpha expirée")
                .font(.title.bold())
            Text("Cette version alpha de GPXManagement a expiré le \(AppConfig.alphaExpiryLabel).\nMerci d'installer une version plus récente pour continuer.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Télécharger une nouvelle version") {
                NSWorkspace.shared.open(AppConfig.alphaURL)
            }
            .controlSize(.large)
            Text("Build \(AppConfig.buildNumber)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 320)
    }
}
