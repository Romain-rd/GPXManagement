import Foundation
import AVFoundation
import AppKit
import MapKit
import CoreLocation
import CoreImage
import GPXCore
import GPXMapKit

public enum TrackVideoMedia {
    case photo(image: NSImage, thumbnail: NSImage?, coordinate: CLLocationCoordinate2D, date: Date?, manualMeters: Double?)
    case video(asset: AVAsset, thumbnail: NSImage?, coordinate: CLLocationCoordinate2D, date: Date?, manualMeters: Double?)

    public var coordinate: CLLocationCoordinate2D {
        switch self {
        case .photo(_, _, let c, _, _), .video(_, _, let c, _, _): return c
        }
    }
    public var thumbnail: NSImage? {
        switch self {
        case .photo(_, let t, _, _, _), .video(_, let t, _, _, _): return t
        }
    }
    /// Heure de prise du média (EXIF/PHAsset) : sert à positionner le média dans le temps du parcours.
    public var date: Date? {
        switch self {
        case .photo(_, _, _, let d, _), .video(_, _, _, let d, _): return d
        }
    }
    /// Position manuelle réglée par l'utilisateur (mètres le long de la trace) ; nil = auto.
    public var manualMeters: Double? {
        switch self {
        case .photo(_, _, _, _, let m), .video(_, _, _, _, let m): return m
        }
    }
    public var isVideo: Bool { if case .video = self { return true }; return false }
}

public enum VideoInsetSize: String, CaseIterable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .small:  return "Petite"
        case .medium: return "Moyenne"
        case .large:  return "Grande"
        }
    }
    public var widthFactor: Double { self == .small ? 0.42 : (self == .medium ? 0.60 : 0.95) }
    public var heightFactor: Double { self == .small ? 0.46 : (self == .medium ? 0.66 : 0.95) }
}

public enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case hd720, fullHD1080
    public var id: String { rawValue }
    public var label: String { self == .hd720 ? "HD (720p)" : "Full HD (1080p)" }
    public var base: Int { self == .hd720 ? 720 : 1080 }
}

public enum VideoFormat: String, CaseIterable, Identifiable, Codable {
    case landscape, square, portrait
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .landscape: return "Paysage 16:9"
        case .square:    return "Carré 1:1"
        case .portrait:  return "Portrait 9:16"
        }
    }
    public var aspect: Double { let d = dimensions(base: 720); return Double(d.width) / Double(d.height) }

    /// Dimensions (paires) à partir d'une base = côté court (paysage/portrait) ou côté (carré).
    public func dimensions(base: Int) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { let i = Int(v.rounded()); return i % 2 == 0 ? i : i + 1 }
        switch self {
        case .landscape: return (even(Double(base) * 16.0 / 9.0), base)
        case .square:    return (base, base)
        case .portrait:  return (base, even(Double(base) * 16.0 / 9.0))
        }
    }
}

/// Zone rectangulaire en fractions du cadre (origine haut-gauche, v vers le bas).
public struct LayoutZone: Codable, Equatable {
    public var x: Double; public var y: Double; public var w: Double; public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct VideoLayout: Codable, Equatable {
    public var trace: LayoutZone
    public var media: LayoutZone
    public var profile: LayoutZone?   // nil → pas de profil

    public init(trace: LayoutZone, media: LayoutZone, profile: LayoutZone?) {
        self.trace = trace; self.media = media; self.profile = profile
    }

    public static func defaultLayout(for format: VideoFormat) -> VideoLayout {
        switch format {
        case .landscape:
            return VideoLayout(
                trace: LayoutZone(x: 0, y: 0, w: 0.58, h: 1),
                media: LayoutZone(x: 0.60, y: 0.04, w: 0.38, h: 0.62),
                profile: LayoutZone(x: 0.60, y: 0.74, w: 0.38, h: 0.22))
        case .square:
            return VideoLayout(
                trace: LayoutZone(x: 0, y: 0, w: 1, h: 0.80),
                media: LayoutZone(x: 0.08, y: 0.06, w: 0.84, h: 0.62),
                profile: LayoutZone(x: 0.04, y: 0.83, w: 0.92, h: 0.14))
        case .portrait:
            return VideoLayout(
                trace: LayoutZone(x: 0, y: 0, w: 1, h: 0.74),
                media: LayoutZone(x: 0.06, y: 0.05, w: 0.88, h: 0.55),
                profile: LayoutZone(x: 0.04, y: 0.78, w: 0.92, h: 0.12))
        }
    }
}

/// Modèle (template) : configuration vidéo complète, nommée et réutilisable.
public struct VideoTemplate: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var quality: VideoQuality
    public var format: VideoFormat
    public var layout: VideoLayout
    public var builtin: Bool
    public var transition: MediaTransition
    public var showHeartRate: Bool
    public var showIntro: Bool
    public var showOutro: Bool
    public var mapLayerRaw: String

