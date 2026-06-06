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
            ContentView(services: services)
                .environment(\.managedObjectContext, services.persistence.container.viewContext)
                .alphaRibbon()
        }
        .commands {
            AppMenuCommands(services: services)
        }

        Settings {
            PreferencesView()
                .alphaRibbon()
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
