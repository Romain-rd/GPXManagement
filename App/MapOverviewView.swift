import SwiftUI
import AppKit
import MapKit
import GPXCore
import GPXMapKit

struct LayerPicker: View {
    @Binding var layer: MapLayer

    var body: some View {
        Menu {
            ForEach(MapLayer.countryOrder, id: \.self) { country in
                Section(country) {
                    ForEach(MapLayer.allCases.filter { $0.country == country && !$0.isOverlayOnly }) { l in
                        Button {
                            layer = l
                        } label: {
                            Label(l.displayName, systemImage: l == layer ? "checkmark" : "")
                        }
                    }
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

/// Contrôle d'opacité de la surcouche « pentes » IGN (bouton + popover slider + légende).
/// À n'afficher que lorsqu'un fond IGN est sélectionné.
struct SlopeOverlayControl: View {
    @Binding var opacity: Double
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Label("Pentes", systemImage: "triangle.fill")
                .foregroundStyle(opacity > 0 ? .orange : .secondary)
        }
        .help("Superposer la carte des pentes IGN")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Carte des pentes IGN").font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: "triangle").foregroundStyle(.secondary)
                    Slider(value: $opacity, in: 0...1)
                    Text("\(Int((opacity * 100).rounded())) %")
                        .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
                }
                Divider()
                ForEach([SlopeBand.d30_35, .d35_40, .d40_45, .above45], id: \.label) { band in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(band.color.map { Color(nsColor: $0) } ?? .clear)
                            .frame(width: 12, height: 12)
                        Text(band.label).font(.caption)
                    }
                }
            }
            .padding(12)
            .frame(width: 230)
        }
    }
}

struct MapOverviewView: View {
    let activities: [ActivitySummary]
    let selectedIds: Set<UUID>
    let repository: CoreDataActivityRepository
    @Bindable var window: WindowModel
    let onSelect: (UUID) -> Void

    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignScan25.rawValue
    @AppStorage("slopeOverlayOpacity") private var slopeOverlayOpacity: Double = 0
    @State private var layer: MapLayer = .ignScan25
    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoading = true
    @State private var loadedCount = 0
    @State private var totalCount = 0
    @State private var proxy = MapViewProxy()
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
                    TrackMapView(tracks: tracks, layer: $layer, proxy: proxy, slopeOverlayOpacity: slopeOverlayOpacity, onSelectActivity: onSelect)
                }
            }

            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Text("\(tracks.count) trace(s)")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.thinMaterial, in: Capsule())
                    if layer.isIGN {
                        SlopeOverlayControl(opacity: $slopeOverlayOpacity)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    LayerPicker(layer: $layer)
                }
                .padding(8)
            }
        }
        .navigationTitle("Carte d'ensemble")
        .task(id: visibleActivitiesIDsKey) { await loadAll() }
        .onAppear { layer = MapLayer.base(fromRawValue: defaultLayerRaw) }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
        .onChange(of: window.mapExportToken) { _, _ in
            guard !tracks.isEmpty else { return }
            Task { await exportPNG(fullRoute: window.mapExportFullRoute) }
        }
        .alert("Export PNG", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportPNG(fullRoute: Bool) async {
        let mapRect: MKMapRect?
        if fullRoute {
            mapRect = tracksBoundingRect()
        } else {
            mapRect = proxy.visibleMapRect
        }
        guard let mapRect else { return }
        window.isExportingMap = true
        window.mapExportFraction = 0
        window.mapExportStatus = "Préparation de l'export…"
        defer {
            window.isExportingMap = false
            window.mapExportStatus = ""
        }
        do {
            let data = try await MapImageExporter.renderPNG(layer: layer, mapRect: mapRect, tracks: tracks) { progress in
                Task { @MainActor in
                    window.mapExportFraction = progress.fraction
                    window.mapExportStatus = progress.label
                }
            }
            window.mapExportFraction = 1
            window.mapExportStatus = "Enregistrement…"
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

    private func tracksBoundingRect() -> MKMapRect? {
        var rect = MKMapRect.null
        for track in tracks {
            for coord in track.coordinates {
                let point = MKMapPoint(coord)
                rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
            }
        }
        guard !rect.isNull, rect.size.width > 0 || rect.size.height > 0 else { return nil }
        return rect.insetBy(dx: -rect.size.width * 0.06 - 1, dy: -rect.size.height * 0.06 - 1)
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
