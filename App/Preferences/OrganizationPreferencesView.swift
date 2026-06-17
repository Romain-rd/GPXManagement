import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct OrganizationPreferencesView: View {
    @Bindable private var services = AppServices.shared
    @State private var watchedFolderPath: String = ""
    @State private var showReorganizeConfirmation = false
    @State private var reorganizeAlreadyTidy = false

    var body: some View {
        Form {
            Section("Modèle d'organisation") {
                Text("Vos fichiers GPX/FIT sont rangés dans iCloud par **chronologie** : `Année / Mois`, chaque fichier nommé `aaaa-mm-jj_activité_titre`. Ce modèle est imposé et n'est pas modifiable.")
                    .font(.callout)
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
                    .help("Déplace les fichiers iCloud pour les ranger par chronologie")
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
                    Text("\(services.pendingReorganizeCount) fichier(s) seront déplacés dans iCloud pour les ranger par chronologie (Année / Mois). La synchronisation s'appliquera sur tous vos appareils.")
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
