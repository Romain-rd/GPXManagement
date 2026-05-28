import Foundation
import MapKit
import AppKit
import GPXCore

public enum MapImageExportError: Error {
    case emptyRegion
    case contextFailure
    case encodingFailure
}

public enum MapImageExporter {
    private static let session = URLSession(configuration: .default)
    private static let maxTiles = 600

    /// Rend un PNG WYSIWYG de la zone visible : tuiles WMTS IGN (ou snapshot Apple) + traces dessinées.
    public static func renderPNG(
        layer: MapLayer,
        mapRect: MKMapRect,
        tracks: [TrackOverlayInput]
    ) async throws -> Data {
        guard mapRect.size.width > 0, mapRect.size.height > 0 else { throw MapImageExportError.emptyRegion }

        if layer.isIGN {
            return try await renderIGN(layer: layer, mapRect: mapRect, tracks: tracks)
        } else {
            return try await renderApple(layer: layer, mapRect: mapRect, tracks: tracks)
        }
    }

    // MARK: - IGN (composition de tuiles WMTS)

    private static func renderIGN(layer: MapLayer, mapRect: MKMapRect, tracks: [TrackOverlayInput]) async throws -> Data {
        let topLeft = MKMapPoint(x: mapRect.minX, y: mapRect.minY).coordinate
        let bottomRight = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate
        let topLat = topLeft.latitude, leftLon = topLeft.longitude
        let bottomLat = bottomRight.latitude, rightLon = bottomRight.longitude

        var lonSpan = rightLon - leftLon
        if lonSpan <= 0 { lonSpan = 0.0001 }

        // Zoom : viser ~ largeur visible en points écran traduite en tuiles, borné par la couche.
        let targetWidthPx = max(640.0, mapRect.size.width / 256.0 * 256.0) // placeholder; recalculé via tuiles
        _ = targetWidthPx
        var z = Int((log2(360.0 / lonSpan * 4.0)).rounded())
        z = min(max(z, 3), layer.maxZoom)

        // Réduire z si trop de tuiles.
        func tileRange(_ z: Int) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int, originX: Double, originY: Double) {
            let nw = project(lat: topLat, lon: leftLon, z: z)
            let se = project(lat: bottomLat, lon: rightLon, z: z)
            return (Int(floor(nw.x / 256)), Int(floor(se.x / 256)), Int(floor(nw.y / 256)), Int(floor(se.y / 256)), nw.x, nw.y)
        }
        while z > 3 {
            let r = tileRange(z)
            let count = (r.xMax - r.xMin + 1) * (r.yMax - r.yMin + 1)
            if count <= maxTiles { break }
            z -= 1
        }

        let r = tileRange(z)
        let widthPx = Int(ceil(project(lat: bottomLat, lon: rightLon, z: z).x - r.originX))
        let heightPx = Int(ceil(project(lat: bottomLat, lon: rightLon, z: z).y - r.originY))
        guard widthPx > 0, heightPx > 0 else { throw MapImageExportError.emptyRegion }

        guard let ctx = makeContext(width: widthPx, height: heightPx) else { throw MapImageExportError.contextFailure }
        // Fond
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        // Télécharger les tuiles en parallèle
        struct TilePos: Sendable { let x: Int; let y: Int }
        var positions: [TilePos] = []
        for ty in r.yMin...r.yMax {
            for tx in r.xMin...r.xMax {
                positions.append(TilePos(x: tx, y: ty))
            }
        }

        let images: [(TilePos, CGImage?)] = await withTaskGroup(of: (TilePos, CGImage?).self) { group in
            for pos in positions {
                let url = IGNTileOverlay.buildURL(
                    layerIdentifier: layer.wmtsLayerIdentifier!,
                    format: layer.wmtsFormat,
                    tileMatrixSet: layer.wmtsTileMatrixSet,
                    apiKey: layer.discoveryAPIKey,
                    z: z, x: pos.x, y: pos.y
                )
                group.addTask {
                    let img = await fetchImage(url: url)
                    return (pos, img)
                }
            }
            var out: [(TilePos, CGImage?)] = []
            for await result in group { out.append(result) }
            return out
        }

