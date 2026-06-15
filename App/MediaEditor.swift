import SwiftUI
import AVKit
import MapKit
import Photos
import Charts
import GPXCore
import GPXMapKit
import GPXRender
import GPXVideo

// MARK: - Édition de média (recadrage)

enum CropRatio: String, CaseIterable, Identifiable {
    case r16x9, r1x1, r9x16, original, free
    var id: String { rawValue }
    var label: String {
        switch self {
        case .r16x9: return "16:9"
        case .r1x1: return "1:1"
        case .r9x16: return "9:16"
        case .original: return "Original"
        case .free: return "Libre"
        }
    }
    /// Aspect cible en pixels (largeur/hauteur). nil = libre.
    func pixelAspect(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .r16x9: return 16.0 / 9.0
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16.0
        case .original: return imageAspect
        case .free: return nil
        }
    }
}

struct EditingMedia: Identifiable {
    let id: String
    let asset: PHAsset
}

// MARK: - Réglage de la position d'un média sur la trace

struct PositioningMedia: Identifiable {
    let id: String
    let asset: PHAsset
    let manualMeters: Double?
}

/// Éditeur « Position sur le parcours » : carte (marqueur) + profil (scrubber) synchronisés.
/// Le glisser pose une position manuelle (posMeters) ; « Réinitialiser » revient à l'auto (heure→GPS).
struct MediaPositionEditor: View {
    let asset: PHAsset
    let activityId: UUID
    let activityType: ActivityType
    let repository: CoreDataActivityRepository
    let initialManualMeters: Double?
    let onSave: (Double?) -> Void
    let onCancel: () -> Void

    @AppStorage("defaultMapLayer") private var defaultMapLayerRaw = MapLayer.ignScan25.rawValue

    @State private var points: [TrackPoint] = []
    @State private var profile: [ElevationProfilePoint] = []
    @State private var resolver: MediaTrackResolver?
    @State private var meters: Double = 0
    @State private var manual: Bool = false
    @State private var thumbnail: NSImage?
    @State private var layer: MapLayer = .ignScan25
    @State private var loaded = false