    public init(id: String, name: String, quality: VideoQuality, format: VideoFormat, layout: VideoLayout, builtin: Bool,
         transition: MediaTransition = .fade, showHeartRate: Bool = true, showIntro: Bool = true, showOutro: Bool = true,
         mapLayerRaw: String = "ign_scan25") {
        self.id = id; self.name = name; self.quality = quality; self.format = format; self.layout = layout; self.builtin = builtin
        self.transition = transition; self.showHeartRate = showHeartRate; self.showIntro = showIntro; self.showOutro = showOutro
        self.mapLayerRaw = mapLayerRaw
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        quality = try c.decode(VideoQuality.self, forKey: .quality)
        format = try c.decode(VideoFormat.self, forKey: .format)
        layout = try c.decode(VideoLayout.self, forKey: .layout)
        builtin = (try? c.decode(Bool.self, forKey: .builtin)) ?? false
        transition = (try? c.decode(MediaTransition.self, forKey: .transition)) ?? .fade
        showHeartRate = (try? c.decode(Bool.self, forKey: .showHeartRate)) ?? true
        showIntro = (try? c.decode(Bool.self, forKey: .showIntro)) ?? true
        showOutro = (try? c.decode(Bool.self, forKey: .showOutro)) ?? true
        mapLayerRaw = (try? c.decode(String.self, forKey: .mapLayerRaw)) ?? "ign_scan25"
    }

    public static let builtins: [VideoTemplate] = [
        VideoTemplate(id: "builtin.sidebyside", name: "16:9 côte à côte", quality: .hd720, format: .landscape,
                      layout: .defaultLayout(for: .landscape), builtin: true),
        VideoTemplate(id: "builtin.fullscreen", name: "16:9 plein écran", quality: .hd720, format: .landscape,
                      layout: VideoLayout(trace: LayoutZone(x: 0, y: 0, w: 1, h: 1), media: LayoutZone(x: 0, y: 0, w: 1, h: 1), profile: nil), builtin: true, showHeartRate: false),
        VideoTemplate(id: "builtin.square", name: "Carré réseaux", quality: .fullHD1080, format: .square,
                      layout: VideoLayout(trace: LayoutZone(x: 0, y: 0, w: 1, h: 1), media: LayoutZone(x: 0.06, y: 0.06, w: 0.88, h: 0.72), profile: nil), builtin: true, showHeartRate: false),
        VideoTemplate(id: "builtin.story", name: "Story portrait", quality: .fullHD1080, format: .portrait,
                      layout: .defaultLayout(for: .portrait), builtin: true)
    ]
}

public enum MediaTransition: String, CaseIterable, Identifiable, Codable {
    case none, fade, zoom, slide
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none:  return "Aucune"
        case .fade:  return "Fondu"
        case .zoom:  return "Zoom"
        case .slide: return "Glissement"
        }
    }
}

public struct VideoConfig {
    public let width: Int
    public let height: Int
    public let layout: VideoLayout
    public let transition: MediaTransition
    public let showHeartRate: Bool
    public let showIntro: Bool
    public let showOutro: Bool
    public let mapLayer: MapLayer
    public let title: String
    public let dateText: String
    public let summary: [(label: String, value: String)]

    public init(width: Int, height: Int, layout: VideoLayout, transition: MediaTransition, showHeartRate: Bool,
                showIntro: Bool, showOutro: Bool, mapLayer: MapLayer, title: String, dateText: String,
                summary: [(label: String, value: String)]) {
        self.width = width; self.height = height; self.layout = layout; self.transition = transition
        self.showHeartRate = showHeartRate; self.showIntro = showIntro; self.showOutro = showOutro
        self.mapLayer = mapLayer; self.title = title; self.dateText = dateText; self.summary = summary
    }
}

public enum TrackVideoError: Error, LocalizedError {
    case noTrack
    case snapshotFailed
    case writerFailed

    public var errorDescription: String? {
        switch self {
        case .noTrack:        return "La trace ne contient pas assez de points."
        case .snapshotFailed: return "Impossible de générer la carte de fond."
        case .writerFailed:   return "Échec de l'écriture de la vidéo."
        }
    }
}

/// Génère un film (format/qualité au choix) : carton d'intro (titre + date), carte avec un point qui
/// parcourt le tracé, vignettes des médias sur la carte, encart d'infos (heure/altitude/pente), médias
/// sélectionnés affichés 4 s en encart (vidéos lues avec son), puis carton de fin (résumé des métriques).
public enum TrackVideoExporter {
    private static let fps: Int32 = 30
    private static let trackSeconds = 30.0
    private static let photoSeconds = 4.0
    private static let introSeconds = 3.0
    private static let outroSeconds = 5.0

    private static let animSeconds = 1.0

    private struct Hud { let time: Date?; let altitude: Double?; let slope: Double?; let speed: Double?; let heart: Double? }
    private struct ProfileOverlay { let image: NSImage; let rect: CGRect; let indicatorX: CGFloat; let indicatorY: CGFloat; let pad: CGFloat }
    private struct Appearance { var alpha: CGFloat; var scale: CGFloat; var dx: CGFloat; var dy: CGFloat
        static let full = Appearance(alpha: 1, scale: 1, dx: 0, dy: 0)
    }

    private static func appearance(_ transition: MediaTransition, progress: CGFloat, mediaRect: CGRect) -> Appearance {
        let p = Swift.max(0, Swift.min(1, progress))
        switch transition {
        case .none:  return .full
        case .fade:  return Appearance(alpha: p, scale: 1, dx: 0, dy: 0)
        case .zoom:  return Appearance(alpha: p, scale: 0.9 + 0.1 * p, dx: 0, dy: 0)
        case .slide: return Appearance(alpha: p, scale: 1, dx: 0, dy: -(1 - p) * mediaRect.height * 0.35)
        }
    }
    struct AudioInsert { let asset: AVAsset; let start: Double; let duration: Double }

