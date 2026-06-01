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
    // Les fournisseurs de tuiles (OpenStreetMap/OpenTopoMap, IGN) exigent un User-Agent identifiant
    // et limitent le débit : sans cela OpenTopoMap renvoie 403, et le téléchargement massif déclenche des 429.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "GPXManagement/1.0 (macOS; com.demoustier.GPXManagement)"
        ]
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    private static let maxTiles = 1200

    public struct Progress: Sendable {
        public let fraction: Double
        public let label: String
    }

    /// Rend un PNG WYSIWYG de la zone visible : tuiles WMTS IGN (ou snapshot Apple) + traces dessinées.
    public static func renderPNG(
        layer: MapLayer,
        mapRect: MKMapRect,
        tracks: [TrackOverlayInput],
        maxDimension: Int? = nil,
        trackColor: NSColor? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Data {
        guard mapRect.size.width > 0, mapRect.size.height > 0 else { throw MapImageExportError.emptyRegion }

        if let template = layer.tileURLTemplate {
            return try await renderTiledMap(maxZoom: layer.maxZoom, maxConcurrent: layer.maxConcurrentTileRequests, attribution: layer.attribution, mapRect: mapRect, tracks: tracks, maxDimension: maxDimension, trackColor: trackColor, onProgress: onProgress) { z, x, y in
                templateURL(template, z: z, x: x, y: y)
            }
        } else if layer.isIGN {
            return try await renderTiledMap(maxZoom: layer.maxZoom, maxConcurrent: layer.maxConcurrentTileRequests, attribution: layer.attribution, mapRect: mapRect, tracks: tracks, maxDimension: maxDimension, trackColor: trackColor, onProgress: onProgress) { z, x, y in
                IGNTileOverlay.buildURL(layerIdentifier: layer.wmtsLayerIdentifier!, format: layer.wmtsFormat,
                                        tileMatrixSet: layer.wmtsTileMatrixSet, apiKey: layer.discoveryAPIKey, z: z, x: x, y: y)
            }
        } else {
            return try await renderApple(layer: layer, mapRect: mapRect, tracks: tracks, maxDimension: maxDimension, trackColor: trackColor, onProgress: onProgress)
        }
    }

    private static func templateURL(_ template: String, z: Int, x: Int, y: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    // MARK: - Composition de tuiles XYZ/WMTS

    private static func renderTiledMap(maxZoom: Int, maxConcurrent: Int, attribution: String?, mapRect: MKMapRect, tracks: [TrackOverlayInput], maxDimension: Int?, trackColor: NSColor?, onProgress: (@Sendable (Progress) -> Void)?, urlFor: @Sendable @escaping (Int, Int, Int) -> URL?) async throws -> Data {
        let topLeft = MKMapPoint(x: mapRect.minX, y: mapRect.minY).coordinate
        let bottomRight = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate
        let topLat = topLeft.latitude, leftLon = topLeft.longitude
        let bottomLat = bottomRight.latitude, rightLon = bottomRight.longitude

        func tileRange(_ z: Int) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int, originX: Double, originY: Double) {
            let nw = project(lat: topLat, lon: leftLon, z: z)
            let se = project(lat: bottomLat, lon: rightLon, z: z)
            return (Int(floor(nw.x / 256)), Int(floor(se.x / 256)), Int(floor(nw.y / 256)), Int(floor(se.y / 256)), nw.x, nw.y)
        }

        // On part du zoom le plus détaillé puis on redescend tant que (a) le nombre de tuiles dépasse
        // le budget, ou (b) l'image dépasserait nettement la résolution de sortie demandée. Le point (b)
        // est crucial pour la vidéo : inutile (et nuisible vis-à-vis du rate limit) de télécharger des
        // milliers de tuiles pour produire une image de ~1280 px ensuite réduite.
        var z = maxZoom
        while z > 3 {
            let r = tileRange(z)
            let count = (r.xMax - r.xMin + 1) * (r.yMax - r.yMin + 1)
            let se = project(lat: bottomLat, lon: rightLon, z: z)
            let wPx = se.x - r.originX, hPx = se.y - r.originY
            let pixelOK = maxDimension == nil || Swift.max(wPx, hPx) <= Double(maxDimension!) * 1.4
            if count <= maxTiles && pixelOK { break }
            z -= 1
        }

        let r = tileRange(z)
        let widthPx = Int(ceil(project(lat: bottomLat, lon: rightLon, z: z).x - r.originX))
        let heightPx = Int(ceil(project(lat: bottomLat, lon: rightLon, z: z).y - r.originY))
        guard widthPx > 0, heightPx > 0 else { throw MapImageExportError.emptyRegion }

        // Réduction éventuelle (export PDF) : on compose à la résolution des tuiles, puis on réduit.
        // L'épaisseur du tracé est augmentée d'autant pour rester visible après réduction.
        let outputScale: Double = {
            guard let maxDimension, max(widthPx, heightPx) > maxDimension else { return 1 }
            return Double(maxDimension) / Double(max(widthPx, heightPx))
        }()
        let lineWidth = 4.0 / outputScale

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

        let total = positions.count
        onProgress?(Progress(fraction: 0, label: "Téléchargement des tuiles 0/\(total)…"))

        // Concurrence bornée : on ne lance qu'un nombre limité de requêtes simultanées (faible pour
        // les couches OSM/OpenTopoMap qui bannissent les rafales), avec retry/backoff sur 429.
        let limit = Swift.max(1, Swift.min(maxConcurrent, total))
        var images: [(TilePos, CGImage?)] = []
        images.reserveCapacity(total)
        await withTaskGroup(of: (TilePos, CGImage?).self) { group in
            var next = 0
            func submit() {
                guard next < positions.count else { return }
                let pos = positions[next]; next += 1
                let url = urlFor(z, pos.x, pos.y)
                group.addTask {
                    guard let url else { return (pos, nil) }
                    return (pos, await fetchImage(url: url))
                }
            }
            for _ in 0..<limit { submit() }
            while let result = await group.next() {
                images.append(result)
                onProgress?(Progress(fraction: Double(images.count) / Double(total) * 0.9, label: "Téléchargement des tuiles \(images.count)/\(total)…"))
                submit()
            }
        }

        onProgress?(Progress(fraction: 0.93, label: "Composition de l'image…"))

        // Dessiner les tuiles (origine CG en bas-gauche → flip vertical)
        for (pos, image) in images {
            guard let image else { continue }
            let px = Double(pos.x * 256) - r.originX
            let py = Double(pos.y * 256) - r.originY
            let rect = CGRect(x: px, y: Double(heightPx) - py - 256, width: 256, height: 256)
            ctx.draw(image, in: rect)
        }

        // Dessiner les traces
        drawTracks(tracks, in: ctx, heightPx: heightPx, originX: r.originX, originY: r.originY, z: z, lineWidth: lineWidth, override: trackColor)
        drawAttribution(attribution, in: ctx, width: widthPx, height: heightPx)

        onProgress?(Progress(fraction: 0.98, label: "Encodage du PNG…"))
        guard let cgImage = ctx.makeImage() else { throw MapImageExportError.contextFailure }
        return try png(from: downscale(cgImage, scale: outputScale))
    }

    private static func drawAttribution(_ text: String?, in ctx: CGContext, width: Int, height: Int) {
        guard let text, !text.isEmpty else { return }
        let fontSize = max(11.0, Double(height) / 55.0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pad = fontSize * 0.5
        let box = CGRect(x: Double(width) - size.width - pad * 2 - 4, y: 4, width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        s.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func downscale(_ image: CGImage, scale: Double) -> CGImage {
        guard scale < 1 else { return image }
        let outW = max(1, Int((Double(image.width) * scale).rounded()))
        let outH = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = makeContext(width: outW, height: outH) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? image
    }

    // MARK: - Apple (MKMapSnapshotter)

    private static func renderApple(layer: MapLayer, mapRect: MKMapRect, tracks: [TrackOverlayInput], maxDimension: Int?, trackColor: NSColor?, onProgress: (@Sendable (Progress) -> Void)?) async throws -> Data {
        onProgress?(Progress(fraction: 0.2, label: "Capture de la carte…"))
        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect
        // La taille DOIT conserver le ratio du mapRect : sinon MKMapSnapshotter élargit la région
        // pour remplir l'image, ce qui décale la trace projetée par l'appelant (cadrage faux).
        let longSide = max(1200.0, min(Double(maxDimension ?? 2400), 2400.0))
        let aspect = mapRect.size.width / mapRect.size.height
        options.size = aspect >= 1
            ? CGSize(width: longSide, height: longSide / aspect)
            : CGSize(width: longSide * aspect, height: longSide)
        options.showsBuildings = true
        switch layer {
        case .mapkitSatellite: options.mapType = .hybrid
        default:               options.mapType = .standard
        }

        let snapshot = try await MKMapSnapshotter(options: options).start()
        onProgress?(Progress(fraction: 0.9, label: "Composition de l'image…"))
        let size = snapshot.image.size
        guard let ctx = makeContext(width: Int(size.width), height: Int(size.height)) else { throw MapImageExportError.contextFailure }

        if let base = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(base, in: CGRect(origin: .zero, size: size))
        }

        drawTracksApple(tracks, in: ctx, snapshot: snapshot, height: size.height, override: trackColor)
        drawAttribution(layer.attribution, in: ctx, width: Int(size.width), height: Int(size.height))

        guard let cgImage = ctx.makeImage() else { throw MapImageExportError.contextFailure }
        return try png(from: cgImage)
    }

    // MARK: - Tracé

    private static func resolvedColors(_ tracks: [TrackOverlayInput], override: NSColor?) -> [NSColor] {
        let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
        if let override { return nonEmpty.map { _ in override } }
        let distinct = Set(nonEmpty.map(\.activityType))
        let useRotation = nonEmpty.count > 1 && distinct.count == 1
        return nonEmpty.enumerated().map { idx, t in
            useRotation ? MapTrackPalette.color(at: idx) : t.activityType.trackColor
        }
    }

    private static func drawTracks(_ tracks: [TrackOverlayInput], in ctx: CGContext, heightPx: Int, originX: Double, originY: Double, z: Int, lineWidth: Double = 4, override: NSColor? = nil) {
        let colors = resolvedColors(tracks, override: override)
        let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        func stroke(_ track: TrackOverlayInput) {
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

        // Liseré blanc (casing) sous chaque trace → lisible sur tout fond.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(lineWidth * 1.9)
        for track in nonEmpty { stroke(track) }

        ctx.setLineWidth(lineWidth)
        for (idx, track) in nonEmpty.enumerated() {
            ctx.setStrokeColor(colors[idx].cgColor)
            stroke(track)
        }
    }

    private static func drawTracksApple(_ tracks: [TrackOverlayInput], in ctx: CGContext, snapshot: MKMapSnapshotter.Snapshot, height: CGFloat, override: NSColor? = nil) {
        let colors = resolvedColors(tracks, override: override)
        let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        func stroke(_ track: TrackOverlayInput) {
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

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(4 * 1.9)
        for track in nonEmpty { stroke(track) }

        ctx.setLineWidth(4)
        for (idx, track) in nonEmpty.enumerated() {
            ctx.setStrokeColor(colors[idx].cgColor)
            stroke(track)
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

    private static func fetchImage(url: URL, retries: Int = 3) async -> CGImage? {
        for attempt in 0...retries {
            do {
                let (data, response) = try await session.data(from: url)
                let http = response as? HTTPURLResponse
                switch http?.statusCode ?? 0 {
                case 200:
                    return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                case 429, 500, 502, 503, 504:
                    guard attempt < retries else { return nil }
                    let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let delay = retryAfter ?? Double(1 << attempt) * 0.4
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                default:
                    return nil
                }
            } catch {
                guard attempt < retries else { return nil }
                try? await Task.sleep(nanoseconds: UInt64(Double(1 << attempt) * 0.3 * 1_000_000_000))
            }
        }
        return nil
    }

    private static func png(from cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw MapImageExportError.encodingFailure
        }
        return data
    }
}
