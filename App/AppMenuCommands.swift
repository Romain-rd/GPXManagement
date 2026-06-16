import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct AppMenuCommands: Commands {
    @Bindable var services: AppServices
    @FocusedValue(\.windowModel) private var window: WindowModel?

    var body: some Commands {
        // Menu Fichier : on garde "Nouvelle fenêtre" (fournie par WindowGroup) et on ajoute imports/exports juste après.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Nouveau raid…") {
                window?.requestNewRaid()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!(window?.hasSelection ?? false))

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

            Button("Exporter l'activité en PDF…") {
                window?.exportSelectedActivityPDF()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!(window?.hasSelection ?? false))

            Menu("Exporter la carte en PNG") {
                Button("Exporter la vue") { window?.requestMapExport(fullRoute: false) }
                Button("Exporter tout le parcours") { window?.requestMapExport(fullRoute: true) }
            }
            .disabled(!(window?.canExportMap ?? false))
        }

        // Menu Présentation natif : on insère les 3 modes après la section "barre latérale" / toolbar.
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Activités") { window?.navigation.visualizationMode = .activities }
                .keyboardShortcut("1", modifiers: .command)
            Button("Statistiques") { window?.navigation.visualizationMode = .statistics }
                .keyboardShortcut("2", modifiers: .command)
            Button("Vue d'ensemble") { window?.navigation.visualizationMode = .mapOverview }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Recharger les cartes") {
                NotificationCenter.default.post(name: .reloadMapTiles, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Re-télécharge les tuiles des cartes visibles (utile si une carte ne s'est pas chargée)")
        }

        // Menu Aide : renvoie vers la page d'aide du site (remplace l'entrée d'aide native sans livre d'aide).
        CommandGroup(replacing: .help) {
            Button("Aide GPXManagement") { NSWorkspace.shared.open(AppConfig.helpURL) }
        }

        // Menu Activité : actions sur la sélection (fenêtre active).
        CommandMenu("Activité") {
            Button("Renommer d'après le parcours") {
                window?.renameSelectedFromRoute()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(window?.hasSelection ?? false))

            Menu("Changer le type") {
                activityTypeMenuItems { type in
                    window?.changeTypeOfSelection(type)
                }
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Réparer (ré-analyser le fichier source)") {
                window?.requestRepair()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Générer le profil altimétrique") {
                window?.requestGenerateElevation()
            }
            .disabled(!(window?.hasSelection ?? false))

            Divider()

            Button("Exporter en page web…") {
                window?.requestWebExport()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Créer une vidéo…") {
                window?.requestVideo()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Partager…") {
                window?.requestShare()
            }
            .disabled(!(window?.hasSelection ?? false))

            Divider()

            Button("Supprimer") {
                window?.deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(window?.hasSelection ?? false))
        }

        // Actions d'édition de trace : rattachées au menu « Édition » standard de macOS.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Dupliquer la trace") {
                window?.requestDuplicate()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Découper la trace…") {
                window?.requestSplit()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Simplifier la trace…") {
                window?.requestSimplify()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Nettoyer les points aberrants…") {
                window?.requestClean()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Inverser le sens de la trace") {
                window?.requestReverse()
            }
            .disabled(!(window?.hasSelection ?? false))

            Button("Fusionner les traces…") {
                window?.requestMerge()
            }
            .disabled(!(window?.canMerge ?? false))
        }
    }
}
