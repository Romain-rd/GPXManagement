import SwiftUI
import Charts
import AppKit
import MapKit
import Photos
import GPXCore
import GPXMapKit

struct WebExportOptions {
    enum MapRendering: String, CaseIterable, Identifiable {
        case staticImage, interactive
        var id: String { rawValue }
        var label: String { self == .staticImage ? "Image statique" : "Carte interactive" }
    }
    enum ProfileRendering: String, CaseIterable, Identifiable {
        case staticImage, interactive
        var id: String { rawValue }
        var label: String { self == .staticImage ? "Image statique" : "Graphique interactif" }
    }
    enum Output: String, CaseIterable, Identifiable {
        case singleFile, folder
        var id: String { rawValue }
        var label: String { self == .singleFile ? "Fichier HTML unique" : "Dossier (HTML + images)" }
    }

    var map: MapRendering = .staticImage
    var profile: ProfileRendering = .staticImage
    var output: Output = .singleFile
    var includePhotos: Bool = true
}

enum HTMLReportError: Error, LocalizedError {
    case noTrackData
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noTrackData:  return "Cette activité ne contient pas de trace."
        case .renderFailed: return "Échec de la génération de la page web."
        }
    }
}

@MainActor
enum HTMLReportRenderer {
    enum Output {
        case singleFile(html: Data)
        case folder(files: [String: Data]) // contient "index.html"
    }

