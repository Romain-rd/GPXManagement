import SwiftUI
import AppKit
import PhotosUI
import Photos
import CoreLocation
import MapKit
import GPXCore
import GPXRender
import GPXVideo
import GPXMapKit

/// Liste des raids (colonne centrale) — sélectionner un raid ouvre son détail dans la 3ᵉ colonne (comme une activité).
struct RaidsListView: View {
    @Bindable var listVM: ActivityListViewModel
    @Bindable var navigation: AppNavigationModel
    @Environment(\.openWindow) private var openWindow
    @State private var renamingRaid: Raid?
    @State private var renameText = ""

    private var visibleRaids: [(raid: Raid, count: Int)] {
        guard let type = navigation.selectedActivityType else { return listVM.availableRaids }
        return listVM.availableRaids.filter { listVM.raidDominantType($0.raid.id) == type }
    }

    var body: some View {
        List(selection: Binding(
            get: { navigation.selectedRaidInListId },
            set: { if let id = $0 { navigation.selectRaid(id) } }
        )) {
            ForEach(visibleRaids, id: \.raid.id) { entry in
                row(entry.raid, count: entry.count)
                    .tag(entry.raid.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let raid = listVM.raids.first(where: { $0.id == id }) {
                Button("Ouvrir dans une nouvelle fenêtre") { openWindow(value: id) }
                Divider()
                Button("Renommer…") { renameText = raid.name; renamingRaid = raid }
                Button("Supprimer le raid", role: .destructive) {
                    Task { await listVM.deleteRaid(id) }
                    if navigation.selectedRaidInListId == id { navigation.selectedRaidInListId = nil }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { openWindow(value: id) }
        }
        .navigationTitle("Tous les raids")
        .alert("Renommer le raid", isPresented: Binding(get: { renamingRaid != nil }, set: { if !$0 { renamingRaid = nil } })) {
            TextField("Nom", text: $renameText)
            Button("Renommer") {
                if let raid = renamingRaid {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { Task { await listVM.renameRaid(raid.id, name: name) } }
                }
                renamingRaid = nil
            }
            Button("Annuler", role: .cancel) { renamingRaid = nil }
        }
    }

    private func row(_ raid: Raid, count: Int) -> some View {
        HStack(spacing: 12) {
            if let data = raid.coverImageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "flag.2.crossed").foregroundStyle(.orange))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(raid.name).fontWeight(.medium)
                    if raid.isPublished {
                        Image(systemName: "globe").font(.caption2).foregroundStyle(.tint).help("Publié sur le web")
                    }
                }
                Text("\(count) activité(s)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
