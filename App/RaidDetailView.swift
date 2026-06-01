import SwiftUI
import AppKit
import GPXCore
import GPXMapKit

struct RaidDetailView: View {
    let raid: Raid
    let listVM: ActivityListViewModel
    let repository: CoreDataActivityRepository
    let navigation: AppNavigationModel

    @State private var draft: Raid
    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignScan25.rawValue
    @State private var layer: MapLayer = .ignScan25
    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoadingMap = true
    @State private var proxy = MapViewProxy()

    init(raid: Raid, listVM: ActivityListViewModel, repository: CoreDataActivityRepository, navigation: AppNavigationModel) {
        self.raid = raid
        self.listVM = listVM
        self.repository = repository
        self.navigation = navigation
        _draft = State(initialValue: raid)
    }

    private var members: [ActivitySummary] {
        listVM.allActivities.filter { $0.raidId == raid.id }.sorted { $0.startDate < $1.startDate }
    }

    private var isDirty: Bool {
        draft.name != raid.name
            || (draft.place ?? "") != (raid.place ?? "")
            || (draft.notes ?? "") != (raid.notes ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statsGrid
                mapCard
                stepsSection
                infoSection
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(raid.name)
        .task(id: raid.id) { await loadMap() }
        .onAppear { layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25 }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "flag.2.crossed.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                TextField("Nom du raid", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .onSubmit { save() }
            }
            TextField("Lieu / région (facultatif)", text: Binding(
                get: { draft.place ?? "" },
                set: { draft.place = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .font(.title3)
            .foregroundStyle(.secondary)
            .onSubmit { save() }

            if let range = dateRangeText {
                Label(range, systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Statistiques cumulées

    private var statsGrid: some View {
        let totalDistance = members.reduce(0) { $0 + $1.distance }
        let totalGain = members.reduce(0) { $0 + $1.elevationGain }
        let totalMoving = members.reduce(0) { $0 + $1.movingDuration }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
            statTile("Étapes", "\(members.count)", "point.topleft.down.to.point.bottomright.curvepath")
            statTile("Distance", Self.formatDistance(totalDistance), "ruler")
            statTile("Dénivelé +", "\(Int(totalGain.rounded())) m", "mountain.2")
            statTile("Temps en mouvement", Self.formatDuration(totalMoving), "stopwatch")
        }
    }

    private func statTile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title3.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Carte multi-traces

    private var mapCard: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isLoadingMap {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                } else if tracks.isEmpty {
                    ContentUnavailableView("Aucune trace", systemImage: "map",
                                           description: Text("Les étapes de ce raid n'ont pas de données GPS."))
                        .frame(minHeight: 320)
                } else {
                    TrackMapView(tracks: tracks, layer: $layer, proxy: proxy, onSelectActivity: { id in
                        navigation.listSelection = [id]
                    })
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            if !tracks.isEmpty {
                LayerPicker(layer: $layer).padding(8)
            }
        }
    }

    // MARK: Étapes

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Étapes").font(.headline)
            if members.isEmpty {
                Text("Aucune activité dans ce raid.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, activity in
                    Button {
                        navigation.listSelection = [activity.id]
                    } label: {
                        stepRow(index: index + 1, activity: activity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stepRow(index: Int, activity: ActivitySummary) -> some View {
        HStack(spacing: 12) {
            Text("J\(index)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.15), in: Circle())
            Image(systemName: activity.activityType.symbolName)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.body)
                Text(Self.dayFormatter.string(from: activity.startDate))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.formatDistance(activity.distance)).font(.callout.monospacedDigit())
                Text("\(Int(activity.elevationGain.rounded())) m D+")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Informations / notes

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                if isDirty {
                    Button("Enregistrer") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            TextEditor(text: Binding(
                get: { draft.notes ?? "" },
                set: { draft.notes = $0.isEmpty ? nil : $0 }
            ))
            .frame(minHeight: 90)
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .font(.body)
        }
    }

    // MARK: Actions

    private func save() {
        guard isDirty else { return }
        let snapshot = draft
        Task { await listVM.saveRaid(snapshot) }
    }

    private func loadMap() async {
        isLoadingMap = true
        var loaded: [TrackOverlayInput] = []
        for activity in members {
            if let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
               let overlay = try? TrackOverlayInput.fromTrackData(data, activityId: activity.id, activityType: activity.activityType),
               !overlay.coordinates.isEmpty {
                loaded.append(overlay)
            }
        }
        tracks = loaded
        isLoadingMap = false
    }

    // MARK: Formatage

    private var dateRangeText: String? {
        guard let start = raid.startDate else { return nil }
        let end = raid.endDate ?? start
        let cal = Calendar.current
        if cal.isDate(start, inSameDayAs: end) {
            return Self.dayFormatter.string(from: start)
        }
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0) + 1
        return "\(Self.dayFormatter.string(from: start)) → \(Self.dayFormatter.string(from: end)) · \(days) jours"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private static func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m))" }
        return "\(m) min"
    }
}
