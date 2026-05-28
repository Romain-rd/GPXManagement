import SwiftUI
import GPXCore

struct AppMenuCommands: Commands {
    @Bindable var services: AppServices

    var body: some Commands {
        // Menu Fichier : remplace "Nouveau" par les imports + exports.
        CommandGroup(replacing: .newItem) {
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

            Divider()

            Button("Exporter l'activité en GPX…") {
                services.exportSelectedActivityGPX()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!services.hasSelection)

            Menu("Exporter la carte en PNG") {
                Button("Exporter la vue") { services.requestMapExport(fullRoute: false) }
                Button("Exporter tout le parcours") { services.requestMapExport(fullRoute: true) }
            }
            .disabled(!services.canExportMap)
        }

        // Menu Présentation : bascule des 3 modes.
        CommandMenu("Présentation") {
            Button("Activités") { services.navigation.visualizationMode = .activities }
                .keyboardShortcut("1", modifiers: .command)
            Button("Statistiques") { services.navigation.visualizationMode = .statistics }
                .keyboardShortcut("2", modifiers: .command)
            Button("Vue d'ensemble") { services.navigation.visualizationMode = .mapOverview }
                .keyboardShortcut("3", modifiers: .command)
        }

        // Menu Activité : actions sur la sélection.
        CommandMenu("Activité") {
            Button("Renommer d'après le parcours") {
                services.renameSelectedFromRoute()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!services.hasSelection)

            Menu("Changer le type") {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Button(type.displayName) {
                        services.changeTypeOfSelection(type)
                    }
                }
            }
            .disabled(!services.hasSelection)

            Divider()

            Button("Supprimer") {
                services.deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!services.hasSelection)
        }
    }
}
