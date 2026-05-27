import SwiftUI
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
            Spacer()
            Text("\(listVM.visibleActivities.count) résultat(s)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
