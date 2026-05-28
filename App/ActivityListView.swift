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
                    pickFilesForImport()
                } label: {
                    Label("Importer des fichiers GPX/FIT…", systemImage: "doc.badge.plus")
                }
                Button {
                    scanWatchedFolder()
                } label: {
                    Label("Importer depuis HealthFit / dossier iCloud…", systemImage: "applewatch.radiowaves.left.and.right")
                }
                Button {
                    pickAppleHealthExport()
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

    private func pickFilesForImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "gpx") ?? .xml,
            .init(filenameExtension: "fit") ?? .data
        ]
        panel.title = "Choisir des fichiers GPX ou FIT"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await services.prepareImports(from: urls) }
    }

    private func scanWatchedFolder() {
        if let saved = WatchedFolderBookmark.resolve() {
            Task { await services.scanWatchedFolder(saved) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choisir un dossier à surveiller"
        panel.message = "Sélectionnez le dossier iCloud où HealthFit (ou un autre service) dépose vos fichiers GPX/FIT."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        try? WatchedFolderBookmark.save(url: folder)
        Task { await services.scanWatchedFolder(folder) }
    }

    private func pickAppleHealthExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choisir le dossier d'export Apple Santé"
        panel.message = "Sélectionnez le dossier qui contient export.xml (et workout-routes/)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await services.importAppleHealthExport(rootURL: folder) }
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    private static func subtitle(for activity: ActivitySummary) -> String {
        let relative = relativeFormatter.localizedString(for: activity.startDate, relativeTo: Date())
        return "\(activity.activityType.displayName) · \(relative)"
    }

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }
}
