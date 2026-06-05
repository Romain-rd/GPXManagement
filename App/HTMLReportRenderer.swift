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
        case singleFile, folder, publishBunny
        var id: String { rawValue }
        var label: String {
            switch self {
            case .singleFile:   return "Fichier unique"
            case .folder:       return "Dossier"
            case .publishBunny: return "GPXManagement.net"
            }
        }
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
        let interactiveProfile = options.profile == .interactive

        var distancePNG: Data?
        var timePNG: Data?
        if !interactiveProfile {
            if !distanceSamples.isEmpty {
                distancePNG = renderChartPNG(HTMLDistanceChart(samples: distanceSamples, scale: distanceScale), size: CGSize(width: 1000, height: 300))
            }
            if timeProfile.available {
                timePNG = renderChartPNG(HTMLTimeChart(time: timeProfile), size: CGSize(width: 1000, height: 300))
            }
        }
        let profilePayload = interactiveProfile ? profilePayloadJSON(profile) : ""

        var photoItems: [PhotoItem] = []
        if options.includePhotos {
            for asset in photos {
                if let image = await PhotoLibraryService.fullImage(for: asset), let jpeg = image.jpeg(quality: 0.82) {
                    let coord = asset.location?.coordinate
                    photoItems.append(PhotoItem(data: jpeg, lat: coord?.latitude, lon: coord?.longitude))
                }
            }
        }

        let assets = HTMLAssets(map: mapPNG, distanceProfile: distancePNG, timeProfile: timePNG, photos: photoItems)
        let html = buildHTML(activity: activity, assets: assets, options: options,
                             slopeLegend: slopeLegendItems(distanceScale: distanceScale),
                             movement: movement, hasHeartRate: !timeProfile.hr.isEmpty,
                             layer: layer, trackCoords: trackCoords, profilePayload: profilePayload)

        switch options.output {
        case .singleFile:
            guard let data = html.data(using: .utf8) else { throw HTMLReportError.renderFailed }
            return .singleFile(html: data)
        case .folder, .publishBunny:
            var files: [String: Data] = ["index.html": html.data(using: .utf8) ?? Data()]
            if let map = mapPNG { files["images/carte.png"] = map }
            if let d = distancePNG { files["images/profil-distance.png"] = d }
            if let t = timePNG { files["images/profil-temps.png"] = t }
            for (i, item) in photoItems.enumerated() { files["images/photo-\(i + 1).jpg"] = item.data }
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

    // MARK: - Données du profil interactif

    private static let slopeOrder: [SlopeCategory] = [.gentle, .moderate, .steep, .veryStep, .descent]

    /// Sérialise le profil (décimé) en objet JS : altitude/pente par distance et par temps + FC, lat/lon pour la synchro carte.
    private static func profilePayloadJSON(_ profile: [ElevationProfilePoint]) -> String {
        guard profile.count >= 2 else { return "" }
        let pts = ElevationProfileBuilder.decimate(profile, tolerance: 1.0, maxPoints: 1200)

        func arr(_ values: [String]) -> String { "[" + values.joined(separator: ",") + "]" }
        func num(_ d: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", d) }

        let cats = slopeOrder.map { "\"\(hex($0.color))\"" }
        let catLabels = slopeOrder.map { "\"\($0.label)\"" }

        // Distance / pente
        let dx = pts.map { num($0.distanceFromStart / 1000, 3) }
        let dAlt = pts.map { num($0.altitude, 1) }
        let dCat = pts.map { String(slopeOrder.firstIndex(of: SlopeCategory.category(for: $0.slope)) ?? 0) }
        let dLat = pts.map { num($0.latitude ?? 0, 5) }
        let dLon = pts.map { num($0.longitude ?? 0, 5) }
        let distanceObj = "{x:\(arr(dx)),alt:\(arr(dAlt)),cat:\(arr(dCat)),lat:\(arr(dLat)),lon:\(arr(dLon))}"

        // Temps / mouvement + FC
        var timeObj = "{available:false}"
        let stamps = pts.compactMap(\.timestamp)
        if let t0 = stamps.first, let tLast = stamps.last, tLast > t0 {
            let useMinutes = tLast.timeIntervalSince(t0) < 5400
            let div = useMinutes ? 60.0 : 3600.0
            let axisLabel = useMinutes ? "Temps (min)" : "Temps (h)"
            var lastX = 0.0
            let tx = pts.map { p -> String in
                if let t = p.timestamp { lastX = t.timeIntervalSince(t0) / div }
                return num(lastX, 3)
            }
            let tAlt = pts.map { num($0.altitude, 1) }
            var moving: [String] = []
            for i in 0..<pts.count {
                if i + 1 < pts.count, let a = pts[i].timestamp, let b = pts[i + 1].timestamp, b.timeIntervalSince(a) > 0 {
                    let dd = pts[i + 1].distanceFromStart - pts[i].distanceFromStart
                    moving.append(dd / b.timeIntervalSince(a) > 0.5 ? "1" : "0")
                } else {
                    moving.append(moving.last ?? "1")
                }
            }
            let hrs = pts.compactMap(\.heartRate).filter { $0 > 0 }
            var hrField = "null"
            if hrs.count >= 2 {
                let hr = pts.map { ($0.heartRate ?? 0) > 0 ? num($0.heartRate!, 0) : "null" }
                hrField = arr(hr)
            }
            let tLatA = pts.map { num($0.latitude ?? 0, 5) }
            let tLonA = pts.map { num($0.longitude ?? 0, 5) }
            timeObj = "{available:true,axisLabel:\"\(axisLabel)\",x:\(arr(tx)),alt:\(arr(tAlt)),moving:\(arr(moving)),hr:\(hrField),lat:\(arr(tLatA)),lon:\(arr(tLonA))}"
        }

        return "{cats:[\(cats.joined(separator: ","))],catLabels:[\(catLabels.joined(separator: ","))],distance:\(distanceObj),time:\(timeObj)}"
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

    private struct PhotoItem { let data: Data; let lat: Double?; let lon: Double? }

    private struct HTMLAssets {
        let map: Data?
        let distanceProfile: Data?
        let timeProfile: Data?
        let photos: [PhotoItem]
    }

    private struct LegendItem { let label: String; let color: String }

    private static func slopeLegendItems(distanceScale: [String: Color]) -> [LegendItem] {
        guard !distanceScale.isEmpty else { return [] }
        let cats: [SlopeCategory] = [.gentle, .moderate, .steep, .veryStep, .descent]
        return cats.map { LegendItem(label: $0.label, color: hex($0.color)) }
    }

    private static func buildHTML(activity: ActivitySummary, assets: HTMLAssets, options: WebExportOptions, slopeLegend: [LegendItem], movement: (moving: TimeInterval, paused: TimeInterval), hasHeartRate: Bool, layer: MapLayer, trackCoords: [(lat: Double, lon: Double)], profilePayload: String) -> String {
        let accent = hex(activity.activityType.trackColor)
        let inline = options.output == .singleFile
        let interactiveMap = options.map == .interactive && !trackCoords.isEmpty
        let interactiveProfile = options.profile == .interactive && !profilePayload.isEmpty

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

        // Profils (statiques en images, ou graphique interactif canvas)
        var profileSection = ""
        var profileScript = ""
        if interactiveProfile {
            profileSection = """
            <section class="section"><h2>Profil altimétrique</h2>
              <div class="chart-block">
                <div class="chart-toolbar">
                  <button class="seg active" data-mode="distance">Distance / pente</button>
                  <button class="seg" data-mode="time">Temps / mouvement</button>
                </div>
                <div class="chart-wrap"><canvas id="profile"></canvas><div id="profile-tip" class="tip"></div></div>
                <div class="legend" id="profile-legend"></div>
              </div>
            </section>
            """
            profileScript = "<script>\nwindow.__gpxProfile = \(profilePayload);\n\(profileChartJS)\n</script>"
        } else {
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

              var el = document.getElementById('map');
              var fsBtn = null, pseudo = false;
              function nativeSupported(){ return !!(el.requestFullscreen || el.webkitRequestFullscreen); }
              function isNativeFs(){ return document.fullscreenElement === el || document.webkitFullscreenElement === el; }
              function active(){ return pseudo || isNativeFs(); }
              function refresh(){ setTimeout(function(){ map.invalidateSize(); map.fitBounds(line.getBounds(), { padding: [24, 24] }); if (fsBtn) fsBtn.innerHTML = active() ? '✕' : '⤢'; }, 160); }
              function toggle(){
                if (nativeSupported()) {
                  if (!isNativeFs()) { (el.requestFullscreen || el.webkitRequestFullscreen).call(el); }
                  else { (document.exitFullscreen || document.webkitExitFullscreen).call(document); }
                } else {
                  pseudo = !pseudo;
                  el.classList.toggle('gpx-pseudo-fs', pseudo);
                  document.body.classList.toggle('gpx-fs-lock', pseudo);
                  refresh();
                }
              }
              var FsControl = L.Control.extend({
                options: { position: 'topright' },
                onAdd: function(){
                  fsBtn = L.DomUtil.create('a', 'leaflet-bar leaflet-control gpx-fs');
                  fsBtn.href = '#'; fsBtn.title = 'Plein écran'; fsBtn.innerHTML = '⤢';
                  L.DomEvent.on(fsBtn, 'click', function(e){ L.DomEvent.stop(e); toggle(); });
                  return fsBtn;
                }
              });
              map.addControl(new FsControl());
              document.addEventListener('fullscreenchange', refresh);
              document.addEventListener('webkitfullscreenchange', refresh);

              var cursor = null;
              window.gpxHighlight = function(lat, lon){
                if (lat == null || lon == null) { return; }
                if (!cursor) { cursor = L.circleMarker([lat, lon], { radius: 7, color: '#fff', weight: 2, fillColor: \(jsString(accent)), fillOpacity: 1 }).addTo(map); }
                else { cursor.setLatLng([lat, lon]); }
              };
              window.gpxClearHighlight = function(){ if (cursor) { map.removeLayer(cursor); cursor = null; } };
              var photoMarker = null;
              window.gpxShowPhoto = function(lat, lon, zoom){
                if (lat == null || lon == null) { return; }
                if (!photoMarker) { photoMarker = L.circleMarker([lat, lon], { radius: 8, color: '#fff', weight: 2, fillColor: '#ffcc00', fillOpacity: 1 }).addTo(map); }
                else { photoMarker.setLatLng([lat, lon]); }
                if (zoom) { map.setView([lat, lon], Math.max(map.getZoom(), 15)); } else if (!map.getBounds().contains([lat, lon])) { map.panTo([lat, lon]); }
              };
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

        // Photos (cliquables/survolables → localisation sur la carte interactive)
        var photosSection = ""
        var photoScript = ""
        if !assets.photos.isEmpty {
            let grid = assets.photos.enumerated().map { i, item -> String in
                let src = inline ? "data:image/jpeg;base64,\(item.data.base64EncodedString())" : "images/photo-\(i + 1).jpg"
                if interactiveMap, let lat = item.lat, let lon = item.lon {
                    let attrs = " data-lat=\"\(String(format: "%.6f", lat))\" data-lon=\"\(String(format: "%.6f", lon))\" title=\"Voir où la photo a été prise\""
                    return "<img class=\"photo locatable\" src=\"\(src)\" alt=\"Photo \(i + 1)\" loading=\"lazy\"\(attrs)>"
                }
                return "<img class=\"photo\" src=\"\(src)\" alt=\"Photo \(i + 1)\" loading=\"lazy\">"
            }.joined()
            photosSection = "<section class=\"section\"><h2>Photos</h2><div class=\"photos\">\(grid)</div></section>"
            if interactiveMap, assets.photos.contains(where: { $0.lat != nil }) {
                photoScript = "<script>\n\(photoMapJS)\n</script>"
            }
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
          \(mapSection)
          \(profileSection)
          \(photosSection)
          \(notesSection)
          <footer>\(sourceLine)<p class="madeby">Généré par GPXManagement</p></footer>
        </main>
        \(mapScript)
        \(profileScript)
        \(photoScript)
        </body>
        </html>
        """
    }

    private static let profileChartJS = """
    (function(){
      var D = window.__gpxProfile;
      if (!D) return;
      var canvas = document.getElementById('profile');
      var tip = document.getElementById('profile-tip');
      var legend = document.getElementById('profile-legend');
      var ctx = canvas.getContext('2d');
      var mode = 'distance';
      var dpr = window.devicePixelRatio || 1;
      var pad = { l: 50, r: 16, t: 12, b: 30 };
      var hover = -1;

      function series(){ return mode === 'distance' ? D.distance : D.time; }
      function css(v){ return getComputedStyle(document.body).getPropertyValue(v).trim() || '#999'; }

      function resize(){
        var w = canvas.clientWidth;
        canvas.width = w * dpr; canvas.height = 300 * dpr;
        ctx.setTransform(dpr,0,0,dpr,0,0);
        draw();
      }

      function bounds(s){
        var xmin = s.x[0], xmax = s.x[s.x.length-1];
        var amin = Infinity, amax = -Infinity;
        for (var i=0;i<s.alt.length;i++){ if(s.alt[i]<amin)amin=s.alt[i]; if(s.alt[i]>amax)amax=s.alt[i]; }
        var padA = (amax-amin)*0.08 || 10;
        return { xmin:xmin, xmax:xmax, ymin:amin-padA, ymax:amax+padA };
      }

      function draw(){
        var s = series();
        var W = canvas.clientWidth, H = 300;
        ctx.clearRect(0,0,W,H);
        var b = bounds(s);
        var pl = pad.l, pr = W-pad.r, pt = pad.t, pbt = H-pad.b;
        function X(x){ return pl + (x-b.xmin)/((b.xmax-b.xmin)||1)*(pr-pl); }
        function Y(y){ return pbt - (y-b.ymin)/((b.ymax-b.ymin)||1)*(pbt-pt); }

        for (var i=0;i<s.x.length-1;i++){
          var color = mode==='distance' ? (D.cats[s.cat[i]] || '#888') : (s.moving[i]==1 ? '#34c759' : '#8e8e93');
          ctx.beginPath();
          ctx.moveTo(X(s.x[i]), pbt);
          ctx.lineTo(X(s.x[i]), Y(s.alt[i]));
          ctx.lineTo(X(s.x[i+1]), Y(s.alt[i+1]));
          ctx.lineTo(X(s.x[i+1]), pbt);
          ctx.closePath();
          ctx.fillStyle = color; ctx.globalAlpha = 0.75; ctx.fill(); ctx.globalAlpha = 1;
        }

        if (mode==='time' && s.hr){
          var hmin=Infinity,hmax=-Infinity;
          for (var k=0;k<s.hr.length;k++){ var v=s.hr[k]; if(v!=null){ if(v<hmin)hmin=v; if(v>hmax)hmax=v; } }
          if (hmax>hmin){
            ctx.beginPath(); var started=false;
            for (var k2=0;k2<s.hr.length;k2++){ var v2=s.hr[k2]; if(v2==null)continue; var yy=pbt-(v2-hmin)/(hmax-hmin)*(pbt-pt); var xx=X(s.x[k2]); if(!started){ctx.moveTo(xx,yy);started=true;}else ctx.lineTo(xx,yy); }
            ctx.strokeStyle='#ff3b30'; ctx.lineWidth=1.5; ctx.stroke();
          }
        }

        ctx.strokeStyle = css('--line'); ctx.lineWidth=1;
        ctx.beginPath(); ctx.moveTo(pl,pt); ctx.lineTo(pl,pbt); ctx.lineTo(pr,pbt); ctx.stroke();
        ctx.fillStyle = css('--sec'); ctx.font='11px -apple-system,sans-serif';
        for (var t=0;t<=4;t++){ var yv=b.ymin+(b.ymax-b.ymin)*t/4; var yy2=Y(yv); ctx.fillText(Math.round(yv)+' m', 6, yy2+3); ctx.globalAlpha=0.35; ctx.beginPath(); ctx.moveTo(pl,yy2); ctx.lineTo(pr,yy2); ctx.stroke(); ctx.globalAlpha=1; }
        for (var tx=0;tx<=5;tx++){ var xv=b.xmin+(b.xmax-b.xmin)*tx/5; var xx2=X(xv); ctx.fillText(xv.toFixed(xv<10?1:0), xx2-8, pbt+16); }
        ctx.fillText(mode==='distance' ? 'Distance (km)' : (s.axisLabel||'Temps'), (pl+pr)/2-30, H-4);

        if (hover>=0 && hover<s.x.length){
          var hx=X(s.x[hover]), hy=Y(s.alt[hover]);
          ctx.strokeStyle=css('--accent'); ctx.lineWidth=1; ctx.beginPath(); ctx.moveTo(hx,pt); ctx.lineTo(hx,pbt); ctx.stroke();
          ctx.fillStyle=css('--accent'); ctx.beginPath(); ctx.arc(hx,hy,4,0,Math.PI*2); ctx.fill();
        }
      }

      function showTip(s,i,px){
        var html = '<b>'+s.alt[i].toFixed(0)+' m</b>';
        if (mode==='distance'){ html += '  '+s.x[i].toFixed(2)+' km  '+D.catLabels[s.cat[i]]; }
        else { html += '  '+s.x[i].toFixed(1)+((s.axisLabel||'').indexOf('min')>=0?' min':' h'); if (s.hr && s.hr[i]!=null) html += '  '+s.hr[i]+' bpm'; }
        tip.innerHTML = html; tip.style.left = px+'px'; tip.style.top = pad.t+'px'; tip.style.opacity = 1;
      }

      canvas.addEventListener('mousemove', function(e){
        var s = series(); var rect = canvas.getBoundingClientRect();
        var W = canvas.clientWidth; var pl = pad.l, pr = W-pad.r; var b = bounds(s);
        var xv = b.xmin + (e.clientX-rect.left-pl)/((pr-pl)||1)*(b.xmax-b.xmin);
        var best=0, bd=Infinity;
        for (var i=0;i<s.x.length;i++){ var d=Math.abs(s.x[i]-xv); if(d<bd){bd=d;best=i;} }
        hover=best; draw();
        var px = pl + (s.x[best]-b.xmin)/((b.xmax-b.xmin)||1)*(pr-pl);
        showTip(s,best,px);
        if (window.gpxHighlight && s.lat) window.gpxHighlight(s.lat[best], s.lon[best]);
      });
      canvas.addEventListener('mouseleave', function(){ hover=-1; tip.style.opacity=0; draw(); if(window.gpxClearHighlight) window.gpxClearHighlight(); });

      function buildLegend(){
        var html='';
        if (mode==='distance'){ for (var i=0;i<D.cats.length;i++){ html += '<span class="li"><i style="background:'+D.cats[i]+'"></i>'+D.catLabels[i]+'</span>'; } }
        else { html += '<span class="li"><i style="background:#34c759"></i>En mouvement</span><span class="li"><i style="background:#8e8e93"></i>Pause</span>'; if (D.time.hr) html += '<span class="li"><i style="background:#ff3b30"></i>Fréquence cardiaque</span>'; }
        legend.innerHTML = html;
      }

      var btns = Array.prototype.slice.call(document.querySelectorAll('.seg'));
      btns.forEach(function(btn){
        btn.addEventListener('click', function(){
          var m = btn.getAttribute('data-mode');
          if (m==='time' && !D.time.available) return;
          mode = m;
          btns.forEach(function(b){ b.classList.toggle('active', b===btn); });
          hover=-1; tip.style.opacity=0; buildLegend(); draw();
        });
      });
      if (!D.time.available){ btns.forEach(function(b){ if(b.getAttribute('data-mode')==='time'){ b.disabled=true; b.style.opacity=0.4; b.style.cursor='not-allowed'; } }); }

      buildLegend();
      window.addEventListener('resize', resize);
      resize();
    })();
    """

    private static let photoMapJS = """
    (function(){
      var imgs = Array.prototype.slice.call(document.querySelectorAll('.photo.locatable'));
      imgs.forEach(function(img){
        var lat = parseFloat(img.getAttribute('data-lat'));
        var lon = parseFloat(img.getAttribute('data-lon'));
        img.addEventListener('mouseenter', function(){ if (window.gpxShowPhoto) window.gpxShowPhoto(lat, lon, false); });
        img.addEventListener('click', function(){
          if (window.gpxShowPhoto) window.gpxShowPhoto(lat, lon, true);
          var m = document.getElementById('map');
          if (m) m.scrollIntoView({ behavior: 'smooth', block: 'center' });
        });
      });
    })();
    """

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
        .gpx-fs { font-size:18px; line-height:28px; text-align:center; width:30px; height:30px; cursor:pointer; text-decoration:none; color:#333; background:#fff; }
        #map:fullscreen, #map:-webkit-full-screen { width:100%; height:100%; border-radius:0; aspect-ratio:auto; border:0; }
        #map.gpx-pseudo-fs { position:fixed !important; inset:0 !important; width:100vw !important; height:100vh !important; height:100dvh !important; border-radius:0 !important; aspect-ratio:auto !important; border:0 !important; z-index:9999 !important; }
        body.gpx-fs-lock { overflow:hidden; }
        .chart { width:100%; height:auto; border-radius:14px; border:1px solid var(--line); display:block; background:var(--card); }
        .credit { font-size:11px; color:var(--sec); margin:6px 0 0; }
        .chart-block { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px 16px; margin-bottom:14px; }
        .chart-block h3 { margin-top:0; }
        .legend { display:flex; flex-wrap:wrap; gap:14px; margin-top:8px; font-size:12px; color:var(--sec); }
        .legend .li { display:inline-flex; align-items:center; gap:5px; }
        .legend i { width:11px; height:11px; border-radius:3px; display:inline-block; }
        .chart-toolbar { display:flex; gap:6px; margin-bottom:10px; }
        .seg { font:13px inherit; padding:5px 12px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--fg); cursor:pointer; }
        .seg.active { background:var(--accent); color:#fff; border-color:var(--accent); }
        .chart-wrap { position:relative; width:100%; }
        #profile { width:100%; height:300px; display:block; cursor:crosshair; }
        .tip { position:absolute; pointer-events:none; background:rgba(0,0,0,0.82); color:#fff; font-size:12px; padding:6px 9px; border-radius:8px; transform:translate(-50%,-115%); white-space:nowrap; opacity:0; transition:opacity .08s; z-index:5; }
        .photos { display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:10px; }
        .photo { width:100%; aspect-ratio:1; object-fit:cover; border-radius:12px; border:1px solid var(--line); }
        .photo.locatable { cursor:pointer; transition:transform .1s, box-shadow .1s; }
        .photo.locatable:hover { transform:scale(1.03); box-shadow:0 0 0 2px var(--accent); }
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
