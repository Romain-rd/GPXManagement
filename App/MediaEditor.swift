import SwiftUI
import AVKit
import MapKit
import Photos
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

    private var imageAspect: CGFloat { displaySize.height > 0 ? displaySize.width / displaySize.height : 16.0 / 9.0 }
    private var normalizedAspect: CGFloat? {
        guard let r = ratio.pixelAspect(imageAspect: imageAspect) else { return nil }
        return r / imageAspect
    }
    private var playheadBinding: Binding<Double> {
        Binding(get: { playback?.time ?? 0 }, set: { playback?.seek($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recadrer / extraire la vidéo").font(.title3.bold())
            Picker("Format", selection: $ratio) {
                ForEach(CropRatio.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .onChange(of: ratio) { _, _ in resetCrop() }

            GeometryReader { geo in
                if let playback, displaySize != .zero {
                    let iv = PhotoCropEditor.fit(displaySize, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        VideoPlayerSurface(player: playback.player)
                            .frame(width: iv.width, height: iv.height)
                            .position(x: iv.midX, y: iv.midY)
                        CropDim(crop: crop, imageRect: iv).fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        CropRectView(crop: $crop, imageRect: iv, normalizedAspect: normalizedAspect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .coordinateSpace(name: "crop")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 320)

            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: (playback?.isPlaying ?? false) ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .disabled(playback == nil)
                TrimBar(duration: duration, start: $startT, end: $endT, playhead: playheadBinding)
                    .frame(height: 34)
            }
            Text("Extrait : \(Self.time(startT)) → \(Self.time(endT))  ·  \(Self.time(endT - startT))")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                if isExporting { ProgressView().controlSize(.small); Text("Export…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Annuler") { playback?.stop(); onCancel() }.disabled(isExporting)
                Button("Enregistrer") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(avAsset == nil || isExporting || endT - startT < 0.3)
            }
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

    static func time(_ s: Double) -> String {
        let total = Int(max(0, s).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TrimBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { t in duration > 0 ? CGFloat(t / duration) * w : 0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.25))
                // zone retenue
                Rectangle().fill(Color.accentColor.opacity(0.3))
                    .frame(width: max(0, x(end) - x(start)))
                    .offset(x: x(start))
                // playhead
                Rectangle().fill(.white).frame(width: 2).offset(x: x(playhead))
                handle(color: .accentColor, at: x(start)) { nx in
                    start = min(max(0, nx / w * duration), end - 0.3)
                    playhead = start
                }
                handle(color: .accentColor, at: x(end)) { nx in
                    end = max(min(duration, nx / w * duration), start + 0.3)
                    playhead = end
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                playhead = min(max(0, Double(v.location.x / w) * duration), duration)
            })
        }
    }

    private func handle(color: Color, at px: CGFloat, onMove: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color)
            .frame(width: 10)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1))
            .offset(x: px - 5)
            .highPriorityGesture(DragGesture(coordinateSpace: .local).onChanged { v in onMove(v.location.x) })
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

