import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GPXCore
import GPXMapKit

struct ActivityListView: View {
    @Bindable var listVM: ActivityListViewModel
    @Bindable var navigation: AppNavigationModel
    @Bindable var services: AppServices
    @State private var isDropTargeted = false
    @State private var creatingRaidIds: Set<UUID>?
    @State private var newRaidName = ""

    var body: some View {
        VStack(spacing: 0) {
            sortBar
            if !navigation.listSelection.isEmpty {
                selectionBar
            }
            list
        }
        .searchable(text: $listVM.searchText, prompt: "Rechercher (titre, notes, tags)")
        .overlay {
            if isDropTargeted {
                dropOverlay
            } else if listVM.allActivities.isEmpty {
                emptyState
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await services.prepareImports(from: urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("Activités")
        .onChange(of: navigation.newRaidToken) { _, _ in
            guard !navigation.listSelection.isEmpty else { return }
            newRaidName = listVM.suggestedRaidName(for: navigation.listSelection)
            creatingRaidIds = navigation.listSelection
        }
        .alert("Nouveau raid", isPresented: Binding(get: { creatingRaidIds != nil }, set: { if !$0 { creatingRaidIds = nil } })) {
            TextField("Nom du raid", text: $newRaidName)
            Button("Annuler", role: .cancel) { creatingRaidIds = nil }
            Button("Créer") {
                if let ids = creatingRaidIds {
                    let name = newRaidName.trimmingCharacters(in: .whitespaces)
                    Task {
                        if let raidId = await listVM.createRaid(name: name.isEmpty ? "Nouveau raid" : name, activityIds: ids) {
                            navigation.listSelection = []
                            navigation.sidebarSelection = .raid(raidId)
                        }
                    }
                }
                creatingRaidIds = nil
            }
        } message: {
            Text("Regrouper \(creatingRaidIds?.count ?? 0) activité(s) sélectionnée(s) dans un raid.")
        }
    }

    private var sortBar: some View {
        HStack {
            Picker("Tri", selection: $listVM.sortOrder) {
                ForEach(ActivitySortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)

            filterMenu

            Spacer()
            if services.isPreparingImports {
                ProgressView()
                    .scaleEffect(0.7)
                Text(services.preparingImportProgress ?? "Analyse du fichier…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if services.isScanningHealthExport || services.isScanningWatchedFolder {
                ProgressView()
                    .scaleEffect(0.7)
                Text(services.healthScanProgress ?? services.watchedFolderProgress ?? "Analyse…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if let summary = services.lastWatchedFolderSummary {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text("\(listVM.visibleActivities.count) résultat(s)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var filterMenu: some View {
        Menu {
            if !listVM.filters.isEmpty {
                Button("Réinitialiser les filtres") { listVM.filters.reset() }
                Divider()
            }
            Menu("Type") {
                ForEach(listVM.availableActivityTypes, id: \.type) { entry in
                    Toggle(isOn: Binding(
                        get: { listVM.filters.activityTypes.contains(entry.type) },
                        set: { _ in listVM.filters.toggleType(entry.type) }
                    )) { Text("\(entry.type.displayName) (\(entry.count))") }
                }
            }
            if !listVM.availableYears.isEmpty {
                Menu("Année") {
                    ForEach(listVM.availableYears, id: \.year) { entry in
                        Toggle(isOn: Binding(
                            get: { listVM.filters.years.contains(entry.year) },
                            set: { _ in listVM.filters.toggleYear(entry.year) }
                        )) { Text("\(String(entry.year)) (\(entry.count))") }
                    }
                }
            }
            if !listVM.availableSources.isEmpty {
                Menu("Source") {
                    ForEach(listVM.availableSources, id: \.source) { entry in
                        Toggle(isOn: Binding(
                            get: { listVM.filters.sources.contains(entry.source) },
                            set: { _ in listVM.filters.toggleSource(entry.source) }
                        )) { Text("\(entry.source.displayName) (\(entry.count))") }
                    }
                }
            }
            if !listVM.availableTags.isEmpty {
                Menu("Tags") {
                    ForEach(listVM.availableTags, id: \.tag) { entry in
                        Toggle(isOn: Binding(
                            get: { listVM.filters.tags.contains(entry.tag) },
                            set: { _ in listVM.filters.toggleTag(entry.tag) }
                        )) { Text("\(entry.tag) (\(entry.count))") }
                    }
                }
            }
        } label: {
            Label("Filtrer", systemImage: listVM.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var selectionBar: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text("\(navigation.listSelection.count) sélectionnée(s)")
                .font(.caption)
            switch navigation.visualizationMode {
            case .statistics:
                Text("· statistiques sur la sélection")
                    .font(.caption).foregroundStyle(.secondary)
            case .mapOverview:
                Text("· affichées sur la carte")
                    .font(.caption).foregroundStyle(.secondary)
            case .activities:
                EmptyView()
            }
            Spacer()
            Button("Tout désélectionner") {
                navigation.listSelection = []
            }
            .font(.caption)
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5))
    }

    private var list: some View {
        List(selection: $navigation.listSelection) {
            ForEach(listVM.visibleActivities) { activity in
                ActivityRow(activity: activity)
                    .tag(activity.id)
            }
            .onDelete(perform: deleteActivities)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            Menu("Changer le type") {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Button {
                        Task { await listVM.updateType(ids: ids, type: type) }
                    } label: {
                        Label(type.displayName, systemImage: type.symbolName)
                    }
                }
            }
            Menu("Raid") {
                Button("Nouveau raid…") {
                    newRaidName = listVM.suggestedRaidName(for: ids)
                    creatingRaidIds = ids
                }
                if !listVM.raids.isEmpty {
                    Menu("Ajouter au raid") {
                        ForEach(listVM.raids) { raid in
                            Button(raid.name) {
                                Task { await listVM.addToRaid(raid.id, activityIds: ids) }
                            }
                        }
                    }
                }
                if ids.contains(where: { id in listVM.allActivities.first(where: { $0.id == id })?.raidId != nil }) {
                    Button("Retirer du raid") {
                        Task { await listVM.removeFromRaid(activityIds: ids) }
                    }
                }
            }
            Divider()
            Button("Supprimer", role: .destructive) {
                Task {
                    for id in ids { await listVM.delete(id: id) }
                    navigation.listSelection.subtract(ids)
                }
            }
        } primaryAction: { ids in
            if ids.count == 1 { navigation.listSelection = ids }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Aucune activité")
                .font(.title3)
            Text("Glissez ici un fichier GPX ou FIT pour démarrer.")
                .foregroundStyle(.secondary)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08))
            .padding(8)
    }

    private func deleteActivities(at offsets: IndexSet) {
        let ids = offsets.map { listVM.visibleActivities[$0].id }
        Task {
            for id in ids { await listVM.delete(id: id) }
        }
    }
}

struct ActivityRow: View {
    let activity: ActivitySummary

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.dateFormatter.string(from: activity.startDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(activity.activityType.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.formatDistance(activity.distance))
                        .fontWeight(.medium)
                    Text("\(Int(activity.elevationGain.rounded())) m D+")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 5)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Color(nsColor: activity.activityType.trackColor))
            Image(systemName: activity.activityType.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }
}