    nonisolated(unsafe) private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "HH:mm"
        return f
    }()

    public static func export(points rawPoints: [TrackPoint], media: [TrackVideoMedia], config: VideoConfig, to outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let width = config.width, height = config.height
        let scale = Double(height) / 720.0
        let pts = decimate(rawPoints, max: 1500)
        guard pts.count >= 2 else { throw TrackVideoError.noTrack }
        let coords = pts.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        var cumulative: [Double] = [0]
        for i in 1..<coords.count {
            cumulative.append(cumulative[i - 1] + CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)))
        }
        let total = cumulative.last ?? 0
        guard total > 0 else { throw TrackVideoError.noTrack }
        let altitudes = smooth(fillNils(pts.map(\.altitude)), window: 7)
        let timestamps = pts.map(\.timestamp)
        // Plages de pause (mêmes réglages que l'app/PDF/web) calculées sur le profil plein → vitesse forcée à 0 à l'arrêt.
        let pauseMinSeconds = (UserDefaults.standard.object(forKey: "pauseThresholdMinutes") as? Double ?? 5) * 60
        let pauseRadiusMeters = UserDefaults.standard.object(forKey: "pauseRadiusMeters") as? Double ?? 40
        let pauseProfile = ElevationProfileBuilder.build(points: rawPoints)
        let pauseRanges = ElevationProfileBuilder.pausedTimeRanges(
            pauseProfile.isEmpty ? ElevationProfileBuilder.buildMotion(points: rawPoints) : pauseProfile,
            pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        let heartRates = smooth(fillNils(pts.map(\.heartRate)), window: 5)
        let hrAll = heartRates.compactMap { $0 }
        let hrMin = hrAll.min() ?? 0, hrMax = hrAll.max() ?? 1
        let hrEnabled = config.showHeartRate && hrAll.count >= 2 && (hrMax - hrMin) > 1

        // Disposition définie par l'utilisateur : 3 zones (trace, média, profil) en fractions.
        let layout = config.layout
        let alts = altitudes.compactMap { $0 }
        let altMin = alts.min() ?? 0, altMax = alts.max() ?? 1
        let profileEnabled = layout.profile != nil && alts.count >= 2 && (altMax - altMin) > 1
        let W = Double(width), H = Double(height)
        func pxRect(_ z: LayoutZone) -> CGRect {
            CGRect(x: z.x * W, y: H * (1 - z.y - z.h), width: z.w * W, height: z.h * H) // coords AppKit (bas-gauche)
        }
        let mediaRect: CGRect = pxRect(layout.media)
        let profileRect: CGRect = profileEnabled ? pxRect(layout.profile!) : .zero

        let bounding = boundingMapRect(coords)
        let aspect = W / H
        let mapRect = mapRectForZone(bounding: bounding, aspect: aspect, zone: layout.trace)
        // Fond de carte selon la couche choisie (IGN ou Apple), sans tracé : on dessine la trace nous-mêmes.
        let mapImage: NSImage
        if let png = try? await MapImageExporter.renderPNG(layer: config.mapLayer, mapRect: mapRect, tracks: [], maxDimension: Swift.max(width, height)),
           let img = NSImage(data: png) {
            mapImage = img
        } else {
            throw TrackVideoError.snapshotFailed
        }
        let project: (CLLocationCoordinate2D) -> CGPoint = { coord in
            let mp = MKMapPoint(coord)
            let nx = (mp.x - mapRect.minX) / mapRect.width
            let ny = (mp.y - mapRect.minY) / mapRect.height
            return CGPoint(x: nx * Double(width), y: (1 - ny) * Double(height))
        }

        func segment(at meters: Double) -> (lo: Int, hi: Int, t: Double) {
            let n = coords.count - 1
            if meters <= 0 { return (0, Swift.min(1, n), 0) }
            if meters >= total { return (Swift.max(0, n - 1), n, 1) }
            var i = 1
            while i < cumulative.count && cumulative[i] < meters { i += 1 }
            let segLen = cumulative[i] - cumulative[i - 1]
            return (i - 1, i, segLen > 0 ? (meters - cumulative[i - 1]) / segLen : 0)
        }
        func altitudeAt(_ meters: Double) -> Double? {
            let s = segment(at: meters)
            switch (altitudes[s.lo], altitudes[s.hi]) {
            case let (a?, b?): return a + (b - a) * s.t
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        func timeAt(_ meters: Double) -> Date? {
            let s = segment(at: meters)
            guard let a = timestamps[s.lo], let b = timestamps[s.hi] else { return timestamps.compactMap { $0 }.first }
            return a.addingTimeInterval(b.timeIntervalSince(a) * s.t)
        }
        func hrAt(_ meters: Double) -> Double? {
            let s = segment(at: meters)
            switch (heartRates[s.lo], heartRates[s.hi]) {
            case let (a?, b?): return a + (b - a) * s.t
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }
        func hud(at meters: Double) -> Hud {
            let lo = max(0, meters - 50), hi = min(total, meters + 50)
            var slope: Double?
            if let aLo = altitudeAt(lo), let aHi = altitudeAt(hi), hi - lo > 1 { slope = (aHi - aLo) / (hi - lo) * 100 }
            var speed: Double?
            if let t1 = timeAt(lo), let t2 = timeAt(hi) {
                let dt = t2.timeIntervalSince(t1)
                if dt > 0.5 { speed = (hi - lo) / dt } // m/s
            }
            // À l'arrêt, la vitesse réelle est nulle (le jitter GPS en fabriquait une).
            if let t = timeAt(meters), pauseRanges.contains(where: { $0.contains(t) }) { speed = 0 }
            return Hud(time: timeAt(meters), altitude: altitudeAt(meters), slope: slope, speed: speed, heart: hrEnabled ? hrAt(meters) : nil)
        }

        let markers = media.map { (point: project($0.coordinate), image: $0.thumbnail, isVideo: $0.isVideo) }
        let background = bakeBackground(mapImage: mapImage, points: coords.map(project), markers: markers, width: width, height: height, scale: scale)
        let projectedPoints = coords.map(project)
        func position(atMeters meters: Double) -> CGPoint {
            let s = segment(at: meters)
            return CGPoint(x: projectedPoints[s.lo].x + (projectedPoints[s.hi].x - projectedPoints[s.lo].x) * s.t,
                           y: projectedPoints[s.lo].y + (projectedPoints[s.hi].y - projectedPoints[s.lo].y) * s.t)
        }

        // Position des médias via le résolveur central (manuel → heure → GPS) : l'heure lève l'ambiguïté
        // des allers-retours (une même position = deux instants ; sans ça une photo du retour retombait sur l'aller).
        let resolver = MediaTrackResolver(points: pts)
        func distanceForMedia(_ m: TrackVideoMedia) -> Double {
            resolver.distance(manualMeters: m.manualMeters, captureDate: m.date,
                              gpsLatitude: m.coordinate.latitude, gpsLongitude: m.coordinate.longitude) ?? 0
        }
        let ordered = media
            .map { (m: $0, dist: distanceForMedia($0)) }
            .sorted { $0.dist < $1.dist }

        let profilePad = 8.0 * scale
        let profilePanel: NSImage? = profileEnabled
            ? bakeProfile(size: profileRect.size, pad: profilePad, total: total, altMin: altMin, altMax: altMax, scale: scale, altAt: altitudeAt,
                          hr: hrEnabled ? (min: hrMin, max: hrMax, at: hrAt) : nil)
            : nil
        func profileOverlay(atMeters meters: Double) -> ProfileOverlay? {
            guard let panel = profilePanel else { return nil }
            let frac = total > 0 ? Swift.min(1, Swift.max(0, meters / total)) : 0
            let x = profileRect.minX + profilePad + frac * (profileRect.width - 2 * profilePad)
            let alt = altitudeAt(meters) ?? altMin
            let y = profileRect.minY + profilePad + CGFloat((alt - altMin) / Swift.max(1, altMax - altMin)) * (profileRect.height - 2 * profilePad)
            return ProfileOverlay(image: panel, rect: profileRect, indicatorX: x, indicatorY: y, pad: profilePad)
        }
        let hudBottom = 20 * scale

        let mutedURL = FileManager.default.temporaryDirectory.appendingPathComponent("track-muted-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: mutedURL)
        let writer = try AVAssetWriter(outputURL: mutedURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw TrackVideoError.writerFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        let ciContext = CIContext()
        var audioInserts: [AudioInsert] = []

        func append(_ image: CGImage) {
            while !input.isReadyForMoreMediaData { usleep(3000) }
            if let buffer = VideoRendering.pixelBuffer(from: image, pool: adaptor.pixelBufferPool, width: width, height: height) {
                adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
                frameIndex += 1
            }
        }

        // Carton d'intro (titre + date) — optionnel.
        if config.showIntro {
            let intro = drawCard(background: background, title: config.title, subtitle: config.dateText, lines: [], width: width, height: height, scale: scale)
            for _ in 0..<Int(introSeconds * Double(fps)) { autoreleasepool { append(intro) } }
        }
        progress(0.05)

        func emitMedia(_ entry: (m: TrackVideoMedia, dist: Double)) async {
            let point = project(entry.m.coordinate)
            let info = hud(at: entry.dist)
            // Le profil reste affiché ; si la zone média le recouvre (plein écran), il est masqué naturellement.
            let overlay = profileOverlay(atMeters: entry.dist)
            let anim = Swift.max(1, Int(animSeconds * Double(fps)))
            switch entry.m {
            case .photo(let image, _, _, _, _):
                let total = Int(photoSeconds * Double(fps))
                for i in 0..<total {
                    autoreleasepool {
                        let p: CGFloat = i < anim ? CGFloat(i) / CGFloat(anim)
                            : (i >= total - anim ? CGFloat(total - i) / CGFloat(anim) : 1)
                        let app = appearance(config.transition, progress: p, mediaRect: mediaRect)
                        append(renderFrame(background: background, point: point, hud: info, encart: image, width: width, height: height, scale: scale, profile: overlay, hudBottom: hudBottom, mediaRect: mediaRect, appearance: app))
                    }
                }
            case .video(let asset, _, _, _, _):
                let start = Double(frameIndex) / Double(fps)
                let emitted = await emitVideoSegment(asset: asset, background: background, point: point, hud: info, width: width, height: height, scale: scale, profile: overlay, hudBottom: hudBottom, mediaRect: mediaRect, transition: config.transition, animFrames: anim, ciContext: ciContext, append: append)
                if emitted > 0 { audioInserts.append(AudioInsert(asset: asset, start: start, duration: Double(emitted) / Double(fps))) }
            }
        }

        let trackFrames = Int(trackSeconds * Double(fps))
        var mediaPtr = 0
        for f in 0...trackFrames {
            let target = (Double(f) / Double(trackFrames)) * total
            while mediaPtr < ordered.count, ordered[mediaPtr].dist <= target { await emitMedia(ordered[mediaPtr]); mediaPtr += 1 }
            autoreleasepool {
                append(renderFrame(background: background, point: position(atMeters: target), hud: hud(at: target), encart: nil, width: width, height: height, scale: scale, profile: profileOverlay(atMeters: target), hudBottom: hudBottom, mediaRect: nil))
            }
            if f % 15 == 0 { progress(0.08 + 0.6 * Double(f) / Double(trackFrames)) }
        }
        while mediaPtr < ordered.count { await emitMedia(ordered[mediaPtr]); mediaPtr += 1 }

        // Carton de fin (titre + résumé des métriques) — optionnel.
        if config.showOutro {
            let outro = drawCard(background: background, title: config.title, subtitle: nil, lines: config.summary, width: width, height: height, scale: scale, footer: "Réalisé avec GPXManagement.net")
            for _ in 0..<Int(outroSeconds * Double(fps)) { autoreleasepool { append(outro) } }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TrackVideoError.writerFailed }

        progress(0.75)
        try await mux(mutedVideo: mutedURL, audio: audioInserts, to: outputURL)
        try? FileManager.default.removeItem(at: mutedURL)
        progress(1)
    }

    // MARK: - Segment vidéo (frames réelles décodées)

    private static func emitVideoSegment(asset: AVAsset, background: NSImage, point: CGPoint, hud: Hud, width: Int, height: Int, scale: Double, profile: ProfileOverlay?, hudBottom: CGFloat, mediaRect: CGRect?, transition: MediaTransition, animFrames: Int, ciContext: CIContext, append: (CGImage) -> Void) async -> Int {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading() else { return 0 }

        let rect = mediaRect ?? .zero
        var emitted = 0
        let frameStep = CMTime(value: 1, timescale: fps)
        var nextEmitTime = CMTime.zero
        var lastImage: CGImage?

        func frame(_ image: CGImage, _ app: Appearance) {
            append(renderFrame(background: background, point: point, hud: hud, encartCG: image, width: width, height: height, scale: scale, profile: profile, hudBottom: hudBottom, mediaRect: mediaRect, appearance: app))
        }

        // Lecture du clip en entier (rééchantillonné à 30 fps), avec animation d'entrée sur le début.
        while true {
            let more = autoreleasepool { () -> Bool in
                guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { return false }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                let ci = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                lastImage = ciContext.createCGImage(ci, from: ci.extent)
                while CMTimeCompare(presentation, nextEmitTime) >= 0 {
                    if let image = lastImage {
                        let p: CGFloat = emitted < animFrames ? CGFloat(emitted) / CGFloat(animFrames) : 1
                        frame(image, appearance(transition, progress: p, mediaRect: rect))
                        emitted += 1
                    }
                    nextEmitTime = CMTimeAdd(nextEmitTime, frameStep)
                }
                return true
            }
            if !more { break }
        }
        if emitted == 0, let image = lastImage {
            for i in 0..<Int(Double(fps)) {
                autoreleasepool {
                    let p: CGFloat = i < animFrames ? CGFloat(i) / CGFloat(animFrames) : 1
                    frame(image, appearance(transition, progress: p, mediaRect: rect)); emitted += 1
                }
            }
        }
        reader.cancelReading()
        // Disparition : frames figées sur la dernière image (sans audio).
        let played = emitted
        if let image = lastImage, transition != .none {
            for k in 0..<animFrames {
                autoreleasepool {
                    let p = CGFloat(animFrames - k) / CGFloat(animFrames)
                    frame(image, appearance(transition, progress: p, mediaRect: rect))
                }
            }
        }
        return played
    }

    private static func mux(mutedVideo: URL, audio inserts: [AudioInsert], to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: mutedVideo)
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first else { throw TrackVideoError.writerFailed }
        let fullDuration = try await videoAsset.load(.duration)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: fullDuration), of: srcVideo, at: .zero)

        if !inserts.isEmpty {
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            for insert in inserts {
                guard let srcAudio = try? await insert.asset.loadTracks(withMediaType: .audio).first else { continue }
                let clipDuration = (try? await insert.asset.load(.duration)) ?? .zero
                let wanted = CMTime(seconds: min(insert.duration, CMTimeGetSeconds(clipDuration)), preferredTimescale: 600)
                guard wanted.seconds > 0 else { continue }
                try? audioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: wanted), of: srcAudio, at: CMTime(seconds: insert.start, preferredTimescale: 600))
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw TrackVideoError.writerFailed }
        try await session.export(to: outputURL, as: .mp4)
    }

    // MARK: - Rendu

    private static func bakeBackground(mapImage: NSImage, points: [CGPoint], markers: [(point: CGPoint, image: NSImage?, isVideo: Bool)], width: Int, height: Int, scale: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        mapImage.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        let path = NSBezierPath()
        for (i, p) in points.enumerated() { if i == 0 { path.move(to: p) } else { path.line(to: p) } }
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        NSColor.white.setStroke(); path.lineWidth = 7 * scale; path.stroke()
        NSColor.systemRed.setStroke(); path.lineWidth = 4 * scale; path.stroke()
        for marker in markers { drawMarker(at: marker.point, image: marker.image, isVideo: marker.isVideo, scale: scale) }
        image.unlockFocus()
        return image
    }

    private static func drawMarker(at p: CGPoint, image: NSImage?, isVideo: Bool, scale: Double) {
        let side: CGFloat = 40 * scale
        let box = NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        NSColor.white.setFill(); NSBezierPath(roundedRect: box, xRadius: 7 * scale, yRadius: 7 * scale).fill()
        let inner = box.insetBy(dx: 2 * scale, dy: 2 * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: 5 * scale, yRadius: 5 * scale).addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let s = max(inner.width / image.size.width, inner.height / image.size.height)
            let dw = image.size.width * s, dh = image.size.height * s
            image.draw(in: NSRect(x: inner.midX - dw / 2, y: inner.midY - dh / 2, width: dw, height: dh))
        } else {
            NSColor.systemGray.setFill(); NSBezierPath(roundedRect: inner, xRadius: 5 * scale, yRadius: 5 * scale).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if isVideo {
            let d: CGFloat = 14 * scale
            let c = NSRect(x: box.midX - d / 2, y: box.midY - d / 2, width: d, height: d)
            NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(ovalIn: c).fill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: c.midX - 2.5 * scale, y: c.midY - 3.5 * scale))
            tri.line(to: NSPoint(x: c.midX - 2.5 * scale, y: c.midY + 3.5 * scale))
            tri.line(to: NSPoint(x: c.midX + 3.5 * scale, y: c.midY))
            tri.close(); NSColor.white.setFill(); tri.fill()
        }
    }

    private static func bakeProfile(size: NSSize, pad: CGFloat, total: Double, altMin: Double, altMax: Double, scale: Double, altAt: (Double) -> Double?, hr: (min: Double, max: Double, at: (Double) -> Double?)?) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10 * scale, yRadius: 10 * scale).fill()

        let innerW = size.width - 2 * pad, innerH = size.height - 2 * pad
        let range = Swift.max(1, altMax - altMin)
        let samples = Swift.max(40, Int(innerW / 2))
        let area = NSBezierPath()
        area.move(to: NSPoint(x: pad, y: pad))
        var topPoints: [NSPoint] = []
        for i in 0...samples {
            let f = Double(i) / Double(samples)
            let x = pad + CGFloat(f) * innerW
            let alt = altAt(f * total) ?? altMin
            let y = pad + CGFloat((alt - altMin) / range) * innerH
            let p = NSPoint(x: x, y: y)
            area.line(to: p); topPoints.append(p)
        }
        area.line(to: NSPoint(x: pad + innerW, y: pad)); area.close()
        NSColor.systemTeal.withAlphaComponent(0.45).setFill(); area.fill()
        let top = NSBezierPath()
        for (i, p) in topPoints.enumerated() { i == 0 ? top.move(to: p) : top.line(to: p) }
        top.lineWidth = 2 * scale; NSColor.white.withAlphaComponent(0.9).setStroke(); top.stroke()

        if let hr {
            let range = Swift.max(1, hr.max - hr.min)
            let line = NSBezierPath()
            var started = false
            for i in 0...samples {
                let f = Double(i) / Double(samples)
                guard let v = hr.at(f * total) else { continue }
                let x = pad + CGFloat(f) * innerW
                let y = pad + CGFloat((v - hr.min) / range) * innerH
                if started { line.line(to: NSPoint(x: x, y: y)) } else { line.move(to: NSPoint(x: x, y: y)); started = true }
            }
            line.lineWidth = 2 * scale; NSColor.systemRed.withAlphaComponent(0.95).setStroke(); line.stroke()
        }
        image.unlockFocus()
        return image
    }

    private static func renderFrame(background: NSImage, point: CGPoint, hud: Hud, encart: NSImage?, width: Int, height: Int, scale: Double, profile: ProfileOverlay?, hudBottom: CGFloat, mediaRect: CGRect?, appearance app: Appearance = .full) -> CGImage {
        drawFrame(background: background, point: point, hud: hud, width: width, height: height, scale: scale, profile: profile, hudBottom: hudBottom) { _ in
            if let encart, let mediaRect { drawEncart(encart, mediaRect: mediaRect, scale: scale, appearance: app) }
        }
    }

    private static func renderFrame(background: NSImage, point: CGPoint, hud: Hud, encartCG: CGImage, width: Int, height: Int, scale: Double, profile: ProfileOverlay?, hudBottom: CGFloat, mediaRect: CGRect?, appearance app: Appearance = .full) -> CGImage {
        let nsImage = NSImage(cgImage: encartCG, size: NSSize(width: encartCG.width, height: encartCG.height))
        return renderFrame(background: background, point: point, hud: hud, encart: nsImage, width: width, height: height, scale: scale, profile: profile, hudBottom: hudBottom, mediaRect: mediaRect, appearance: app)
    }

    private static func drawFrame(background: NSImage, point: CGPoint, hud: Hud, width: Int, height: Int, scale: Double, profile: ProfileOverlay?, hudBottom: CGFloat, overlay: (NSRect) -> Void) -> CGImage {
        let rep = VideoRendering.bitmap(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        background.draw(in: rect)
        let r: CGFloat = 9 * scale
        let dot = NSRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -2 * scale, dy: -2 * scale)).fill()
        NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot).fill()
        if let profile { drawProfile(profile, scale: scale) }
        drawHud(hud, scale: scale, bottomY: hudBottom)
        overlay(rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static func drawProfile(_ profile: ProfileOverlay, scale: Double) {
        profile.image.draw(in: profile.rect)
        let top = profile.rect.maxY - profile.pad
        let bottom = profile.rect.minY + profile.pad
        let line = NSBezierPath()
        line.move(to: NSPoint(x: profile.indicatorX, y: bottom))
        line.line(to: NSPoint(x: profile.indicatorX, y: top))
        line.lineWidth = 1.5 * scale
        NSColor.white.withAlphaComponent(0.85).setStroke(); line.stroke()
        let d = 8.0 * scale
        let dot = NSRect(x: profile.indicatorX - d / 2, y: profile.indicatorY - d / 2, width: d, height: d)
        NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -1.5 * scale, dy: -1.5 * scale)).fill()
        NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot).fill()
    }

    private static func drawHud(_ hud: Hud, scale: Double, bottomY: CGFloat) {
        var lines: [String] = []
        if let t = hud.time { lines.append(clockFormatter.string(from: t)) }
        if let a = hud.altitude { lines.append("\(Int(a.rounded())) m") }
        if let v = hud.speed { lines.append(String(format: "%.0f km/h", v * 3.6)) }
        if let h = hud.heart { lines.append("\(Int(h.rounded())) bpm") }
        if let s = hud.slope { lines.append(String(format: "%+.0f %% ", s) + (s >= 0 ? "↑" : "↓")) }
        guard !lines.isEmpty else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 20 * scale, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let strings = lines.map { NSAttributedString(string: $0, attributes: attrs) }
        let lineHeight = 26 * scale
        let textWidth = strings.map { $0.size().width }.max() ?? 80
        let box = NSRect(x: 20 * scale, y: bottomY, width: textWidth + 24 * scale, height: CGFloat(lines.count) * lineHeight + 14 * scale)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10 * scale, yRadius: 10 * scale).fill()
        for (i, s) in strings.enumerated() {
            let y = box.maxY - 9 * scale - lineHeight * CGFloat(i + 1) + (lineHeight - s.size().height) / 2
            s.draw(at: NSPoint(x: box.minX + 12 * scale, y: y))
        }
    }

    private static func drawEncart(_ image: NSImage, mediaRect: CGRect, scale: Double, appearance app: Appearance) {
        let border = 7.0 * scale
        let ar = image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 1
        let avail = mediaRect.insetBy(dx: border, dy: border)
        var w = avail.width, h = avail.width / ar
        if h > avail.height { h = avail.height; w = avail.height * ar }
        let box = NSRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
        let a = app.alpha

        NSGraphicsContext.saveGraphicsState()
        if app.scale != 1 || app.dx != 0 || app.dy != 0 {
            let t = NSAffineTransform()
            t.translateX(by: mediaRect.midX + app.dx, yBy: mediaRect.midY + app.dy)
            t.scale(by: app.scale)
            t.translateX(by: -mediaRect.midX, yBy: -mediaRect.midY)
            t.concat()
        }
        NSColor.black.withAlphaComponent(0.4 * a).setFill()
        NSBezierPath(roundedRect: box.insetBy(dx: -7 * scale, dy: -7 * scale), xRadius: 14 * scale, yRadius: 14 * scale).fill()
        NSColor.white.withAlphaComponent(a).setFill()
        NSBezierPath(roundedRect: box.insetBy(dx: -4 * scale, dy: -4 * scale), xRadius: 12 * scale, yRadius: 12 * scale).fill()
        NSBezierPath(roundedRect: box, xRadius: 9 * scale, yRadius: 9 * scale).addClip()
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: a)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCard(background: NSImage, title: String, subtitle: String?, lines: [(label: String, value: String)], width: Int, height: Int, scale: Double, footer: String? = nil) -> CGImage {
        let rep = VideoRendering.bitmap(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let W = CGFloat(width), H = CGFloat(height)
        background.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSColor.black.withAlphaComponent(0.6).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()

        let subFont = NSFont.systemFont(ofSize: 26 * scale, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 17 * scale, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 30 * scale, weight: .semibold)
        let white = NSColor.white
        let grey = NSColor(white: 0.72, alpha: 1)

        // Géométrie du panneau central (largeur bornée) et titre auto-ajusté pour tenir dedans.
        let cols = lines.isEmpty ? 1 : 2
        let rows = lines.isEmpty ? 0 : Int(ceil(Double(lines.count) / Double(cols)))
        let pad = 34 * scale
        let panelW = W * 0.86
        let maxContentW = panelW - pad * 2

        func fitted(_ text: String, baseSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
            VideoRendering.fittedText(text, baseSize: baseSize, weight: weight, color: color, maxWidth: maxContentW)
        }

        let titleStr = fitted(title, baseSize: 48 * scale, weight: .bold, color: white)
        let subStr = subtitle.map { NSAttributedString(string: $0, attributes: [.font: subFont, .foregroundColor: grey]) }

        let titleH = titleStr.size().height
        let subH = subStr?.size().height ?? 0
        let sepGap = lines.isEmpty ? (subStr != nil ? 16 * scale : 0) : 26 * scale
        let cellH = 70 * scale
        let contentH = titleH + (subH > 0 ? 10 * scale + subH : 0) + sepGap + CGFloat(rows) * cellH
        let panelH = contentH + pad * 2
        let panel = NSRect(x: (W - panelW) / 2, y: (H - panelH) / 2, width: panelW, height: panelH)

        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 22 * scale, yRadius: 22 * scale).fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        let border = NSBezierPath(roundedRect: panel, xRadius: 22 * scale, yRadius: 22 * scale); border.lineWidth = 1.5 * scale; border.stroke()

        var y = panel.maxY - pad
        // Titre
        y -= titleH
        titleStr.draw(at: NSPoint(x: panel.midX - titleStr.size().width / 2, y: y))
        // Sous-titre (intro)
        if let subStr {
            y -= 10 * scale + subStr.size().height
            subStr.draw(at: NSPoint(x: panel.midX - subStr.size().width / 2, y: y))
        }
        // Séparateur + grille des métriques (fin)
        if !lines.isEmpty {
            y -= sepGap
            let sepY = y + sepGap / 2
            NSColor(white: 1, alpha: 0.18).setFill()
            NSRect(x: panel.minX + pad, y: sepY, width: panel.width - pad * 2, height: 1 * scale).fill()

            let cellW = (panel.width - pad * 2) / CGFloat(cols)
            for (i, line) in lines.enumerated() {
                let col = i % cols, row = i / cols
                let cellX = panel.minX + pad + CGFloat(col) * cellW
                let cellTop = y - CGFloat(row) * cellH
                let labelStr = NSAttributedString(string: line.label.uppercased(), attributes: [.font: labelFont, .foregroundColor: grey])
                let valueStr = NSAttributedString(string: line.value, attributes: [.font: valueFont, .foregroundColor: white])
                labelStr.draw(at: NSPoint(x: cellX, y: cellTop - labelStr.size().height - 4 * scale))
                valueStr.draw(at: NSPoint(x: cellX, y: cellTop - labelStr.size().height - valueStr.size().height - 8 * scale))
            }
        }
        // Crédit (dernier plan) — discret, centré en bas de l'écran.
        if let footer, !footer.isEmpty {
            let footFont = NSFont.systemFont(ofSize: 20 * scale, weight: .medium)
            let footStr = NSAttributedString(string: footer, attributes: [.font: footFont, .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            footStr.draw(at: NSPoint(x: W / 2 - footStr.size().width / 2, y: 46 * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // MARK: - Helpers

    private static func boundingMapRect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect {
        var rect = MKMapRect.null
        for c in coords { rect = rect.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 0, height: 0))) }
        return rect.insetBy(dx: -rect.size.width * 0.12 - 1, dy: -rect.size.height * 0.12 - 1)
    }

    private static func aspectFitted(_ rect: MKMapRect, aspect: Double) -> MKMapRect {
        var r = rect
        if r.size.width / r.size.height < aspect {
            let nw = r.size.height * aspect; r.origin.x -= (nw - r.size.width) / 2; r.size.width = nw
        } else {
            let nh = r.size.width / aspect; r.origin.y -= (nh - r.size.height) / 2; r.size.height = nh
        }
        return r
    }

    /// Cadre le tracé pour qu'il remplisse au mieux la zone donnée (fractions image, origine haut-gauche),
    /// en conservant le ratio de l'image. Le tracé est centré dans la zone.
    private static func mapRectForZone(bounding: MKMapRect, aspect: Double, zone: LayoutZone) -> MKMapRect {
        let bw = bounding.size.width, bh = bounding.size.height
        let rw = Swift.max(0.05, zone.w), rh = Swift.max(0.05, zone.h)
        let hMap = Swift.max(bw / (rw * aspect), bh / rh)
        let wMap = hMap * aspect
        let uc = zone.x + zone.w / 2, vc = zone.y + zone.h / 2
        return MKMapRect(x: bounding.midX - uc * wMap, y: bounding.midY - vc * hMap, width: wMap, height: hMap)
    }

    private static func decimate(_ points: [TrackPoint], max: Int) -> [TrackPoint] {
        guard points.count > max else { return points }
        let step = Double(points.count) / Double(max)
        return (0..<max).map { points[Int(Double($0) * step)] }
    }

    private static func fillNils(_ values: [Double?]) -> [Double?] {
        guard values.contains(where: { $0 != nil }) else { return values }
        var result = values
        var last: Double?
        for i in result.indices { if let v = result[i] { last = v } else { result[i] = last } }
        var next: Double?
        for i in result.indices.reversed() { if let v = result[i] { next = v } else { result[i] = next } }
        return result
    }

    private static func smooth(_ values: [Double?], window: Int) -> [Double?] {
        guard window > 1 else { return values }
        let half = window / 2
        return values.indices.map { i -> Double? in
            let lo = Swift.max(0, i - half), hi = Swift.min(values.count - 1, i + half)
            let slice = (lo...hi).compactMap { values[$0] }
            return slice.isEmpty ? nil : slice.reduce(0, +) / Double(slice.count)
        }
    }
}