        // Dessiner les tuiles (origine CG en bas-gauche → flip vertical)
        for (pos, image) in images {
            guard let image else { continue }
            let px = Double(pos.x * 256) - r.originX
            let py = Double(pos.y * 256) - r.originY
            let rect = CGRect(x: px, y: Double(heightPx) - py - 256, width: 256, height: 256)
            ctx.draw(image, in: rect)
        }

        // Dessiner les traces
        drawTracks(tracks, in: ctx, heightPx: heightPx, originX: r.originX, originY: r.originY, z: z)

        guard let cgImage = ctx.makeImage() else { throw MapImageExportError.contextFailure }
        return try png(from: cgImage)
    }

    // MARK: - Apple (MKMapSnapshotter)

    private static func renderApple(layer: MapLayer, mapRect: MKMapRect, tracks: [TrackOverlayInput]) async throws -> Data {
        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect
        options.size = CGSize(width: min(2400, max(800, mapRect.size.width / 200)), height: min(2400, max(600, mapRect.size.height / 200)))
        options.showsBuildings = true
        switch layer {
        case .mapkitSatellite: options.mapType = .hybrid
        default:               options.mapType = .standard
        }

        let snapshot = try await MKMapSnapshotter(options: options).start()
        let size = snapshot.image.size
        guard let ctx = makeContext(width: Int(size.width), height: Int(size.height)) else { throw MapImageExportError.contextFailure }

        if let base = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(base, in: CGRect(origin: .zero, size: size))
        }

        drawTracksApple(tracks, in: ctx, snapshot: snapshot, height: size.height)

        guard let cgImage = ctx.makeImage() else { throw MapImageExportError.contextFailure }
        return try png(from: cgImage)
    }

    // MARK: - Tracé

    private static func resolvedColors(_ tracks: [TrackOverlayInput]) -> [NSColor] {
        let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
        let distinct = Set(nonEmpty.map(\.activityType))
        let useRotation = nonEmpty.count > 1 && distinct.count == 1
        return nonEmpty.enumerated().map { idx, t in
            useRotation ? MapTrackPalette.color(at: idx) : t.activityType.trackColor
        }
    }

    private static func drawTracks(_ tracks: [TrackOverlayInput], in ctx: CGContext, heightPx: Int, originX: Double, originY: Double, z: Int) {
        let colors = resolvedColors(tracks)
        let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
        ctx.setLineWidth(4)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for (idx, track) in nonEmpty.enumerated() {
            ctx.setStrokeColor(colors[idx].cgColor)
            var first = true
            ctx.beginPath()
            for coord in track.coordinates {
                let p = project(lat: coord.latitude, lon: coord.longitude, z: z)
                let x = p.x - originX
                let y = Double(heightPx) - (p.y - originY)
                if first { ctx.move(to: CGPoint(x: x, y: y)); first = false }
                else { ctx.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.strokePath()
        }
    }

    private static func drawTracksApple(_ tracks: [TrackOverlayInput], in ctx: CGContext, snapshot: MKMapSnapshotter.Snapshot, height: CGFloat) {
        let colors = resolvedColors(tracks)
        let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
        ctx.setLineWidth(4)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for (idx, track) in nonEmpty.enumerated() {
            ctx.setStrokeColor(colors[idx].cgColor)
            var first = true
            ctx.beginPath()
            for coord in track.coordinates {
                let pt = snapshot.point(for: coord)
                let flipped = CGPoint(x: pt.x, y: height - pt.y)
                if first { ctx.move(to: flipped); first = false }
                else { ctx.addLine(to: flipped) }
            }
            ctx.strokePath()
        }
    }

    // MARK: - Helpers

    private static func project(lat: Double, lon: Double, z: Int) -> (x: Double, y: Double) {
        let worldPx = 256.0 * pow(2.0, Double(z))
        let x = (lon + 180.0) / 360.0 * worldPx
        let sinLat = sin(lat * .pi / 180.0)
        let y = (0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)) * worldPx
        return (x, y)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func fetchImage(url: URL) async -> CGImage? {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } catch {
            return nil
        }
    }

    private static func png(from cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw MapImageExportError.encodingFailure
        }
        return data
    }
}