    private var total: Double { resolver?.totalDistance ?? 0 }
    private var gps: CLLocationCoordinate2D? { asset.location?.coordinate }
    private var timeMeters: Double? {
        guard let date = asset.creationDate else { return nil }
        return resolver?.distance(manualMeters: nil, captureDate: date, gpsLatitude: nil, gpsLongitude: nil)
    }
    private var gpsMeters: Double? {
        guard let c = gps else { return nil }
        return resolver?.distance(manualMeters: nil, captureDate: nil, gpsLatitude: c.latitude, gpsLongitude: c.longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if loaded, let resolver, !resolver.isEmpty {
                map(resolver)
                profileChart
                readout
                sourceButtons
            } else if loaded {
                ContentUnavailableView("Tracé indisponible", systemImage: "map", description: Text("Impossible de charger le parcours de cette activité."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 320)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("Position sur le parcours").font(.headline)
                if let date = asset.creationDate {
                    Text("Pris à \(Self.timeFormatter.string(from: date))").font(.caption).foregroundStyle(.secondary)
                }
                if let c = gps, let off = resolver?.distanceFromTrack(latitude: c.latitude, longitude: c.longitude), off > 80 {
                    Label("GPS à \(Int(off)) m de la trace", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    private func map(_ resolver: MediaTrackResolver) -> some View {
        let coord = resolver.coordinate(atMeters: meters)
        let c = CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
        return TrackMapView(
            tracks: [TrackOverlayInput(activityId: activityId, activityType: activityType,
                                       coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })],
            layer: $layer,
            highlight: c,
            photos: [PhotoMapItem(id: asset.localIdentifier, coordinate: c, image: thumbnail, isVideo: asset.mediaType == .video)]
        )
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var profileChart: some View {
        Chart {
            ForEach(Array(profile.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("km", p.distanceFromStart / 1000), y: .value("alt", p.altitude))
                    .foregroundStyle(.tint.opacity(0.15))
                LineMark(x: .value("km", p.distanceFromStart / 1000), y: .value("alt", p.altitude))
                    .foregroundStyle(.tint)
            }
            if let t = timeMeters {
                RuleMark(x: .value("heure", t / 1000)).foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            if let g = gpsMeters {
                RuleMark(x: .value("gps", g / 1000)).foregroundStyle(.gray)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            RuleMark(x: .value("position", meters / 1000)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYAxis(.hidden)
        .frame(height: 110)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let plot = proxy.plotFrame else { return }
                        let x = value.location.x - geo[plot].origin.x
                        if let km: Double = proxy.value(atX: x) {
                            meters = min(max(0, km * 1000), total)
                            manual = true
                        }
                    })
            }
        }
    }

    private var readout: some View {
        let sample = sampleAt(meters)
        return HStack(spacing: 16) {
            Label(String(format: "%.1f km", meters / 1000), systemImage: "location")
            if let t = sample.time { Label(Self.timeFormatter.string(from: t), systemImage: "clock") }
            if let a = sample.altitude { Label("\(Int(a.rounded())) m", systemImage: "mountain.2") }
            Spacer()
            if manual { Text("Position manuelle").font(.caption).foregroundStyle(.orange) }
            else { Text("Auto").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout.monospacedDigit())
    }

    private var sourceButtons: some View {
        HStack(spacing: 10) {
            if let t = timeMeters {
                Button("Aligner sur l'heure") { meters = t; manual = true }
            }
            if let g = gpsMeters {
                Button("Aligner sur le GPS") { meters = g; manual = true }
            }
            Button("Réinitialiser (auto)") {
                manual = false
                meters = autoMeters() ?? 0
            }.disabled(!manual)
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Annuler", role: .cancel) { onCancel() }
            Button("Valider") { onSave(manual ? meters : nil) }.keyboardShortcut(.defaultAction)
        }
    }

    private func autoMeters() -> Double? {
        resolver?.distance(manualMeters: nil, captureDate: asset.creationDate,
                           gpsLatitude: gps?.latitude, gpsLongitude: gps?.longitude)
    }

    private func sampleAt(_ m: Double) -> (altitude: Double?, time: Date?) {
        guard !profile.isEmpty else { return (nil, nil) }
        var lo = profile[0]
        for p in profile {
            if p.distanceFromStart >= m {
                let span = p.distanceFromStart - lo.distanceFromStart
                let t = span > 0 ? (m - lo.distanceFromStart) / span : 0
                let alt = lo.altitude + (p.altitude - lo.altitude) * t
                let time: Date? = {
                    guard let t0 = lo.timestamp, let t1 = p.timestamp else { return lo.timestamp ?? p.timestamp }
                    return t0.addingTimeInterval(t1.timeIntervalSince(t0) * t)
                }()
                return (alt, time)
            }
            lo = p
        }
        return (profile.last?.altitude, profile.last?.timestamp)
    }

    private func load() async {
        layer = MapLayer(rawValue: defaultMapLayerRaw) ?? .ignScan25
        thumbnail = await PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: 160, height: 160))
        if let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
           let decoded = try? TrackPointCodec.decode(data) {
            points = decoded
            let r = MediaTrackResolver(points: decoded)
            resolver = r
            profile = ElevationProfileBuilder.decimate(ElevationProfileBuilder.build(points: decoded), maxPoints: 600)
            if let m = initialManualMeters { meters = m; manual = true }
            else { meters = r.distance(manualMeters: nil, captureDate: asset.creationDate, gpsLatitude: gps?.latitude, gpsLongitude: gps?.longitude) ?? 0 }
        }
        loaded = true
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "HH:mm"; return f
    }()
}

/// Recadrage d'une photo selon un ratio, puis enregistrement d'une nouvelle photo dans la photothèque.
struct PhotoCropEditor: View {
    let asset: PHAsset
    let onCancel: () -> Void
    let onSave: (Data) -> Void

    @State private var image: NSImage?
    @State private var ratio: CropRatio = .original
    @State private var crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.5) // normalisé, origine haut-gauche

    private var imageAspect: CGFloat {
        guard let s = image?.size, s.height > 0 else { return 1 }
        return s.width / s.height
    }
    /// Aspect normalisé (nw/nh) correspondant au ratio pixel cible.
    private var normalizedAspect: CGFloat? {
        guard let r = ratio.pixelAspect(imageAspect: imageAspect) else { return nil }
        return r / imageAspect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recadrer la photo").font(.title3.bold())
            Picker("Format", selection: $ratio) {
                ForEach(CropRatio.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: ratio) { _, _ in resetCrop() }

            GeometryReader { geo in
                if let image {
                    let iv = Self.fit(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable()
                            .frame(width: iv.width, height: iv.height)
                            .position(x: iv.midX, y: iv.midY)
                        CropDim(crop: crop, imageRect: iv)
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        CropRectView(crop: $crop, imageRect: iv, normalizedAspect: normalizedAspect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .coordinateSpace(name: "crop")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 380)

            HStack {
                Spacer()
                Button("Annuler") { onCancel() }
                Button("Enregistrer") { if let data = makeJPEG() { onSave(data) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task {
            image = await PhotoLibraryService.editingImage(for: asset)
            resetCrop()
        }
    }

    private func resetCrop() {
        let an = normalizedAspect ?? imageAspect / imageAspect // libre → 1 (carré normalisé de base)
        var w: CGFloat = 1, h: CGFloat = 1
        if an >= 1 { w = 1; h = 1 / an } else { h = 1; w = an }
        if ratio == .free { w = 0.9; h = 0.9 }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func makeJPEG() -> Data? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let px = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H).integral
        guard let cropped = cg.cropping(to: px) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    static func fit(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let s = min(container.width / size.width, container.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

@MainActor @Observable private final class VideoPlayerModel {
    let player: AVPlayer
    var time: Double = 0
    var isPlaying = false
    var start = 0.0
    var end = 0.0
    @ObservationIgnored private var token: Any?

    init(asset: AVAsset) {
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.time = t.seconds
            if self.isPlaying, t.seconds >= self.end { self.seek(self.start) }
        }
    }
    func play(from s: Double) { seek(s); player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ s: Double) { player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func stop() { player.pause(); if let token { player.removeTimeObserver(token); self.token = nil } }
}

private struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView { let v = PlayerLayerView(); v.playerLayer.player = player; return v }
    func updateNSView(_ nsView: PlayerLayerView, context: Context) { nsView.playerLayer.player = player }
    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = playerLayer; playerLayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError() }
    }
}

/// Recadrage + extrait (trim) d'une vidéo, avec lecture, puis enregistrement dans la photothèque.
struct VideoEditor: View {
    let asset: PHAsset
    let onCancel: () -> Void
    let onExported: (URL) -> Void

    @State private var avAsset: AVAsset?
    @State private var playback: VideoPlayerModel?
    @State private var displaySize: CGSize = .zero
    @State private var duration: Double = 0
    @State private var startT: Double = 0
    @State private var endT: Double = 0
    @State private var ratio: CropRatio = .original
    @State private var crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.5)
    @State private var isExporting = false
    @State private var thumbnails: [CGImage] = []

    private let filmstripCount = 12
    /// Taille d'affichage du film (lecteur + contrôles partagent cette largeur).
    private var filmSize: CGSize {
        let box = CGSize(width: 620, height: 340)
        let src = (displaySize.width > 0 && displaySize.height > 0) ? displaySize : CGSize(width: 16, height: 9)
        return PhotoCropEditor.fit(src, in: box).size
    }

    private var imageAspect: CGFloat { displaySize.height > 0 ? displaySize.width / displaySize.height : 16.0 / 9.0 }
    private var normalizedAspect: CGFloat? {
        guard let r = ratio.pixelAspect(imageAspect: imageAspect) else { return nil }
        return r / imageAspect
    }
    private var playheadBinding: Binding<Double> {
        Binding(get: { playback?.time ?? 0 }, set: { playback?.seek($0) })
    }

    var body: some View {
        let film = filmSize
        VStack(alignment: .center, spacing: 14) {
            Text("Recadrer / extraire la vidéo").font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Format", selection: $ratio) {
                ForEach(CropRatio.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: ratio) { _, _ in resetCrop() }

            // Le lecteur occupe exactement la taille affichée du film ; les contrôles dessous reprennent
            // cette même largeur → bouton lecture au bord gauche du film, fin des poignées au bord droit.
            ZStack(alignment: .topLeading) {
                if let playback, displaySize != .zero {
                    let iv = CGRect(origin: .zero, size: film)
                    VideoPlayerSurface(player: playback.player)
                        .frame(width: film.width, height: film.height)
                    CropDim(crop: crop, imageRect: iv).fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    CropRectView(crop: $crop, imageRect: iv, normalizedAspect: normalizedAspect)
                } else {
                    ProgressView().frame(width: film.width, height: film.height)
                }
            }
            .frame(width: film.width, height: film.height)
            .coordinateSpace(name: "crop")

            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: (playback?.isPlaying ?? false) ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .disabled(playback == nil)
                TrimBar(duration: duration, start: $startT, end: $endT, playhead: playheadBinding, thumbnails: thumbnails, slotCount: filmstripCount)
                    .frame(height: 50)
            }
            .frame(width: film.width)

            Text("Extrait : \(Self.time(startT)) → \(Self.time(endT))  ·  \(Self.time(endT - startT))")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if isExporting { ProgressView().controlSize(.small); Text("Export…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Annuler") { playback?.stop(); onCancel() }.disabled(isExporting)
                Button("Enregistrer") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(avAsset == nil || isExporting || endT - startT < 0.3)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 660)
        .task {
            let a = await PhotoLibraryService.avAsset(for: asset)
            avAsset = a
            guard let a, let track = try? await a.loadTracks(withMediaType: .video).first else { return }
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let pref = (try? await track.load(.preferredTransform)) ?? .identity
            let oriented = natural.applying(pref)
            displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            duration = (try? await a.load(.duration).seconds) ?? 0
            startT = 0; endT = duration
            let model = VideoPlayerModel(asset: a)
            model.start = 0; model.end = duration
            playback = model
            resetCrop()
            // Analyse de la pellicule en tâche de fond : n'empêche pas l'éditeur de s'afficher,
            // les vignettes apparaissent au fur et à mesure.
            Task { await generateFilmstrip(from: a, duration: duration, count: filmstripCount) }
        }
        .onChange(of: startT) { _, v in playback?.start = v }
        .onChange(of: endT) { _, v in playback?.end = v }
        .onDisappear { playback?.stop() }
    }

    private func togglePlay() {
        guard let p = playback else { return }
        if p.isPlaying { p.pause() }
        else { p.play(from: p.time >= endT - 0.05 ? startT : max(startT, p.time)) }
    }

    private func resetCrop() {
        let an = normalizedAspect ?? 1
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio == .free { w = 0.9; h = 0.9 } else if an >= 1 { w = 1; h = 1 / an } else { h = 1; w = an }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func export() async {
        guard let a = avAsset else { return }
        playback?.pause()
        isExporting = true
        defer { isExporting = false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).mp4")
        if await PhotoLibraryService.exportEditedVideo(asset: a, start: startT, end: endT, crop: crop, to: url) {
            playback?.stop()
            onExported(url)
        }
    }

    /// Pellicule : quelques images réparties sur toute la durée, affichées dans la barre (façon QuickTime/Photos).
    private func generateFilmstrip(from asset: AVAsset, duration: Double, count: Int = 12) async {
        guard duration > 0 else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        thumbnails = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                thumbnails.append(img)
            }
        }
    }

    static func time(_ s: Double) -> String {
        let total = Int(max(0, s).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Sélecteur d'extrait façon Apple (Photos/QuickTime) : cadre jaune autour de la portion conservée,
/// zones à rogner assombries, poignées jaunes aux extrémités. Les glissements sont rapportés à la barre
/// (coordinateSpace nommé) — la version précédente lisait les coordonnées dans la poignée de 10 pt,
/// d'où des poignées qui ne réagissaient pas.
private struct TrimBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double
    var thumbnails: [CGImage] = []
    var slotCount: Int = 12

    private let handleW: CGFloat = 16
    private let minGap = 0.3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pos: (Double) -> CGFloat = { t in duration > 0 ? CGFloat(t / duration) * w : 0 }
            let timeAt: (CGFloat) -> Double = { x in duration > 0 ? Double(min(max(0, x), w) / w) * duration : 0 }
            let sx = pos(start)
            let ex = max(sx, pos(end))

            ZStack(alignment: .leading) {
                // Pellicule (vignettes du film) en fond, comme QuickTime/Photos. Cases de largeur fixe
                // remplies au fur et à mesure de l'analyse — pas de saut de mise en page.
                HStack(spacing: 0) {
                    ForEach(0..<max(1, slotCount), id: \.self) { i in
                        Group {
                            if i < thumbnails.count {
                                Image(decorative: thumbnails[i], scale: 1).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Color.secondary.opacity(0.18))
                            }
                        }
                        .frame(width: w / CGFloat(max(1, slotCount)), height: h)
                        .clipped()
                    }
                }
                // Zones hors sélection = ce qui sera coupé → assombries (convention Apple).
                Rectangle().fill(.black.opacity(0.45)).frame(width: sx)
                Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, w - ex)).offset(x: ex)
                // Cadre jaune autour de la portion conservée.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, ex - sx))
                    .offset(x: sx)
                // Tête de lecture.
                Capsule().fill(.white)
                    .frame(width: 2, height: max(0, h - 8))
                    .offset(x: min(max(0, pos(playhead)), w) - 1)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .allowsHitTesting(false)
                // Poignées jaunes.
                trimHandle(height: h)
                    .offset(x: max(0, min(sx, w - handleW)))
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { v in
                        start = min(max(0, timeAt(v.location.x)), end - minGap)
                        playhead = start
                    })
                trimHandle(height: h)
                    .offset(x: max(0, min(ex - handleW, w - handleW)))
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { v in
                        end = max(min(duration, timeAt(v.location.x)), start + minGap)
                        playhead = end
                    })
            }
            .coordinateSpace(name: "trim")
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { v in
                playhead = timeAt(v.location.x)
            })
        }
    }

    private func trimHandle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.yellow)
            .frame(width: handleW, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.black.opacity(0.35))
                    .frame(width: 2.5, height: min(16, height * 0.5))
            )
            .contentShape(Rectangle())
    }
}

