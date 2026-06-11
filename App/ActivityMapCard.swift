import SwiftUI
import AVKit
import MapKit
import Photos
import GPXCore
import GPXMapKit
import GPXRender
import GPXVideo

struct ProfileResizeHandle: View {
    let onCommit: (CGFloat) -> Void // variation en points (positif = agrandir)
    @State private var drag: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(0.7))
            .frame(width: 46, height: 5)
            .padding(.vertical, 5)
            .offset(y: drag) // retour visuel pendant le drag
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in drag = v.translation.height }
                    .onEnded { v in onCommit(-v.translation.height); drag = 0 }
            )
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Glisser pour ajuster la hauteur du profil")
    }
}

struct ActivityMapCard: View {
    let activityId: UUID
    let activityType: ActivityType
    let repository: CoreDataActivityRepository
    @Binding var layer: MapLayer
    let highlight: CLLocationCoordinate2D?
    var highlightRange: [CLLocationCoordinate2D] = []
    let photos: [PhotoMapItem]
    var slopeOverlayOpacity: Double = 0
    var trackColorMode: TrackColorMode = .uniform
    var onFullscreen: (() -> Void)? = nil
    let onSelectPhoto: (String) -> Void

    @State private var tracks: [TrackOverlayInput] = []
    @State private var isLoaded = false

    var body: some View {
        Group {
            if !isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("Pas de tracé", systemImage: "map", description: Text("La trace ne contient pas de coordonnées."))
            } else {
                TrackMapView(tracks: tracks, layer: $layer, highlight: highlight, highlightRange: highlightRange, photos: photos, slopeOverlayOpacity: slopeOverlayOpacity, onSelectPhoto: onSelectPhoto)
                    .overlay(alignment: .bottomLeading) {
                        if let credit = layer.attribution {
                            Text(credit)
                                .font(.system(size: 9))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if slopeOverlayOpacity > 0 { slopeLegend.padding(6) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if trackColorMode != .uniform { trackColorLegend.padding(6) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let onFullscreen {
                            Button(action: onFullscreen) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .padding(7)
                                    .background(.black.opacity(0.5), in: Circle())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .help("Carte en plein écran")
                        }
                    }
            }
        }
        .task(id: "\(activityId.uuidString)|\(trackColorMode.rawValue)") { await load() }
    }

    /// Légende du code couleur de la trace (vitesse ou pente).
    @ViewBuilder
    private var trackColorLegend: some View {
        let items: [(String, Color)] = {
            switch trackColorMode {
            case .uniform: return []
            case .slope:
                let s = SlopeScale.percent
                return s.categories.map { (s.label(for: $0), Color(red: $0.rgb.r, green: $0.rgb.g, blue: $0.rgb.b)) }
            case .speed:
                let s = activityType.speedScale
                return s.categories.map { (s.label(for: $0), Color(red: $0.rgb.r, green: $0.rgb.g, blue: $0.rgb.b)) }
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(trackColorMode == .speed ? "Vitesse" : "Pente").font(.system(size: 9, weight: .semibold))
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                    Text(item.0).font(.system(size: 9))
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    /// Légende de la pente du terrain IGN (visible quand la trace neige est colorée sur fond IGN).
    private var slopeLegend: some View {
        let bands: [SlopeBand] = [.d30_35, .d35_40, .d40_45, .above45]
        return VStack(alignment: .leading, spacing: 2) {
            Text("Pente du terrain").font(.system(size: 9, weight: .semibold))
            ForEach(bands, id: \.label) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(band.color.map { Color(nsColor: $0) } ?? .clear)
                        .frame(width: 10, height: 10)
                    Text(band.label).font(.system(size: 9))
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    private func load() async {
        isLoaded = false
        guard let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
              let input = try? TrackOverlayInput.fromTrackData(data, activityId: activityId, activityType: activityType, colorMode: trackColorMode),
              !input.coordinates.isEmpty else {
            tracks = []
            isLoaded = true
            return
        }
        tracks = [input]
        isLoaded = true
    }
}



