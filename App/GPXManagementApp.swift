import SwiftUI

@main
struct GPXManagementApp: App {
    @State private var services = AppServices.shared

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        registerUbiquityContainer()
    }

    var body: some Scene {
        WindowGroup {
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
            } else {
                ContentView(services: services)
                    .environment(\.managedObjectContext, services.persistence.container.viewContext)
                    .alphaRibbon()
            }
        }
        .commands {
            AppMenuCommands(services: services)
        }

        WindowGroup(for: UUID.self) { $activityId in
            if AppConfig.isAlphaExpired {
                AlphaExpiredView()
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
                ActivityDetailView(activity: activity, listVM: model.listVM, repository: repo, isStandaloneWindow: true, fullscreenMap: $detailFullscreen)
                    .navigationTitle(activity.title)
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
