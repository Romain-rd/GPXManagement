import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct MaintenanceView: View {
    @Bindable private var services = AppServices.shared
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Nommage d'après le parcours") {
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Origine des fichiers") {
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Re-traitement des tracés") {
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Synchronisation iCloud") {
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Récupération") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recrée les activités depuis les fichiers GPX/FIT déjà présents dans le conteneur, **sans rien copier ni supprimer**. À utiliser après une perte des métadonnées (ex. reset du miroir CloudKit). Les tags, notes, raids et parcours manuels ne sont pas restaurés.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button {
                                Task { await services.rebuildLibraryFromStorage() }
                            } label: {
                                Label("Reconstruire depuis les fichiers", systemImage: "arrow.clockwise")
                            }
                            .disabled(services.isDeletingAll)

                            if services.isDeletingAll, let progress = services.watchedFolderProgress {
                                ProgressView().controlSize(.small)
                                Text(progress).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let summary = services.lastMaintenanceSummary {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Zone de danger") {
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
}
