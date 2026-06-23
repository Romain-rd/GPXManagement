import SwiftUI
import AppKit
import Charts
import MapKit
import Photos
import QuickLook
import AVFoundation
import UniformTypeIdentifiers
import GPXCore
import GPXRender
import GPXVideo
import GPXMapKit

/// Panneau d'inspecteur glissant depuis la droite, redimensionnable par sa poignée gauche.
/// Partagé par les détails parcours (fiche d'étape) et raid (activité membre) — présentation homogène.
private struct SlideOverInspector<Inspector: View>: ViewModifier {
    @Binding var width: Double
    let isPresented: Bool
    let onClose: (() -> Void)?
    @ViewBuilder let inspector: () -> Inspector
    @State private var accum: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if isPresented {
                    HStack(spacing: 0) {
                        Rectangle().fill(.clear).frame(width: 7).contentShape(Rectangle())
                            .overlay(Divider(), alignment: .leading)
                            .onHover { inside in NSCursor.resizeLeftRight.set(); if !inside { NSCursor.arrow.set() } }
                            .gesture(
                                DragGesture()
                                    .onChanged { v in
                                        width = Swift.min(680, Swift.max(280, width - Double(v.translation.width - accum)))
                                        accum = v.translation.width
                                    }
                                    .onEnded { _ in accum = 0 }
                            )
                        inspector().frame(width: width)
                            .overlay(alignment: .topTrailing) {
                                if let onClose {
                                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .padding(8).help("Fermer la fiche")
                                }
                            }
                    }
                    .background(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: -2)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}

extension View {
    func slideOverInspector<Inspector: View>(width: Binding<Double>, isPresented: Bool, onClose: (() -> Void)? = nil,
                                             @ViewBuilder inspector: @escaping () -> Inspector) -> some View {
        modifier(SlideOverInspector(width: width, isPresented: isPresented, onClose: onClose, inspector: inspector))
    }
}

enum GeoDistance {
    static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

/// Poignée de redimensionnement vertical, centrée et continue (positif = agrandir l'élément du dessus).
struct DragResizeHandle: View {
    let onDelta: (CGFloat) -> Void
    @State private var accum: CGFloat = 0
    var body: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in onDelta(v.translation.height - accum); accum = v.translation.height }
                    .onEnded { _ in accum = 0 }
            )
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Glisser pour ajuster la hauteur de la carte")
    }
}

/// Carte IGN réelle (même outillage que le détail : sélecteur de fonds) montrant une trace, avec coloration
/// par étape si `stages` est fourni (sinon tracé uniforme). Réutilisée par la fiche d'étape et l'aperçu.
struct StageColoredMap: View {
    let activityId: UUID
    let activityType: ActivityType
    let coords: [CLLocationCoordinate2D]
    var stages: [Stage] = []
    var connectors: [[CLLocationCoordinate2D]] = []
    var highlight: CLLocationCoordinate2D? = nil
    var waypoints: [WaypointMarker] = []
    var onWaypointMoved: ((UUID, CLLocationCoordinate2D) -> Void)? = nil
    var onWaypointTapped: ((UUID) -> Void)? = nil
    var onMapClick: ((CLLocationCoordinate2D) -> Void)? = nil
    var proxy: MapViewProxy? = nil
    var fitTrigger: AnyHashable? = nil
    var showsLayerPicker: Bool = true
    var crosshairSymbol: String? = nil
    @Binding var layer: MapLayer

    private static let connectorIds = [
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    ]
    private var connectorOverlays: [TrackOverlayInput] {
        connectors.enumerated().compactMap { i, c in
            guard c.count >= 2 else { return nil }
            return TrackOverlayInput(activityId: Self.connectorIds[i % Self.connectorIds.count],
                                     activityType: activityType, coordinates: c,
                                     segmentColors: [NSColor](repeating: .systemOrange, count: c.count))
        }
    }

    private var overlay: TrackOverlayInput {
        guard !stages.isEmpty, !coords.isEmpty else {
            return TrackOverlayInput(activityId: activityId, activityType: activityType, coordinates: coords)
        }
        var colors = [NSColor](repeating: .systemGray, count: coords.count)
        for (k, s) in stages.enumerated() {
            let c = MapTrackPalette.colors[k % MapTrackPalette.colors.count]
            let lo = max(0, min(s.startIndex, coords.count - 1))
            let hi = max(lo, min(s.endIndex, coords.count - 1))
            if lo <= hi { for i in lo...hi { colors[i] = c } }
        }
        return TrackOverlayInput(activityId: activityId, activityType: activityType, coordinates: coords, segmentColors: colors)
    }

    var body: some View {
        TrackMapView(tracks: (coords.isEmpty ? [] : [overlay]) + connectorOverlays, layer: $layer, proxy: proxy, highlight: highlight, fitsOnce: true, fitTrigger: fitTrigger,
                     waypoints: waypoints, onWaypointMoved: onWaypointMoved, onWaypointTapped: onWaypointTapped, onMapClick: onMapClick, crosshairSymbol: onMapClick != nil ? (crosshairSymbol ?? "mappin") : nil)
            .overlay(alignment: .topTrailing) {
                if showsLayerPicker { LayerPicker(layer: $layer).padding(8) }
            }
    }
}

/// Carte plein cadre d'un parcours (mode Vue d'ensemble) : tracé du parcours avec ses étapes colorées.
struct StagedRouteOverviewMap: View {
    let activity: ActivitySummary
    let repository: CoreDataActivityRepository
    @State private var coords: [CLLocationCoordinate2D] = []
    @State private var stages: [Stage] = []
    @State private var isLoading = true
    @AppStorage("mapLayerParcoursMap") private var layerRaw = MapLayer.ignScan25.rawValue

    private var layerBinding: Binding<MapLayer> {
        Binding(get: { MapLayer.base(fromRawValue: layerRaw) }, set: { layerRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StageColoredMap(activityId: activity.id, activityType: activity.activityType, coords: coords, stages: stages, layer: layerBinding)
            }
        }
        .task(id: activity.id) { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        var pts: [TrackPoint] = []
        if let data = try? await repository.fetchTrackData(id: activity.id), let p = try? TrackPointCodec.decode(data) {
            pts = p
            coords = p.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        stages = ((try? await repository.fetchStagesResolved(activityId: activity.id, points: pts)) ?? []).sorted { $0.order < $1.order }
    }
}
