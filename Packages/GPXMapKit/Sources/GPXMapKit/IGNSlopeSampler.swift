import Foundation
import AppKit
import CoreLocation

/// Bande de pente du terrain selon la couche IGN `SLOPES.MOUNTAIN` (référentiel avalanche).
/// `< 30°` est rendu transparent par IGN → pas de coloration (couleur normale de la trace).
public enum SlopeBand: Sendable, Equatable {
    case below30, d30_35, d35_40, d40_45, above45

    public var color: NSColor? {
        switch self {
        case .below30: return nil
        case .d30_35:  return NSColor(srgbRed: 245/255, green: 231/255, blue: 0/255,   alpha: 1) // jaune
        case .d35_40:  return NSColor(srgbRed: 247/255, green: 165/255, blue: 30/255,  alpha: 1) // orange
        case .d40_45:  return NSColor(srgbRed: 240/255, green: 35/255,  blue: 0/255,   alpha: 1) // rouge
        case .above45: return NSColor(srgbRed: 200/255, green: 110/255, blue: 200/255, alpha: 1) // violet
        }
    }

    public var label: String {
        switch self {
        case .below30: return "< 30°"
        case .d30_35:  return "30–35°"
        case .d35_40:  return "35–40°"
        case .d40_45:  return "40–45°"
        case .above45: return "> 45°"
        }
    }

    /// Classe un pixel RGBA (0–255) de la tuile IGN. Transparent ⇒ `< 30°` ; sinon plus proche couleur de la palette.
    public static func classify(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> SlopeBand {
        if a < 64 { return .below30 }
        let refs: [(band: SlopeBand, r: Double, g: Double, b: Double)] = [
            (.d30_35, 245, 231, 0),
            (.d35_40, 247, 165, 30),
            (.d40_45, 240, 35, 0),
            (.above45, 211, 158, 199)
        ]
        var best = SlopeBand.below30
        var bestDist = Double.greatestFiniteMagnitude
        for ref in refs {
            let d = pow(Double(r) - ref.r, 2) + pow(Double(g) - ref.g, 2) + pow(Double(b) - ref.b, 2)
            if d < bestDist { bestDist = d; best = ref.band }
        }
        return best
    }
}

/// Échantillonne la pente du terrain le long d'une trace en lisant la couche IGN `SLOPES.MOUNTAIN`.
/// Les tuiles décodées sont mises en cache (mémoire + disque via URLCache).
public actor IGNSlopeSampler {
    public static let shared = IGNSlopeSampler()

    private let session: URLSession
    private var tileCache: [String: [UInt8]] = [:] // "z/x/y" → RGBA 256×256 (origine haut-gauche) ; [] = échec/transparent

    public init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "GPXManagement/1.0 (macOS; com.demoustier.GPXManagement)"]
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    /// Bande de pente pour chaque coordonnée (même ordre, même cardinalité que `coordinates`).
    public func bands(for coordinates: [CLLocationCoordinate2D], zoom: Int = 16) async -> [SlopeBand] {
        guard !coordinates.isEmpty else { return [] }

        struct Loc { let key: String; let z: Int; let tx: Int; let ty: Int; let px: Int; let py: Int }
        var locs: [Loc] = []
        locs.reserveCapacity(coordinates.count)
        var needed: Set<String> = []
        for c in coordinates {
            let (wx, wy) = WebMercator.pixel(lat: c.latitude, lon: c.longitude, z: zoom)
            let tx = Int(wx / 256), ty = Int(wy / 256)
            let px = min(255, max(0, Int(wx) - tx * 256))
            let py = min(255, max(0, Int(wy) - ty * 256))
            let key = "\(zoom)/\(tx)/\(ty)"
            locs.append(Loc(key: key, z: zoom, tx: tx, ty: ty, px: px, py: py))
            needed.insert(key)
        }

        for key in needed where tileCache[key] == nil {
            let parts = key.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { tileCache[key] = []; continue }
            tileCache[key] = await fetchTileRGBA(z: parts[0], x: parts[1], y: parts[2]) ?? []
        }

        return locs.map { loc in
            guard let buf = tileCache[loc.key], buf.count == 256 * 256 * 4 else { return .below30 }
            let idx = (loc.py * 256 + loc.px) * 4
            return SlopeBand.classify(r: buf[idx], g: buf[idx + 1], b: buf[idx + 2], a: buf[idx + 3])
        }
    }

    private func fetchTileRGBA(z: Int, x: Int, y: Int) async -> [UInt8]? {
        let url = IGNTileOverlay.buildURL(layerIdentifier: "GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN", format: "image/png", z: z, x: x, y: y)
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rep = NSBitmapImageRep(data: data),
              let cg = rep.cgImage else { return nil }
        return Self.rgbaBuffer(from: cg)
    }

    /// Rend l'image dans un tampon RGBA 256×256 à origine **haut-gauche** (ligne 0 = haut), comme le schéma de tuiles.
    private static func rgbaBuffer(from cg: CGImage) -> [UInt8]? {
        let w = 256, h = 256
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext a l'origine en bas-gauche : on retourne verticalement pour obtenir un tampon haut-gauche.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return buf
    }
}
