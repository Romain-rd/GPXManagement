import SwiftUI
import AVKit
import MapKit
import Photos
import GPXCore
import GPXMapKit
import GPXRender
import GPXVideo

struct ActivityPhotosSection: View {
    let activityId: UUID
    let repository: CoreDataActivityRepository
    let start: Date
    let end: Date
    @Binding var assets: [PHAsset]
    @Binding var showOnMap: Bool
    let reloadToken: Int
    let isShownOnMap: (String) -> Bool
    let isAppCreated: (String) -> Bool
    var isIncoherent: (String) -> Bool = { _ in false }
    let onToggleMap: (String) -> Void
    let onSelect: (PHAsset) -> Void
    let onEdit: (PHAsset) -> Void
    let onAdjustPosition: (PHAsset) -> Void
    let onDelete: (PHAsset) -> Void

    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var isLoading = true
    @AppStorage("detailSectionPhotos") private var expanded = true

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Label("Photos & vidéos", systemImage: "photo.on.rectangle.angled").font(.headline)
                if !assets.isEmpty { Text("(\(assets.count))").foregroundStyle(.secondary) }
                Spacer()
                if !assets.isEmpty && expanded {
                    Toggle("Sur la carte", isOn: $showOnMap)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                }
            }
            if expanded { content }
        }
        .task(id: activityId) { await load() }
        .onChange(of: reloadToken) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .center)
        } else if status == .denied || status == .restricted {
            HStack(spacing: 8) {
                Text("Accès à la photothèque refusé.").font(.callout).foregroundStyle(.secondary)
                Button("Ouvrir les réglages…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if assets.isEmpty {
            Text("Aucune photo trouvée à proximité du parcours pendant cette activité.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    PhotoThumbnail(
                        asset: asset,
                        shownOnMap: isShownOnMap(asset.localIdentifier),
                        mapToggleEnabled: showOnMap,
                        isAppCreated: isAppCreated(asset.localIdentifier),
                        isIncoherent: isIncoherent(asset.localIdentifier),
                        onToggleMap: { onToggleMap(asset.localIdentifier) },
                        onSelect: { onSelect(asset) },
                        onEdit: { onEdit(asset) },
                        onAdjustPosition: { onAdjustPosition(asset) },
                        onDelete: { onDelete(asset) }
                    )
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        status = await PhotoLibraryService.requestAccess()
        guard status == .authorized || status == .limited else { assets = []; return }

        var coordinates: [CLLocationCoordinate2D] = []
        if let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
           let points = try? TrackPointCodec.decode(data) {
            coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        // Marge temporelle ±30 min (photos prises juste avant/après) ; la proximité géographique cadre le résultat.
        assets = PhotoLibraryService.photos(
            start: start.addingTimeInterval(-1800),
            end: end.addingTimeInterval(1800),
            near: coordinates,
            maxDistance: 300
        )
    }
}

private struct PhotoThumbnail: View {
    let asset: PHAsset
    let shownOnMap: Bool
    let mapToggleEnabled: Bool
    let isAppCreated: Bool
    let isIncoherent: Bool
    let onToggleMap: () -> Void
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onAdjustPosition: () -> Void
    let onDelete: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var isFavorite = false

    private var canEdit: Bool { asset.mediaType == .image || asset.mediaType == .video }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { onSelect() }
            .help(asset.mediaType == .video ? "Lire la vidéo" : "Ouvrir la photo")
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text(Self.durationText(asset.duration)).font(.system(size: 9).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(3)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // Trois boutons alignés, toujours visibles : afficher sur la carte · ajuster la position · modifier.
            HStack(spacing: 3) {
                Button(action: onToggleMap) {
                    badgeIcon(shownOnMap ? "mappin.circle.fill" : "mappin.slash.circle.fill",
                              tint: shownOnMap ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .opacity(mapToggleEnabled ? 1 : 0.45)
                .help(shownOnMap ? "Masquer sur la carte" : "Afficher sur la carte")

                Button(action: onAdjustPosition) {
                    badgeIcon(isIncoherent ? "exclamationmark.triangle.fill" : "location.viewfinder",
                              tint: isIncoherent ? Color.orange : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(isIncoherent ? "Heure et GPS en désaccord — ajuster la position sur le parcours"
                                   : "Ajuster la position sur le parcours")

                if canEdit {
                    Button(action: onEdit) { badgeIcon("pencil.circle.fill", tint: Color.accentColor) }
                        .buttonStyle(.plain)
                        .help("Modifier…")
                }
            }
            .padding(3)
        }
        .overlay(alignment: .bottomTrailing) {
            // Favori dans Photos (toujours visible si favori, sinon au survol).
            if isFavorite || hovering {
                Button {
                    let target = !isFavorite
                    Task { if await PhotoLibraryService.setFavorite(asset, target) { isFavorite = target } }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isFavorite ? Color.red : Color.white)
                        .padding(4)
                        .background(Circle().fill(.black.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help(isFavorite ? "Retirer des favoris (Photos)" : "Marquer comme favori (Photos)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if canEdit { Button("Modifier…") { onEdit() } }
            Button("Ajuster la position sur le parcours…") { onAdjustPosition() }
            if isAppCreated { Button("Supprimer", role: .destructive) { onDelete() } }
        }
        .task(id: asset.localIdentifier) {
            isFavorite = asset.isFavorite
            image = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 200, height: 200))
        }
    }

    private func badgeIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, tint)
            .background(Circle().fill(.black.opacity(0.3)))
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

