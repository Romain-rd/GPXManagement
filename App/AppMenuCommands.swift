import SwiftUI
import GPXCore

struct AppMenuCommands: Commands {
    @Bindable var services: AppServices
    @FocusedValue(\.windowModel) private var window: WindowModel?

    var body: some Commands {
        // Menu Fichier : on garde "Nouvelle fenêtre" (fourni par WindowGroup) et on ajoute imports/exports juste après.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Importer des fichiers GPX/FIT…") {
                services.importFilesViaPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Importer depuis HealthFit / dossier iCloud…") {
                services.importWatchedFolderViaPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Importer depuis Apple Santé (export ZIP)…") {
                services.importAppleHealthViaPanel()
            }

            Button("Importer un export Strava (ZIP ou dossier)…") {
                services.importStravaViaPanel()
            }

            Divider()

            Button("Exporter l'activité en GPX…") {
                window?.exportSelectedActivityGPX()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(window?.hasSelection ?? false))

            Menu("Exporter la carte en PNG") {
                Button("Exporter la vue") { window?.requestMapExport(fullRoute: false) }
                Button("Exporter tout le parcours") { window?.requestMapExport(fullRoute: true) }
            }
            .disabled(!(window?.canExportMap ?? false))
        }

        // Menu Présentation : bascule des 3 modes (fenêtre active).
        CommandMenu("Présentation") {
            Button("Activités") { window?.navigation.visualizationMode = .activities }
                .keyboardShortcut("1", modifiers: .command)
            Button("Statistiques") { window?.navigation.visualizationMode = .statistics }
                .keyboardShortcut("2", modifiers: .command)
            Button("Vue d'ensemble") { window?.navigation.visualizationMode = .mapOverview }
                .keyboardShortcut("3", modifiers: .command)
        }

        // Menu Activité : actions sur la sélection (fenêtre active).
        CommandMenu("Activité") {
            Button("Renommer d'après le parcours") {
                window?.renameSelectedFromRoute()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(window?.hasSelection ?? false))

            Menu("Changer le type") {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        window?.changeTypeOfSelection(type)
                    }
                }
            }
            .disabled(!(window?.hasSelection ?? false))

            Divider()

            Button("Supprimer") {
                window?.deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(window?.hasSelection ?? false))
        }
    }
}
