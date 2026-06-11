import SwiftUI
import AppKit
import MapKit
import GPXCore
import GPXMapKit

/// Élément de menu avec une coche si sélectionné, sans symbole vide sinon (évite « No symbol named '' »).
struct CheckmarkLabel: View {
    let title: String
    let selected: Bool
    init(_ title: String, selected: Bool) { self.title = title; self.selected = selected }
    var body: some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

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
                            CheckmarkLabel(l.displayName, selected: l == layer)
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

/// Contrôle de la surcouche « pentes » IGN (bouton + popover : interrupteur, opacité, légende).
/// À n'afficher que lorsqu'un fond IGN est sélectionné. Désactivée par défaut.
struct SlopeOverlayControl: View {
    @Binding var enabled: Bool
    @Binding var opacity: Double
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Label("Pentes", systemImage: "triangle.fill")
                .foregroundStyle(enabled ? .orange : .secondary)
        }
        .help("Superposer la carte des pentes IGN")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Afficher les pentes", isOn: $enabled)
                    .toggleStyle(.switch)
                    .font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: "triangle").foregroundStyle(.secondary)
                    Slider(value: $opacity, in: 0.1...1)
                    Text("\(Int((opacity * 100).rounded())) %")
                        .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
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

/// Choix du mode de coloration de la trace (uniforme / vitesse / pente).
struct TrackColorControl: View {
    @Binding var mode: TrackColorMode

    var body: some View {
        Menu {
            ForEach(TrackColorMode.allCases) { m in
                Button { mode = m } label: { CheckmarkLabel(m.label, selected: m == mode) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintpalette")
                Text("Trace : \(mode.label)")
            }
        }
        .menuStyle(.borderedButton)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Groupe de contrôles carte (même ordre/style partout) : Fond · Trace · Pentes, + boutons d'action optionnels.
/// Horizontal par défaut (au-dessus/à côté de la carte), vertical en plein écran (centré sur le bord gauche).
struct MapControlCluster<Trailing: View>: View {
    @Binding var layer: MapLayer
    @Binding var trackColorMode: TrackColorMode
    @Binding var slopeEnabled: Bool
    @Binding var slopeOpacity: Double
    var axis: Axis
    @ViewBuilder var trailing: () -> Trailing

    init(layer: Binding<MapLayer>, trackColorMode: Binding<TrackColorMode>, slopeEnabled: Binding<Bool>, slopeOpacity: Binding<Double>, axis: Axis = .horizontal, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        _layer = layer
        _trackColorMode = trackColorMode
        _slopeEnabled = slopeEnabled
        _slopeOpacity = slopeOpacity
        self.axis = axis
        self.trailing = trailing
    }

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            LayerPicker(layer: $layer)
            TrackColorControl(mode: $trackColorMode)
            if layer.isIGN {
                SlopeOverlayControl(enabled: $slopeEnabled, opacity: $slopeOpacity)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            trailing()
        }
    }
}

/// Bouton d'entrée en plein écran carte, réutilisé sur toutes les cartes (la sortie est un item de toolbar).
struct MapFullscreenButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .padding(7).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Carte en plein écran")
    }
}

struct MapOverviewView: View {
    let activities: [ActivitySummary]
    let selectedIds: Set<UUID>
    let repository: CoreDataActivityRepository
    @Bindable var window: WindowModel
    let onSelect: (UUID) -> Void
    /// Force le rendu plein écran (utilisé quand la vue sert d'overlay carte d'un raid).
    var forceFullscreen: Bool = false

    @AppStorage("defaultMapLayer") private var defaultLayerRaw: String = MapLayer.ignScan25.rawValue
    @AppStorage("slopeOverlayEnabled") private var slopeOverlayEnabled: Bool = false
    @AppStorage("slopeOverlayOpacity") private var slopeOverlayOpacity: Double = 0.6
    @AppStorage("trackColorMode") private var trackColorModeRaw: String = TrackColorMode.uniform.rawValue
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

    private var isFullscreen: Bool { window.mapFullscreen || forceFullscreen }

    private var trackColorBinding: Binding<TrackColorMode> {
        Binding(get: { trackColorMode }, set: { trackColorModeRaw = $0.rawValue })
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
                    TrackMapView(tracks: tracks, layer: $layer, proxy: proxy, slopeOverlayOpacity: slopeOverlayEnabled ? slopeOverlayOpacity : 0, onSelectActivity: onSelect)
                }
            }

            if !tracks.isEmpty && !isFullscreen {
                inlineControls.padding(8)
            }
        }
        .overlay(alignment: .top) { if isFullscreen { fsTopScrim } }
        .overlay(alignment: .bottom) { if isFullscreen && !tracks.isEmpty { fsControls } }
        // ignore tout le safe area en plein écran (carte sous la barre transparente), sinon respecte-le —
        // sans changer l'identité de la carte (pas de rechargement des traces au basculement).
        .ignoresSafeArea(.container, edges: isFullscreen ? .all : [])
        .navigationTitle(isFullscreen ? "" : "Carte d'ensemble")
        .task(id: visibleActivitiesIDsKey) { await loadAll() }
        .onAppear { layer = MapLayer.base(fromRawValue: defaultLayerRaw) }
        .onChange(of: layer) { _, newValue in defaultLayerRaw = newValue.rawValue }
        .onChange(of: window.mapExportToken) { _, _ in
            // Pendant le chargement, `tracks` contient encore les traces précédentes (ou rien) :
            // l'export sortirait une carte sans les traces affichées. On refuse explicitement.
            guard !isLoading else {
                exportError = "Les traces sont encore en cours de chargement — réessayez dans un instant."
                return
            }
            guard !tracks.isEmpty else {
                exportError = "Aucune trace chargée à exporter."
                return
            }
            Task { await exportPNG(fullRoute: window.mapExportFullRoute) }
        }
        .alert("Export PNG", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Contrôles en mode fenêtré (coin haut-droit) : compteur + cluster + bouton plein écran.
    private var inlineControls: some View {
        HStack(spacing: 12) {
            Text("\(tracks.count) trace(s)")
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.thinMaterial, in: Capsule())
            MapControlCluster(layer: $layer, trackColorMode: trackColorBinding, slopeEnabled: $slopeOverlayEnabled, slopeOpacity: $slopeOverlayOpacity) {
                MapFullscreenButton { window.mapFullscreen = true }
            }
        }
    }

    /// Contrôles plein écran, en barre horizontale centrée en bas.
    private var fsControls: some View {
        MapControlCluster(layer: $layer, trackColorMode: trackColorBinding, slopeEnabled: $slopeOverlayEnabled, slopeOpacity: $slopeOverlayOpacity, axis: .horizontal)
            .padding(.bottom, 12)
    }

    private var fsTopScrim: some View {
        LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 96)
            .allowsHitTesting(false)
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
        visibleActivities.map(\.id.uuidString).sorted().joined(separator: ",") + "|" + trackColorModeRaw
    }

    private var trackColorMode: TrackColorMode { TrackColorMode(rawValue: trackColorModeRaw) ?? .uniform }

    private func loadAll() async {
        isLoading = true
        loadedCount = 0
        let snapshot = visibleActivities
        totalCount = snapshot.count
        var loaded: [TrackOverlayInput] = []
        for activity in snapshot {
            do {
                if let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty {
                    let overlay = try TrackOverlayInput.fromTrackData(data, activityId: activity.id, activityType: activity.activityType, colorMode: trackColorMode)
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
