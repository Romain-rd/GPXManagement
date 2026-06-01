import Foundation
import AVFoundation
import AppKit
import GPXCore
import GPXMapKit

struct RaidVideoStage {
    let title: String
    let dateText: String
    let points: [TrackPoint]
    let media: [TrackVideoMedia]
    let layout: VideoLayout
}

struct RaidVideoConfig {
    let width: Int
    let height: Int
    let transition: MediaTransition
    let showHeartRate: Bool
    let showStageCards: Bool
    let mapLayer: MapLayer
    let title: String
    let dateText: String
    let place: String?
    let summary: [(label: String, value: String)]
    let coverImage: NSImage?
    let participants: [(name: String, avatar: NSImage?)]
}

enum RaidVideoError: Error, LocalizedError {
    case noStages
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .noStages:     return "Aucune étape avec un tracé exploitable dans ce raid."
        case .writerFailed: return "Échec de l'écriture de la vidéo du raid."
        }
    }
}

/// Film d'un raid : carton d'intro (couverture + titre + participants), un clip par étape (généré par
/// TrackVideoExporter), puis carton de fin (stats cumulées + participants). Les segments sont concaténés.
enum RaidVideoExporter {
    private static let fps: Int32 = 30
    private static let introSeconds = 4.5
    private static let outroSeconds = 6.0

    static func export(stages: [RaidVideoStage], config: RaidVideoConfig, to outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let playable = stages.filter { $0.points.count >= 2 }
        guard !playable.isEmpty else { throw RaidVideoError.noStages }

        let width = config.width, height = config.height
        let tmp = FileManager.default.temporaryDirectory
        var segments: [URL] = []

        let introURL = tmp.appendingPathComponent("raid-intro-\(UUID().uuidString).mp4")
        try await writeStillClip(drawIntro(config), width: width, height: height, seconds: introSeconds, to: introURL)
        segments.append(introURL)
        progress(0.05)

        for (i, stage) in playable.enumerated() {
            let stageURL = tmp.appendingPathComponent("raid-stage-\(i)-\(UUID().uuidString).mp4")
            let stageConfig = VideoConfig(
                width: width, height: height, layout: stage.layout, transition: config.transition,
                showHeartRate: config.showHeartRate && stage.layout.profile != nil, showIntro: config.showStageCards, showOutro: false,
                mapLayer: config.mapLayer, title: stage.title, dateText: stage.dateText, summary: []
            )
            try await TrackVideoExporter.export(points: stage.points, media: stage.media, config: stageConfig, to: stageURL) { f in
                progress(0.05 + 0.8 * (Double(i) + f) / Double(playable.count))
            }
            segments.append(stageURL)
        }
        progress(0.86)

        let outroURL = tmp.appendingPathComponent("raid-outro-\(UUID().uuidString).mp4")
        try await writeStillClip(drawOutro(config), width: width, height: height, seconds: outroSeconds, to: outroURL)
        segments.append(outroURL)
        progress(0.9)

        try await concatenate(segments, to: outputURL)
        for url in segments { try? FileManager.default.removeItem(at: url) }
        progress(1)
    }

    // MARK: - Concaténation

