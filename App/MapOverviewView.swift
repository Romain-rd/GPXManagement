import SwiftUI
import AppKit
import MapKit
import GPXCore
import GPXMapKit

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
    @State private var proxy = MapViewProxy()
    @State private var isExporting = false
    @State private var exportError: String?

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
                    TrackMapView(tracks: tracks, layer: $layer, proxy: proxy, onSelectActivity: onSelect)
                }
            }

            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Text("\(tracks.count) trace(s)")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.thinMaterial, in: Capsule())
                    Button {
                        Task { await exportPNG() }
                    } label: {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Exporter en PNG", systemImage: "photo.badge.arrow.down")
                        }
                    }
                    .disabled(isExporting)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    LayerPicker(layer: $layer)
                }
                .padding(8)
            }
        }
        .navigationTitle("Carte d'ensemble")
        .task(id: visibleActivitiesIDsKey) { await loadAll() }
        .onAppear { layer = MapLayer(rawValue: defaultLayerRaw) ?? .ignScan25 }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
        .alert("Export PNG", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportPNG() async {
        guard let mapRect = proxy.visibleMapRect else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await MapImageExporter.renderPNG(layer: layer, mapRect: mapRect, tracks: tracks)
            let panel = NSSavePanel()
            panel.title = "Exporter la carte en PNG"
            panel.nameFieldStringValue = "carte-\(Int(Date().timeIntervalSince1970)).png"
            panel.allowedContentTypes = [.png]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
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
