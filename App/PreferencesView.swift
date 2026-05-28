import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("Général", systemImage: "gearshape") }
            OrganizationPreferencesView()
                .tabItem { Label("Organisation iCloud", systemImage: "folder") }
            StravaPreferencesView()
                .tabItem { Label("Strava", systemImage: "arrow.triangle.2.circlepath") }
            AboutView()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
    }
}

struct GeneralPreferencesView: View {
    @AppStorage("defaultMapLayer") private var mapLayer: String = MapLayer.ignPlanV2.rawValue

    var body: some View {
        Form {
            Picker("Couche carte par défaut", selection: $mapLayer) {
                ForEach(MapLayer.allCases) { layer in
                    Text(layer.displayName).tag(layer.rawValue)
                }
            }
        }
        .padding()
    }
}

struct OrganizationPreferencesView: View {
    @AppStorage("organizationPattern") private var pattern: String = OrganizationPattern.default.template
    @State private var watchedFolderPath: String = ""

    var body: some View {
        Form {
            Section("Modèle d'organisation") {
                Picker("Modèle prédéfini", selection: $pattern) {
                    ForEach(OrganizationPattern.presets, id: \.template) { preset in
                        Text(preset.label).tag(preset.template)
                    }
                }
                TextField("Modèle personnalisé", text: $pattern, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                Text("Variables : {year}, {month}, {day}, {activity}, {subactivity}, {title}, {ext}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Réorganiser maintenant") {}
                        .disabled(true)
                        .help("Fonctionnalité prévue ultérieurement")
                }
            }

            Section("Dossier surveillé (HealthFit, etc.)") {
                if watchedFolderPath.isEmpty {
                    Text("Aucun dossier configuré.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(watchedFolderPath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choisir un dossier…") {
                        pickFolder()
                    }
                    Button("Oublier") {
                        WatchedFolderBookmark.clear()
                        watchedFolderPath = ""
                    }
                    .disabled(watchedFolderPath.isEmpty)
                }
                Text("Les fichiers GPX/FIT déposés par HealthFit ou un autre service de sync dans ce dossier iCloud seront proposés à l'import (avec filtrage automatique des doublons).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            watchedFolderPath = WatchedFolderBookmark.resolve()?.path ?? ""
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choisir un dossier à surveiller"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        try? WatchedFolderBookmark.save(url: folder)
        watchedFolderPath = folder.path
    }
}

struct StravaPreferencesView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Synchronisation Strava").font(.title3)
            Text("Disponible en P8 (Strava sync).")
                .foregroundStyle(.secondary)
            Button("Connecter Strava") {}
                .disabled(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("GPXManagement").font(.title2.bold())
            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                .foregroundStyle(.secondary)
            Text("Application macOS native pour gérer vos fichiers GPS.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