    static func render(activity: ActivitySummary, repository: CoreDataActivityRepository, layer: MapLayer, options: WebExportOptions, photos: [PHAsset]) async throws -> Output {
        guard let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty else {
            throw HTMLReportError.noTrackData
        }
        let points = try TrackPointCodec.decode(data)

        var mapPNG: Data?
        if options.map == .staticImage, let bounds = PDFReportRenderer.boundingMapRect(points) {
            let mapRect = framedMapRect(bounds, aspect: mapAspect)
            let overlay = TrackOverlayInput(activityId: activity.id, activityType: activity.activityType, coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
            mapPNG = try? await MapImageExporter.renderPNG(layer: layer, mapRect: mapRect, tracks: [overlay], maxDimension: 2000, trackColor: activity.activityType.trackColor)
        }
        let trackCoords = options.map == .interactive ? decimatedCoords(points, max: 2000) : []

        let profile = ElevationProfileBuilder.build(points: points)
        let (distanceSamples, distanceScale) = PDFReportRenderer.slopeRuns(from: profile)
        let timeProfile = PDFReportRenderer.movementRuns(from: profile)
        let movement = ElevationProfileBuilder.movementTime(profile)

        var distancePNG: Data?
        if !distanceSamples.isEmpty {
            distancePNG = renderChartPNG(HTMLDistanceChart(samples: distanceSamples, scale: distanceScale), size: CGSize(width: 1000, height: 300))
        }
        var timePNG: Data?
        if timeProfile.available {
            timePNG = renderChartPNG(HTMLTimeChart(time: timeProfile), size: CGSize(width: 1000, height: 300))
        }

        var photoJPEGs: [Data] = []
        if options.includePhotos {
            for asset in photos {
                if let image = await PhotoLibraryService.fullImage(for: asset), let jpeg = image.jpeg(quality: 0.82) {
                    photoJPEGs.append(jpeg)
                }
            }
        }

        let assets = HTMLAssets(map: mapPNG, distanceProfile: distancePNG, timeProfile: timePNG, photos: photoJPEGs)
        let html = buildHTML(activity: activity, assets: assets, options: options,
                             slopeLegend: slopeLegendItems(distanceScale: distanceScale),
                             movement: movement, hasHeartRate: !timeProfile.hr.isEmpty,
                             layer: layer, trackCoords: trackCoords)

        switch options.output {
        case .singleFile:
            guard let data = html.data(using: .utf8) else { throw HTMLReportError.renderFailed }
            return .singleFile(html: data)
        case .folder:
            var files: [String: Data] = ["index.html": html.data(using: .utf8) ?? Data()]
            if let map = mapPNG { files["images/carte.png"] = map }
            if let d = distancePNG { files["images/profil-distance.png"] = d }
            if let t = timePNG { files["images/profil-temps.png"] = t }
            for (i, jpeg) in photoJPEGs.enumerated() { files["images/photo-\(i + 1).jpg"] = jpeg }
            return .folder(files: files)
        }
    }

    // MARK: - Carte

    private static let mapAspect: Double = 16.0 / 10.0

    /// Élargit le rectangle du tracé à un format paysage : le parcours reste centré avec du contexte
    /// autour, l'image est nette (le côté large reçoit le maximum de pixels) plutôt que sur-zoomée.
    private static func framedMapRect(_ rect: MKMapRect, aspect: Double) -> MKMapRect {
        guard rect.size.width > 0, rect.size.height > 0 else { return rect }
        let current = rect.size.width / rect.size.height
        if current < aspect {
            let newWidth = rect.size.height * aspect
            let dx = (newWidth - rect.size.width) / 2
            return MKMapRect(x: rect.origin.x - dx, y: rect.origin.y, width: newWidth, height: rect.size.height)
        } else {
            let newHeight = rect.size.width / aspect
            let dy = (newHeight - rect.size.height) / 2
            return MKMapRect(x: rect.origin.x, y: rect.origin.y - dy, width: rect.size.width, height: newHeight)
        }
    }

    private static func decimatedCoords(_ points: [TrackPoint], max: Int) -> [(lat: Double, lon: Double)] {
        guard points.count > max else { return points.map { ($0.latitude, $0.longitude) } }
        let step = Double(points.count) / Double(max)
        var out = (0..<max).map { i -> (Double, Double) in let p = points[Int(Double(i) * step)]; return (p.latitude, p.longitude) }
        if let last = points.last { out.append((last.latitude, last.longitude)) }
        return out
    }

    /// Gabarit de tuiles {z}/{x}/{y} pour Leaflet, dérivé de la couche choisie.
    /// IGN WMTS répliqué depuis les paramètres publics ; fallback web pour les couches Apple (sans équivalent tuiles).
    private struct WebTileLayer { let urlTemplate: String; let maxZoom: Int; let attribution: String }

    private static func webTileLayer(for layer: MapLayer) -> WebTileLayer {
        if layer.isIGN, let identifier = layer.wmtsLayerIdentifier {
            let endpoint = layer.discoveryAPIKey == nil ? "https://data.geopf.fr/wmts" : "https://data.geopf.fr/private/wmts"
            var query = ""
            if let key = layer.discoveryAPIKey { query += "apikey=\(key)&" }
            query += "SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=\(identifier)&STYLE=normal"
            query += "&FORMAT=\(layer.wmtsFormat)&TILEMATRIXSET=\(layer.wmtsTileMatrixSet)&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}"
            return WebTileLayer(urlTemplate: "\(endpoint)?\(query)", maxZoom: layer.maxZoom, attribution: layer.attribution ?? "© IGN-F / Géoportail")
        }
        if let template = layer.tileURLTemplate {
            return WebTileLayer(urlTemplate: template, maxZoom: layer.maxZoom, attribution: layer.attribution ?? "")
        }
        // Couches Apple : pas de tuiles web → repli (satellite → Esri, sinon OSM).
        if layer == .mapkitSatellite {
            return WebTileLayer(urlTemplate: MapLayer.esriImagery.tileURLTemplate ?? "", maxZoom: MapLayer.esriImagery.maxZoom, attribution: MapLayer.esriImagery.attribution ?? "")
        }
        return WebTileLayer(urlTemplate: MapLayer.osm.tileURLTemplate ?? "", maxZoom: MapLayer.osm.maxZoom, attribution: MapLayer.osm.attribution ?? "")
    }

    // MARK: - Rendu d'images

    private static func renderChartPNG(_ view: some View, size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    // MARK: - Construction du HTML

    private struct HTMLAssets {
        let map: Data?
        let distanceProfile: Data?
        let timeProfile: Data?
        let photos: [Data]
    }

    private struct LegendItem { let label: String; let color: String }

    private static func slopeLegendItems(distanceScale: [String: Color]) -> [LegendItem] {
        guard !distanceScale.isEmpty else { return [] }
        let cats: [SlopeCategory] = [.gentle, .moderate, .steep, .veryStep, .descent]
        return cats.map { LegendItem(label: $0.label, color: hex($0.color)) }
    }

    private static func buildHTML(activity: ActivitySummary, assets: HTMLAssets, options: WebExportOptions, slopeLegend: [LegendItem], movement: (moving: TimeInterval, paused: TimeInterval), hasHeartRate: Bool, layer: MapLayer, trackCoords: [(lat: Double, lon: Double)]) -> String {
        let accent = hex(activity.activityType.trackColor)
        let inline = options.output == .singleFile
        let interactiveMap = options.map == .interactive && !trackCoords.isEmpty

        func imgTag(_ data: Data?, file: String, mime: String, alt: String, cssClass: String) -> String {
            guard let data else { return "" }
            let src = inline ? "data:\(mime);base64,\(data.base64EncodedString())" : file
            return "<img class=\"\(cssClass)\" src=\"\(src)\" alt=\"\(esc(alt))\" loading=\"lazy\">"
        }

        // En-tête
        let tagsHTML = activity.tags.isEmpty ? "" :
            "<div class=\"tags\">" + activity.tags.map { "<span class=\"tag\">\(esc($0))</span>" }.joined() + "</div>"

        // Métriques
        var cards: [String] = [
            metricCard("Distance", fmtDistance(activity.distance)),
            metricCard("Dénivelé +", "\(Int(activity.elevationGain.rounded())) m"),
            metricCard("Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m"),
            metricCard("Durée totale", fmtDuration(activity.duration)),
            metricCard("En mouvement", fmtDuration(activity.movingDuration)),
            metricCard("Vitesse moy.", fmtSpeed(activity.avgSpeed)),
            metricCard("Vitesse max", fmtSpeed(activity.maxSpeed))
        ]
        if let hr = activity.avgHeartRate { cards.append(metricCard("FC moyenne", "\(Int(hr.rounded())) bpm")) }
        if let hr = activity.maxHeartRate { cards.append(metricCard("FC max", "\(Int(hr.rounded())) bpm")) }

        // Profils
        var profileSection = ""
        let distanceImg = imgTag(assets.distanceProfile, file: "images/profil-distance.png", mime: "image/png", alt: "Profil distance / pente", cssClass: "chart")
        let timeImg = imgTag(assets.timeProfile, file: "images/profil-temps.png", mime: "image/png", alt: "Profil temps / mouvement", cssClass: "chart")
        if !distanceImg.isEmpty || !timeImg.isEmpty {
            var blocks = ""
            if !distanceImg.isEmpty {
                let legend = slopeLegend.map { "<span class=\"li\"><i style=\"background:\($0.color)\"></i>\(esc($0.label))</span>" }.joined()
                blocks += "<div class=\"chart-block\"><h3>Distance / pente</h3>\(distanceImg)<div class=\"legend\">\(legend)</div></div>"
            }
            if !timeImg.isEmpty {
                let total = movement.moving + movement.paused
                func pct(_ t: TimeInterval) -> String { total > 0 ? " (\(Int((t / total * 100).rounded())) %)" : "" }
                var legend = "<span class=\"li\"><i style=\"background:#34c759\"></i>En mouvement : \(esc(fmtDuration(movement.moving)))\(pct(movement.moving))</span>"
                legend += "<span class=\"li\"><i style=\"background:#8e8e93\"></i>Pause : \(esc(fmtDuration(movement.paused)))\(pct(movement.paused))</span>"
                if hasHeartRate { legend += "<span class=\"li\"><i style=\"background:#ff3b30\"></i>Fréquence cardiaque</span>" }
                blocks += "<div class=\"chart-block\"><h3>Temps / mouvement</h3>\(timeImg)<div class=\"legend\">\(legend)</div></div>"
            }
            profileSection = "<section class=\"section\"><h2>Profil altimétrique</h2>\(blocks)</section>"
        }

        // Carte (statique ou interactive Leaflet)
        var mapSection = ""
        var mapScript = ""
        if interactiveMap {
            let tile = webTileLayer(for: layer)
            let coordsJSON = "[" + trackCoords.map { String(format: "[%.6f,%.6f]", $0.lat, $0.lon) }.joined(separator: ",") + "]"
            mapSection = "<section class=\"section\"><h2>Carte</h2><div id=\"map\" class=\"map interactive\"></div></section>"
            mapScript = """
            <script>
            (function(){
              var coords = \(coordsJSON);
              var map = L.map('map', { scrollWheelZoom: false });
              L.tileLayer(\(jsString(tile.urlTemplate)), { maxZoom: \(tile.maxZoom), attribution: \(jsString(tile.attribution)) }).addTo(map);
              var line = L.polyline(coords, { color: \(jsString(accent)), weight: 4, opacity: 0.9 }).addTo(map);
              map.fitBounds(line.getBounds(), { padding: [24, 24] });
              L.circleMarker(coords[0], { radius: 6, color: '#fff', weight: 2, fillColor: '#34c759', fillOpacity: 1 }).addTo(map);
              L.circleMarker(coords[coords.length - 1], { radius: 6, color: '#fff', weight: 2, fillColor: '#ff3b30', fillOpacity: 1 }).addTo(map);
            })();
            </script>
            """
        } else {
            let mapImg = imgTag(assets.map, file: "images/carte.png", mime: "image/png", alt: "Carte du parcours", cssClass: "map")
            if !mapImg.isEmpty {
                let credit = layer.attribution.map { "<p class=\"credit\">\(esc($0))</p>" } ?? ""
                mapSection = "<section class=\"section\"><h2>Carte</h2>\(mapImg)\(credit)</section>"
            }
        }

        // Photos
        var photosSection = ""
        if !assets.photos.isEmpty {
            let grid = assets.photos.enumerated().map { i, data in
                imgTag(data, file: "images/photo-\(i + 1).jpg", mime: "image/jpeg", alt: "Photo \(i + 1)", cssClass: "photo")
            }.joined()
            photosSection = "<section class=\"section\"><h2>Photos</h2><div class=\"photos\">\(grid)</div></section>"
        }

        // Notes + source
        var notesSection = ""
        if let notes = activity.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            notesSection = "<section class=\"section\"><h2>Notes</h2><p class=\"notes\">\(nl2br(notes))</p></section>"
        }
        let sourceLine = "<p class=\"source\">\(esc(sourceText(activity))) · Fichier : \(esc(activity.sourceFileFormat.rawValue.uppercased())) \(esc(activity.sourceFileName))</p>"

        let leafletHead = interactiveMap ? """
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css">
        <script src="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"></script>
        """ : ""

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(activity.title))</title>
        \(leafletHead)
        <style>\(css(accent: accent))</style>
        </head>
        <body>
        <main class="page">
          <header class="hero">
            <div class="badge"></div>
            <div class="hero-text">
              <h1>\(esc(activity.title))</h1>
              <p class="subtitle">\(esc(activity.activityType.displayName)) · \(esc(fmtDate(activity.startDate)))</p>
              \(tagsHTML)
            </div>
          </header>
          <section class="metrics">\(cards.joined())</section>
          \(profileSection)
          \(mapSection)
          \(photosSection)
          \(notesSection)
          <footer>\(sourceLine)<p class="madeby">Généré par GPXManagement</p></footer>
        </main>
        \(mapScript)
        </body>
        </html>
        """
    }

    private static func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func metricCard(_ label: String, _ value: String) -> String {
        "<div class=\"card\"><span class=\"v\">\(esc(value))</span><span class=\"l\">\(esc(label))</span></div>"
    }

    private static func css(accent: String) -> String {
        """
        :root { --accent: \(accent); --bg: #f5f5f7; --fg: #1d1d1f; --sec: #6e6e73; --card: #ffffff; --line: #e3e3e6; }
        @media (prefers-color-scheme: dark) { :root { --bg:#1c1c1e; --fg:#f5f5f7; --sec:#9a9a9e; --card:#2c2c2e; --line:#3a3a3c; } }
        * { box-sizing: border-box; }
        body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
        .page { max-width: 960px; margin: 0 auto; padding: 28px 20px 48px; }
        .hero { display:flex; gap:16px; align-items:center; margin-bottom:24px; }
        .badge { width:54px; height:54px; border-radius:50%; background:var(--accent); flex:0 0 auto; }
        .hero h1 { margin:0; font-size:30px; font-weight:700; letter-spacing:-0.02em; }
        .subtitle { margin:4px 0 0; color:var(--sec); }
        .tags { margin-top:8px; display:flex; flex-wrap:wrap; gap:6px; }
        .tag { font-size:12px; padding:3px 9px; border-radius:999px; background:var(--line); color:var(--sec); }
        .metrics { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:12px; margin-bottom:8px; }
        .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px 16px; display:flex; flex-direction:column; gap:2px; }
        .card .v { font-size:22px; font-weight:700; }
        .card .l { font-size:13px; color:var(--sec); }
        .section { margin-top:32px; }
        .section h2 { font-size:13px; text-transform:uppercase; letter-spacing:0.06em; color:var(--sec); margin:0 0 12px; }
        .section h3 { font-size:15px; font-weight:600; margin:18px 0 8px; }
        .map { width:100%; aspect-ratio:16/10; object-fit:cover; border-radius:14px; border:1px solid var(--line); display:block; background:var(--card); }
        .map.interactive { overflow:hidden; z-index:0; }
        .leaflet-container { background:var(--card); font:inherit; }
        .chart { width:100%; height:auto; border-radius:14px; border:1px solid var(--line); display:block; background:var(--card); }
        .credit { font-size:11px; color:var(--sec); margin:6px 0 0; }
        .chart-block { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px 16px; margin-bottom:14px; }
        .chart-block h3 { margin-top:0; }
        .legend { display:flex; flex-wrap:wrap; gap:14px; margin-top:8px; font-size:12px; color:var(--sec); }
        .legend .li { display:inline-flex; align-items:center; gap:5px; }
        .legend i { width:11px; height:11px; border-radius:3px; display:inline-block; }
        .photos { display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:10px; }
        .photo { width:100%; aspect-ratio:1; object-fit:cover; border-radius:12px; border:1px solid var(--line); }
        .notes { white-space:normal; background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px 16px; margin:0; }
        footer { margin-top:40px; padding-top:16px; border-top:1px solid var(--line); color:var(--sec); font-size:12px; }
        footer p { margin:2px 0; }
        .madeby { color:var(--accent); font-weight:600; }
        """
    }

    // MARK: - Helpers de formatage

    private static func sourceText(_ activity: ActivitySummary) -> String {
        let category = activity.source.displayName
        if let raw = activity.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw != category {
            return "Source : \(category) · \(raw)"
        }
        return "Source : \(category)"
    }

    private static func hex(_ color: Color) -> String { hex(NSColor(color)) }
    private static func hex(_ nsColor: NSColor) -> String {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func nl2br(_ s: String) -> String { esc(s).replacingOccurrences(of: "\n", with: "<br>") }

    private static func fmtDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .long; f.timeStyle = .short
        return f.string(from: d)
    }
    private static func fmtDistance(_ m: Double) -> String { m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m" }
    private static func fmtDuration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, sec)
    }
    private static func fmtSpeed(_ mps: Double) -> String { String(format: "%.1f km/h", mps * 3.6) }
}

// MARK: - Graphiques (rendus en image pour la page)

private struct HTMLDistanceChart: View {
    let samples: [ProfileChartSample]
    let scale: [String: Color]
    var body: some View {
        Chart(samples) { s in
            AreaMark(x: .value("km", s.x), y: .value("m", s.altitude), stacking: .unstacked)
                .foregroundStyle(by: .value("Segment", s.runKey))
                .opacity(0.75)
        }
        .chartForegroundStyleScale(domain: Array(scale.keys), range: Array(scale.keys).map { scale[$0] ?? .clear })
        .chartLegend(.hidden)
        .chartXAxisLabel("Distance (km)")
        .chartYAxisLabel("Altitude (m)")
        .padding(14)
        .background(Color.white)
    }
}

private struct HTMLTimeChart: View {
    let time: PDFTimeProfile
    var body: some View {
        Chart {
            ForEach(time.samples) { s in
                AreaMark(x: .value("t", s.x), y: .value("m", s.altitude), stacking: .unstacked)
                    .foregroundStyle(by: .value("Segment", s.runKey))
                    .opacity(0.75)
            }
            ForEach(time.hr) { p in
                LineMark(x: .value("t", p.x), y: .value("FC", p.plotY), series: .value("s", "hr"))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
        }
        .chartForegroundStyleScale(domain: Array(time.scale.keys), range: Array(time.scale.keys).map { time.scale[$0] ?? .clear })
        .chartLegend(.hidden)
        .chartXAxisLabel(time.axisLabel)
        .chartYAxisLabel("Altitude (m)")
        .chartYScale(domain: 0...max(time.yDomainHi, 1))
        .chartYAxis {
            AxisMarks(position: .leading)
            if !time.hr.isEmpty {
                AxisMarks(position: .trailing, values: time.hrTicks.map(\.y)) { value in
                    AxisTick().foregroundStyle(.red)
                    if let y = value.as(Double.self), let tick = time.hrTicks.first(where: { abs($0.y - y) < 0.5 }) {
                        AxisValueLabel { Text("\(tick.bpm)").foregroundStyle(.red) }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white)
    }
}

private extension NSImage {
    func jpeg(quality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
