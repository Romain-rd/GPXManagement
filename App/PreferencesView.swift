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
            MaintenanceView()
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
            StravaPreferencesView()
                .tabItem { Label("Strava", systemImage: "arrow.triangle.2.circlepath") }
            AboutView()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
    }
}

struct GeneralPreferencesView: View {
    @AppStorage("defaultMapLayer") private var mapLayer: String = MapLayer.ignScan25.rawValue

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
    @Bindable private var services = AppServices.shared
    @AppStorage("organizationPattern") private var pattern: String = OrganizationPattern.default.template
    @State private var watchedFolderPath: String = ""
    @State private var showReorganizeConfirmation = false
    @State private var reorganizeAlreadyTidy = false

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
                    if services.isReorganizing {
                        ProgressView().controlSize(.small)
                        Text(services.reorganizeProgress ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if reorganizeAlreadyTidy {
                        Text("Déjà organisé selon le modèle.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Réorganiser maintenant") {
                        Task {
                            reorganizeAlreadyTidy = false
                            let count = await services.prepareReorganization()
                            if count > 0 { showReorganizeConfirmation = true }
                            else { reorganizeAlreadyTidy = true }
                        }
                    }
                    .disabled(services.isReorganizing)
                    .help("Déplace les fichiers iCloud pour correspondre au modèle choisi")
                }
                .confirmationDialog(
                    "Réorganiser les fichiers ?",
                    isPresented: $showReorganizeConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Déplacer \(services.pendingReorganizeCount) fichier(s)") {
                        Task { await services.applyReorganization() }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("\(services.pendingReorganizeCount) fichier(s) seront déplacés dans iCloud pour correspondre au modèle « \(pattern) ». La synchronisation s'appliquera sur tous vos appareils.")
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

struct MaintenanceView: View {
    @Bindable private var services = AppServices.shared
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section("Nommage d'après le parcours") {
                Text("Renomme **toutes** les activités de la bibliothèque selon le lieu de départ, le point de passage notable et le lieu d'arrivée (via géocodage inverse).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        Task { await services.renameAllActivitiesFromRoute() }
                    } label: {
                        Label("Renommer toutes les activités", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(services.isRenamingAll)

                    if services.isRenamingAll {
                        ProgressView().controlSize(.small)
                        Text(services.renameAllProgress ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let summary = services.lastMaintenanceSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Nécessite une connexion réseau. Le débit du géocodage Apple est limité ; sur de gros volumes, certaines activités peuvent être ignorées (leur nom actuel est alors conservé).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Origine des fichiers") {
                Text("Relit chaque fichier GPX/FIT/TCX stocké pour déterminer l'application qui l'a généré (Strava, Garmin, Komoot…). Utile pour les activités importées avant l'ajout de cette information.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        Task { await services.recalculateSources() }
                    } label: {
                        Label("Recalculer les sources", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(services.isRecalculatingSources)

                    if services.isRecalculatingSources {
                        ProgressView().controlSize(.small)
                        Text(services.recalcSourcesProgress ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let summary = services.lastMaintenanceSummary, !services.isRenamingAll {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Re-traitement des tracés") {
                Text("Relit chaque fichier et **recalcule le tracé et les statistiques** (distance, durée, dénivelé). Corrige les tracés mal interprétés, comme les fichiers Scenic dont les waypoints départ/arrivée déformaient la carte et annulaient la durée.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        Task { await services.reprocessAllFromSource() }
                    } label: {
                        Label("Re-traiter les fichiers", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(services.isReprocessing)

                    if services.isReprocessing {
                        ProgressView().controlSize(.small)
                        Text(services.reprocessProgress ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Synchronisation iCloud") {
                Text("Force la republication de **toutes** les activités vers CloudKit. À utiliser si une machine présente moins d'activités que les autres (par exemple, l'historique local n'a jamais été poussé par le mirroring).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        Task { await services.forceCloudKitResync() }
                    } label: {
                        Label("Forcer la resync CloudKit", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(services.isForcingCloudKitResync)

                    if services.isForcingCloudKitResync {
                        ProgressView().controlSize(.small)
                        Text(services.cloudKitResyncProgress ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Action sans danger : marque chaque activité comme modifiée. La sync vers les autres Macs peut prendre plusieurs minutes selon le volume.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Zone de danger") {
                Text("Supprime **toutes** les activités et leurs fichiers, localement et dans iCloud (la suppression se synchronise sur tous vos appareils). Action **irréversible**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Tout supprimer…", systemImage: "trash")
                    }
                    .disabled(services.isDeletingAll)

                    if services.isDeletingAll {
                        ProgressView().controlSize(.small)
                        Text("Suppression en cours…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .confirmationDialog(
                    "Supprimer toutes les données ?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Tout supprimer", role: .destructive) {
                        Task { await services.deleteAllData() }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Toutes les activités et leurs fichiers GPX/FIT/TCX seront définitivement supprimés, y compris dans iCloud. Cette action est irréversible.")
                }
            }
        }
        .padding()
    }
}

struct StravaPreferencesView: View {
    @Bindable private var strava = AppServices.shared.strava
    @Bindable private var services = AppServices.shared

    var body: some View {
        Form {
            Section("Compte") {
                if strava.isConnected {
                    LabeledContent("État") {
                        Label("Connecté", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let name = strava.athleteName, !name.isEmpty {
                        LabeledContent("Athlète", value: name)
                    }
                    Button("Déconnecter", role: .destructive) {
                        strava.disconnect()
                    }
                } else {
                    LabeledContent {
                        Button {
                            Task { await strava.connect() }
                        } label: {
                            Image("StravaConnectButton")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        .disabled(strava.isConnecting || !strava.isConfigured)
                    } label: {
                        Text("Connectez votre compte Strava pour synchroniser vos activités.")
                    }
                    if strava.isConnecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Autorisation dans le navigateur…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !strava.isConfigured {
                        Text("Identifiants Strava absents — renseignez STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET dans Secrets.xcconfig.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                if let error = strava.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            if strava.isConnected {
                Section {
                    LabeledContent("Synchroniser") {
                        HStack(spacing: 8) {
                            if services.isSyncingStrava {
                                ProgressView().controlSize(.small)
                                Text(services.stravaSyncProgress ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Button {
                                Task { await services.syncStrava() }
                            } label: {
                                Label("Maintenant", systemImage: "arrow.down.circle")
                            }
                            .disabled(services.isSyncingStrava)
                        }
                    }
                    if let last = services.stravaLastSyncDate {
                        LabeledContent("Dernière sync", value: Self.formatDate(last))
                    }
                    if let summary = services.lastStravaSyncSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synchronisation")
                } footer: {
                    Text("Récupère vos activités GPS depuis la dernière synchronisation (déduplication automatique). Le débit Strava est limité ; sur un gros historique la sync reprend là où elle s'est arrêtée.")
                }
            }

            Section {
                HStack(spacing: 8) {
                    Button {
                        services.importStravaViaPanel()
                    } label: {
                        Label("Importer un export Strava…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(services.isScanningWatchedFolder)

                    if services.isScanningWatchedFolder {
                        ProgressView().controlSize(.small)
                        Text(services.watchedFolderProgress ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let summary = services.lastWatchedFolderSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Import manuel")
            } footer: {
                Text("Pas de connexion ? Demandez votre archive sur strava.com (Réglages › Mon compte › Télécharger ou supprimer votre compte), puis importez ici le fichier ZIP ou le dossier « activities » décompressé. Déduplication automatique.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Image("StravaPoweredBy")
                .resizable()
                .scaledToFit()
                .frame(height: 16)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
    }

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
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
