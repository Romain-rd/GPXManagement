import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GPXCore

struct ActivityListView: View {
    @Bindable var listVM: ActivityListViewModel
    @Bindable var navigation: AppNavigationModel
    @Bindable var services: AppServices
    @State private var isDropTargeted = false

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

            Menu {
                Button {
                    services.importFilesViaPanel()
                } label: {
                    Label("Importer des fichiers GPX/FIT…", systemImage: "doc.badge.plus")
                }
                Button {
                    services.importWatchedFolderViaPanel()
                } label: {
                    Label("Importer depuis HealthFit / dossier iCloud…", systemImage: "applewatch.radiowaves.left.and.right")
                }
                Button {
                    services.importAppleHealthViaPanel()
                } label: {
                    Label("Importer depuis Apple Santé (export ZIP)…", systemImage: "heart.text.square")
                }
            } label: {
                Label("Importer", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            if services.isScanningHealthExport || services.isScanningWatchedFolder {
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
            Menu {
                ForEach(ActivityType.allCases, id: \.self) { type in
                    Button {
                        let ids = navigation.listSelection
                        Task { await listVM.updateType(ids: ids, type: type) }
                    } label: {
                        Label(type.displayName, systemImage: type.symbolName)
                    }
                }
            } label: {
                Label("Changer le type", systemImage: "tag")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)

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
        HStack(spacing: 12) {
            Image(systemName: activity.activityType.symbolName)
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.headline)
                Text(Self.subtitle(for: activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.formatDistance(activity.distance))
                    .font(.callout.monospacedDigit())
                Text("\(Int(activity.elevationGain.rounded())) m D+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private static func subtitle(for activity: ActivitySummary) -> String {
        let date = dateFormatter.string(from: activity.startDate)
        return "\(activity.activityType.displayName) · \(date)"
    }

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }
}
