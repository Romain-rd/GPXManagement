import SwiftUI
import GPXCore
import GPXMapKit

struct MapOverviewView: View {
    let activities: [ActivitySummary]
    let selectedIds: Set<UUID>
    let repository: CoreDataActivityRepository
    let onSelect: (UUID) -> Void

    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignScan25.rawValue
    @State private var layer: MapLayer = .ignScan25
    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoading = true
    @State private var loadedCount = 0
    @State private var totalCount = 0

    private var visibleActivities: [ActivitySummary] {
        if selectedIds.isEmpty { return activities }
        return activities.filter { selectedIds.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("\(loadedCount) / \(totalCount) traces chargées")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tracks.isEmpty {
                    ContentUnavailableView("Aucune trace à afficher", systemImage: "map", description: Text(visibleActivities.isEmpty ? "Choisissez une ou plusieurs activités." : "Aucune trace GPS dans la sélection."))
                } else {
                    TrackMapView(tracks: tracks, layer: $layer, onSelectActivity: onSelect)
                }
            }

            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Text("\(tracks.count) trace(s)")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.thinMaterial, in: Capsule())
                    LayerPicker(layer: $layer)
                }
                .padding(8)
            }
        }
        .navigationTitle("Carte d'ensemble")
        .task(id: visibleActivitiesIDsKey) { await loadAll() }
        .onAppear { layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25 }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
    }

    private var visibleActivitiesIDsKey: String {
        visibleActivities.map(\.id.uuidString).sorted().joined(separator: ",")
    }

    private func loadAll() async {
        isLoading = true
        loadedCount = 0
        let snapshot = visibleActivities
        totalCount = snapshot.count
        var loaded: [TrackOverlayInput] = []
        for activity in snapshot {
            do {
                if let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty {
                    let overlay = try TrackOverlayInput.fromTrackData(data, activityId: activity.id, activityType: activity.activityType)
                    if !overlay.coordinates.isEmpty {
                        loaded.append(overlay)
                    }
                }
            } catch {
                NSLog("MapOverview: failed to load track for \(activity.id): \(error)")
            }
            loadedCount += 1
        }
        tracks = loaded
        isLoading = false
    }
}