    private static func concatenate(_ urls: [URL], to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RaidVideoError.writerFailed
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let srcVideo = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = (try? await asset.load(.duration)) ?? .zero
            guard duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: srcVideo, at: cursor)
            if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(range, of: srcAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RaidVideoError.writerFailed
        }
        try await session.export(to: outputURL, as: .mp4)
    }

    // MARK: - Écriture d'un carton fixe

    private static func writeStillClip(_ image: CGImage, width: Int, height: Int, seconds: Double, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw RaidVideoError.writerFailed }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        var idx: Int64 = 0
        for _ in 0..<frames {
            autoreleasepool {
                while !input.isReadyForMoreMediaData { usleep(2000) }
                if let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool, width: width, height: height) {
                    adaptor.append(buffer, withPresentationTime: CMTime(value: idx, timescale: fps))
                    idx += 1
                }
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RaidVideoError.writerFailed }
    }

    // MARK: - Cartons

    private static func drawIntro(_ config: RaidVideoConfig) -> CGImage {
        card(width: config.width, height: config.height) { W, H, scale in
            drawBackdrop(config.coverImage, width: W, height: H)
            let white = NSColor.white
            let grey = NSColor(white: 0.82, alpha: 1)
            let titleStr = fitted(config.title, base: 56 * scale, weight: .bold, color: white, maxWidth: W * 0.86)
            var subtitleText = config.dateText
            if let place = config.place, !place.isEmpty { subtitleText += "  ·  \(place)" }
            let subStr = NSAttributedString(string: subtitleText, attributes: [
                .font: NSFont.systemFont(ofSize: 26 * scale, weight: .medium), .foregroundColor: grey
            ])
            var y = H * 0.62
            titleStr.draw(at: NSPoint(x: (W - titleStr.size().width) / 2, y: y))
            y -= 14 * scale + subStr.size().height
            subStr.draw(at: NSPoint(x: (W - subStr.size().width) / 2, y: y))
            if !config.participants.isEmpty {
                drawParticipants(config.participants, baselineY: H * 0.18, width: W, scale: scale)
            }
        }
    }

    private static func drawOutro(_ config: RaidVideoConfig) -> CGImage {
        card(width: config.width, height: config.height) { W, H, scale in
            drawBackdrop(config.coverImage, width: W, height: H, dim: 0.7)
            let white = NSColor.white
            let grey = NSColor(white: 0.78, alpha: 1)
            let titleStr = fitted(config.title, base: 44 * scale, weight: .bold, color: white, maxWidth: W * 0.86)
            titleStr.draw(at: NSPoint(x: (W - titleStr.size().width) / 2, y: H * 0.78))

            // Grille des stats cumulées (2 colonnes).
            let lines = config.summary
            if !lines.isEmpty {
                let cols = 2
                let rows = Int(ceil(Double(lines.count) / Double(cols)))
                let labelFont = NSFont.systemFont(ofSize: 18 * scale, weight: .regular)
                let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 32 * scale, weight: .semibold)
                let cellH = 78 * scale
                let gridW = W * 0.7
                let cellW = gridW / CGFloat(cols)
                let gridTop = H * 0.66
                for (i, line) in lines.enumerated() {
                    let col = i % cols, row = i / cols
                    let cx = (W - gridW) / 2 + CGFloat(col) * cellW + cellW / 2
                    let top = gridTop - CGFloat(row) * cellH
                    let valueStr = NSAttributedString(string: line.value, attributes: [.font: valueFont, .foregroundColor: white])
                    let labelStr = NSAttributedString(string: line.label.uppercased(), attributes: [.font: labelFont, .foregroundColor: grey])
                    valueStr.draw(at: NSPoint(x: cx - valueStr.size().width / 2, y: top - valueStr.size().height))
                    labelStr.draw(at: NSPoint(x: cx - labelStr.size().width / 2, y: top - valueStr.size().height - 6 * scale - labelStr.size().height))
                }
                _ = rows
            }
            if !config.participants.isEmpty {
                drawParticipants(config.participants, baselineY: H * 0.12, width: W, scale: scale)
            }
        }
    }

    private static func drawBackdrop(_ cover: NSImage?, width W: CGFloat, height H: CGFloat, dim: CGFloat = 0.55) {
        let full = NSRect(x: 0, y: 0, width: W, height: H)
        if let cover, cover.size.width > 0, cover.size.height > 0 {
            let s = Swift.max(W / cover.size.width, H / cover.size.height)
            let dw = cover.size.width * s, dh = cover.size.height * s
            cover.draw(in: NSRect(x: full.midX - dw / 2, y: full.midY - dh / 2, width: dw, height: dh))
            NSColor.black.withAlphaComponent(dim).setFill(); full.fill()
        } else {
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).setFill(); full.fill()
        }
    }

    private static func drawParticipants(_ participants: [(name: String, avatar: NSImage?)], baselineY: CGFloat, width W: CGFloat, scale: CGFloat) {
        let shown = Array(participants.prefix(6))
        guard !shown.isEmpty else { return }
        let avatar: CGFloat = 70 * scale
        let gap: CGFloat = 26 * scale
        let totalW = CGFloat(shown.count) * avatar + CGFloat(shown.count - 1) * gap
        var x = (W - totalW) / 2
        let nameFont = NSFont.systemFont(ofSize: 17 * scale, weight: .medium)
        for p in shown {
            let rect = NSRect(x: x, y: baselineY, width: avatar, height: avatar)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            if let img = p.avatar, img.size.width > 0, img.size.height > 0 {
                let s = Swift.max(rect.width / img.size.width, rect.height / img.size.height)
                let dw = img.size.width * s, dh = img.size.height * s
                img.draw(in: NSRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
            } else {
                NSColor.systemBlue.withAlphaComponent(0.55).setFill(); NSBezierPath(ovalIn: rect).fill()
                let initials = p.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
                let f = NSFont.systemFont(ofSize: avatar * 0.4, weight: .semibold)
                let s = NSAttributedString(string: initials.isEmpty ? "?" : initials, attributes: [.font: f, .foregroundColor: NSColor.white])
                s.draw(at: NSPoint(x: rect.midX - s.size().width / 2, y: rect.midY - s.size().height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: rect); ring.lineWidth = 2.5 * scale; ring.stroke()
            let nameStr = NSAttributedString(string: p.name, attributes: [.font: nameFont, .foregroundColor: NSColor.white])
            nameStr.draw(at: NSPoint(x: rect.midX - nameStr.size().width / 2, y: rect.minY - 6 * scale - nameStr.size().height))
            x += avatar + gap
        }
    }

    private static func fitted(_ text: String, base: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat) -> NSAttributedString {
        var size = base
        var attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        if attr.size().width > maxWidth {
            size *= maxWidth / attr.size().width
            attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        return attr
    }

    // MARK: - Helpers bas niveau

    private static func card(width: Int, height: Int, draw: (CGFloat, CGFloat, CGFloat) -> Void) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(width), CGFloat(height), CGFloat(height) / 720.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?, width: Int, height: Int) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