private struct CropDim: Shape {
    let crop: CGRect
    let imageRect: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path(imageRect)
        p.addRect(CGRect(x: imageRect.minX + crop.minX * imageRect.width,
                         y: imageRect.minY + crop.minY * imageRect.height,
                         width: crop.width * imageRect.width,
                         height: crop.height * imageRect.height))
        return p
    }
}

private struct CropRectView: View {
    @Binding var crop: CGRect
    let imageRect: CGRect
    let normalizedAspect: CGFloat?
    @State private var dragStart: CGRect?

    private func viewRect() -> CGRect {
        CGRect(x: imageRect.minX + crop.minX * imageRect.width,
               y: imageRect.minY + crop.minY * imageRect.height,
               width: crop.width * imageRect.width, height: crop.height * imageRect.height)
    }

    var body: some View {
        let r = viewRect()
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .overlay(Rectangle().strokeBorder(.white, lineWidth: 2))
                .position(x: r.midX, y: r.midY)
                .gesture(moveGesture)
            handle(at: CGPoint(x: r.minX, y: r.minY), corner: .topLeft)
            handle(at: CGPoint(x: r.maxX, y: r.maxY), corner: .bottomRight)
        }
    }

    private enum Corner { case topLeft, bottomRight }

    private func handle(at p: CGPoint, corner: Corner) -> some View {
        Circle().fill(.white).frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.gray, lineWidth: 1))
            .position(x: p.x, y: p.y)
            .highPriorityGesture(
                DragGesture(coordinateSpace: .named("crop"))
                    .onChanged { v in resize(corner: corner, to: v.location) }
            )
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("crop"))
            .onChanged { v in
                let s = dragStart ?? crop; if dragStart == nil { dragStart = s }
                let dx = Double(v.translation.width) / Double(imageRect.width)
                let dy = Double(v.translation.height) / Double(imageRect.height)
                crop.origin = CGPoint(x: min(max(0, s.minX + dx), 1 - crop.width),
                                      y: min(max(0, s.minY + dy), 1 - crop.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resize(corner: Corner, to location: CGPoint) {
        let nx = Double((location.x - imageRect.minX) / imageRect.width)
        let ny = Double((location.y - imageRect.minY) / imageRect.height)
        let cx = min(max(0, nx), 1), cy = min(max(0, ny), 1)
        switch corner {
        case .bottomRight:
            let anchorX = crop.minX, anchorY = crop.minY
            var w = max(0.05, cx - anchorX), h = max(0.05, cy - anchorY)
            if let an = normalizedAspect {
                h = w / an
                if anchorY + h > 1 { h = 1 - anchorY; w = h * an }
                if anchorX + w > 1 { w = 1 - anchorX; h = w / an }
            } else {
                w = min(w, 1 - anchorX); h = min(h, 1 - anchorY)
            }
            crop = CGRect(x: anchorX, y: anchorY, width: w, height: h)
        case .topLeft:
            let anchorX = crop.maxX, anchorY = crop.maxY
            var w = max(0.05, anchorX - cx), h = max(0.05, anchorY - cy)
            if let an = normalizedAspect {
                h = w / an
                if anchorY - h < 0 { h = anchorY; w = h * an }
                if anchorX - w < 0 { w = anchorX; h = w / an }
            } else {
                w = min(w, anchorX); h = min(h, anchorY)
            }
            crop = CGRect(x: anchorX - w, y: anchorY - h, width: w, height: h)
        }
    }
}

