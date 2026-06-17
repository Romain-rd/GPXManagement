import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

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
