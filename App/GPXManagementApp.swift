import SwiftUI
import GPXCore
import Sparkle

@main
struct GPXManagementApp: App {
    @State private var services = AppServices.shared
    @State private var updateGate = UpdateGate.shared
    // Sparkle : démarre les vérifications automatiques (appcast SUFeedURL) dès le lancement.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
                    .alphaRibbon()
                    .task { await updateGate.check() }
                    .sheet(isPresented: Binding(get: { updateGate.showUpdateSheet }, set: { updateGate.showUpdateSheet = $0 })) {
                        UpdateAvailableView(notes: updateGate.notes, latestBuild: updateGate.latestBuild ?? 0) {
                            updateGate.showUpdateSheet = false
                            updaterController.updater.checkForUpdates()
                        }
                    }
            }
        }
        .commands {
            AppMenuCommands(services: services)
            CommandGroup(after: .appInfo) {
                Button("Rechercher les mises à jour…") {
                    updaterController.updater.checkForUpdates()
                }
            }
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
    private(set) var notes = ""
    /// `true` si le build installé est sous le plancher imposé (confirmé en ligne ou connu d'un appel précédent).
    var mustUpdate: Bool
    /// Pilote l'affichage de la fenêtre de nouveautés au démarrage (une fois par lancement).
    var showUpdateSheet = false
    private var didOfferThisLaunch = false

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
        notes = feed.notes ?? ""
        UserDefaults.standard.set(feed.minimumBuild, forKey: Self.lastMinKey)
        mustUpdate = Self.currentBuild < feed.minimumBuild
        // Au démarrage : si une nouvelle version est dispo (et qu'on n'est pas bloqué), proposer les nouveautés une fois.
        if !mustUpdate, Self.currentBuild < feed.latestBuild, !didOfferThisLaunch {
            didOfferThisLaunch = true
            showUpdateSheet = true
        }
    }
}

private struct VersionFeed: Decodable {
    let latestBuild: Int
    let minimumBuild: Int
    let downloadURL: String?
    let notes: String?
}

/// Fenêtre de nouveautés affichée au démarrage quand une nouvelle version est disponible : montre les
/// notes de version pour motiver la mise à jour, et délègue l'installation à Sparkle.
struct UpdateAvailableView: View {
    let notes: String
    let latestBuild: Int
    let onUpdate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nouvelle version disponible").font(.title2.bold())
                    Text("Build \(latestBuild)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
            }
            HStack {
                Spacer()
                Button("Plus tard") { dismiss() }
                Button("Mettre à jour") { onUpdate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
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
