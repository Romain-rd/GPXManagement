import SwiftUI
import GPXCore
import GPXMapKit

struct ActivityMapTabView: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository

    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignPlanV2.rawValue
    @State private var layer: MapLayer = .ignPlanV2
    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isLoading {
                    ProgressView("Chargement de la carte…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Carte indisponible", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if tracks.isEmpty {
                    ContentUnavailableView("Aucune trace GPS", systemImage: "map", description: Text("Cette activité ne contient pas de coordonnées."))
                } else {
                    TrackMapView(tracks: tracks, layer: $layer)
                }
            }

            if !tracks.isEmpty && !isLoading && error == nil {
                LayerPicker(layer: $layer)
                    .padding(8)
            }
        }
        .task(id: activity.id) { await load() }
        .onAppear {
            layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignPlanV2
        }
        .onChange(of: layer) { _, newValue in
            defaultLayerRaw = newValue.rawValue
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            guard let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty else {
                tracks = []
                isLoading = false
                return
            }
            let overlay = try TrackOverlayInput.fromTrackData(data, activityId: activity.id, activityType: activity.activityType)
            tracks = [overlay]
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct LayerPicker: View {
    @Binding var layer: MapLayer

    var body: some View {
        Menu {
            ForEach(MapLayer.allCases) { l in
                Button {
                    layer = l
                } label: {
                    Label(l.displayName, systemImage: l == layer ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(layer.displayName)
            }
        }
        .menuStyle(.borderedButton)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
