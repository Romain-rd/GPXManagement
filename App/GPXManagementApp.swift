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

/// Bandeau diagonal « Alpha » + numéro de build, épinglé dans le coin haut-droit. Clic → page /alpha/.
struct AlphaRibbon: View {
    var body: some View {
        Text("ALPHA · b\(AppConfig.buildNumber)")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 44)
            .padding(.vertical, 3)
            .background(Color.red)
            .overlay(Rectangle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .rotationEffect(.degrees(45))
            .offset(x: 34, y: 14)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(AppConfig.alphaURL) }
            .help("Version alpha (build \(AppConfig.buildNumber)) — ouvrir la page /alpha/")
            .accessibilityLabel("Version alpha, build \(AppConfig.buildNumber)")
    }
}

extension View {
    /// Épingle le bandeau alpha dans le coin haut-droit de la vue.
    func alphaRibbon() -> some View {
        overlay(alignment: .topTrailing) { AlphaRibbon() }
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
