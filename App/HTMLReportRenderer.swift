import SwiftUI
import Charts
import AppKit
import MapKit
import Photos
import GPXCore
import GPXMapKit

struct WebExportOptions: Codable {
    enum MapRendering: String, CaseIterable, Identifiable, Codable {
        case staticImage, interactive
        var id: String { rawValue }
        var label: String { self == .staticImage ? "Image statique" : "Carte interactive" }
    }
    enum ProfileRendering: String, CaseIterable, Identifiable, Codable {
        case staticImage, interactive
        var id: String { rawValue }
        var label: String { self == .staticImage ? "Image statique" : "Graphique interactif" }
    }
    enum Output: String, CaseIterable, Identifiable, Codable {
        case folder, publishBunny
        var id: String { rawValue }
        var label: String {
            switch self {
            case .folder:       return "Dossier"
            case .publishBunny: return "GPXManagement.net"
            }
        }
    }

    var map: MapRendering = .interactive
    var profile: ProfileRendering = .interactive
    var output: Output = .folder
    var includePhotos: Bool = true
    var includeNotes: Bool = true
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
        let mapPoints = options.map == .interactive ? decimatedPoints(points, max: 2000) : []
        let trackCoords = mapPoints.map { (lat: $0.latitude, lon: $0.longitude) }
        let trackColors = mapPoints.isEmpty ? (speed: [String](), slope: [String]()) : trackColorHex(points: mapPoints, activityType: activity.activityType)

        let profile = ElevationProfileBuilder.build(points: points)
        let hasAltitude = !profile.isEmpty
        let workingProfile = hasAltitude ? profile : ElevationProfileBuilder.buildMotion(points: points)
        let (distanceSamples, distanceScale) = PDFReportRenderer.slopeRuns(from: profile, scale: activity.activityType.slopeScale)
        let timeProfile = PDFReportRenderer.movementRuns(from: profile)
        let movement = PDFReportRenderer.movementSplit(workingProfile)
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
        let profilePayload = interactiveProfile ? profilePayloadJSON(workingProfile, activity: activity, hasAltitude: hasAltitude) : ""

        var photoItems: [PhotoItem] = []
        if options.includePhotos {
            for asset in photos {
                let coord = PhotoLibraryService.resolvedCoordinate(for: asset, in: points)
                if asset.mediaType == .video {
                    if let mp4 = await PhotoLibraryService.exportVideo(for: asset) {
                        let poster = await PhotoLibraryService.fullImage(for: asset)?.jpeg(quality: 0.8)
                        photoItems.append(PhotoItem(data: mp4, isVideo: true, poster: poster, lat: coord?.latitude, lon: coord?.longitude))
                    }
                } else if let image = await PhotoLibraryService.fullImage(for: asset), let jpeg = image.jpeg(quality: 0.82) {
                    photoItems.append(PhotoItem(data: jpeg, isVideo: false, poster: nil, lat: coord?.latitude, lon: coord?.longitude))
                }
            }
        }

        let assets = HTMLAssets(map: mapPNG, distanceProfile: distancePNG, timeProfile: timePNG, photos: photoItems)
        let html = buildHTML(activity: activity, assets: assets, options: options,
                             slopeLegend: slopeLegendItems(distanceScale: distanceScale, scale: activity.activityType.slopeScale),
                             movement: movement, hasHeartRate: !timeProfile.hr.isEmpty,
                             layer: layer, trackCoords: trackCoords, trackSpeedColors: trackColors.speed, trackSlopeColors: trackColors.slope, profilePayload: profilePayload)

        do {
            var files: [String: Data] = ["index.html": html.data(using: .utf8) ?? Data()]
            if let map = mapPNG { files["images/carte.png"] = map }
            if let d = distancePNG { files["images/profil-distance.png"] = d }
            if let t = timePNG { files["images/profil-temps.png"] = t }
            for (i, item) in photoItems.enumerated() {
                if item.isVideo {
                    files["images/video-\(i + 1).mp4"] = item.data
                    if let poster = item.poster { files["images/poster-\(i + 1).jpg"] = poster }
                } else {
                    files["images/photo-\(i + 1).jpg"] = item.data
                }
            }
            return .folder(files: files)
        }
    }

    // MARK: - Export d'un raid

    private struct RaidStage {
        let index: Int
        let title: String
        let dateText: String
        let distance: Double
        let gain: Double
        let coords: [(lat: Double, lon: Double)]
        let color: String
    }

    private static let raidPalette = ["#e6194B", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#42d4f4", "#f032e6", "#469990", "#9A6324", "#800000", "#808000", "#000075", "#a9a9a9"]

    /// Génère le dossier d'un raid : page d'ensemble + une page complète par étape (réutilise `render`).
    static func renderRaid(raid: Raid, members: [ActivitySummary], repository: CoreDataActivityRepository, layer: MapLayer, options: WebExportOptions, stagePhotos: [UUID: [PHAsset]], onProgress: ((Double, String) -> Void)? = nil) async throws -> [String: Data] {
        var files: [String: Data] = [:]
        var stageOpts = options
        stageOpts.output = .folder

        var stages: [RaidStage] = []
        let total = max(members.count, 1)
        for (i, m) in members.enumerated() {
            onProgress?(Double(i) / Double(total + 1), "Étape \(i + 1)/\(members.count) — \(m.title)")
            let out = try await render(activity: m, repository: repository, layer: layer, options: stageOpts, photos: stagePhotos[m.id] ?? [])
            if case let .folder(stageFiles) = out {
                for (rel, data) in stageFiles { files["etape-\(i + 1)/\(rel)"] = data }
            }
            var coords: [(lat: Double, lon: Double)] = []
            if let data = try? await repository.fetchTrackData(id: m.id), !data.isEmpty, let pts = try? TrackPointCodec.decode(data) {
                coords = decimatedCoords(pts, max: 1500)
            }
            stages.append(RaidStage(index: i + 1, title: m.title, dateText: fmtDateShort(m.startDate), distance: m.distance, gain: m.elevationGain, coords: coords, color: raidPalette[i % raidPalette.count]))
        }

        var coverRef: String?
        if let cover = raid.coverImageData { let name = "assets/cover.\(imageExt(cover))"; files[name] = cover; coverRef = name }
        var avatarRefs: [String] = []
        for (i, p) in raid.participants.enumerated() {
            if let d = p.avatarImageData { let name = "assets/avatar-\(i + 1).\(imageExt(d))"; files[name] = d; avatarRefs.append(name) } else { avatarRefs.append("") }
        }

        onProgress?(Double(total) / Double(total + 1), "Page du raid…")
        // Page d'aperçu (carte d'ensemble) dans apercu/ → réfs assets remontées d'un niveau.
        let overview = buildRaidOverviewHTML(raid: raid, members: members, layer: layer,
                                             coverRef: coverRef.map { "../" + $0 },
                                             avatarRefs: avatarRefs.map { $0.isEmpty ? "" : "../" + $0 },
                                             stages: stages)
        files["apercu/index.html"] = overview.data(using: .utf8) ?? Data()
        // Coquille split-view à la racine (liste des étapes + iframe de l'étape sélectionnée).
        let shell = buildRaidShellHTML(raid: raid, members: members, coverRef: coverRef, stages: stages)
        files["index.html"] = shell.data(using: .utf8) ?? Data()
        return files
    }

    private static func imageExt(_ data: Data) -> String {
        let sig = [UInt8](data.prefix(4))
        if sig.count == 4, sig[0] == 0x89, sig[1] == 0x50, sig[2] == 0x4E, sig[3] == 0x47 { return "png" }
        return "jpg"
    }

    private static func buildRaidOverviewHTML(raid: Raid, members: [ActivitySummary], layer: MapLayer, coverRef: String?, avatarRefs: [String], stages: [RaidStage]) -> String {
        let accent = hex(members.first?.activityType.trackColor ?? .systemBlue)
        let tile = webTileLayer(for: layer)

        var participantsHTML = ""
        if !raid.participants.isEmpty {
            let items = raid.participants.enumerated().map { i, p -> String in
                let av = (i < avatarRefs.count && !avatarRefs[i].isEmpty)
                    ? "<img src=\"\(avatarRefs[i])\" alt=\"\(esc(p.name))\">"
                    : "<span class=\"pp-ph\">\(esc(String(p.name.prefix(1))))</span>"
                return "<div class=\"pp\">\(av)<span>\(esc(p.name))</span></div>"
            }.joined()
            participantsHTML = "<section class=\"section\"><h2>Participants</h2><div class=\"participants\">\(items)</div></section>"
        }

        let cards = raidStatCards(members).joined()
        let legend = stages.map { "<span class=\"li\"><i style=\"background:\($0.color)\"></i>\(esc("J\($0.index) · \($0.title)"))</span>" }.joined()
        let mapSection = "<section class=\"section\"><h2>Carte d'ensemble</h2><div id=\"map\" class=\"map interactive\"></div><div class=\"legend\">\(legend)</div></section>"

        var notesSection = ""
        if let notes = raid.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            notesSection = "<section class=\"section\"><h2>Notes</h2><p class=\"notes\">\(nl2br(notes))</p></section>"
        }

        let subtitle = [raid.subtitle, raid.place].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(raid.name)) — Carte d'ensemble</title>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css">
        <script src="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"></script>
        <style>\(css(accent: accent))\(raidCSS)</style>
        </head>
        <body>
        <main class="page">
          <header class="hero"><div class="hero-text"><h1>\(esc(raid.name))</h1>\(subtitle.isEmpty ? "" : "<p class=\"subtitle\">\(esc(subtitle))</p>")</div></header>
          <section class="metrics">\(cards)</section>
          \(mapSection)
          \(participantsHTML)
          \(notesSection)
          <footer><p class="madeby">Généré par GPXManagement</p></footer>
        </main>
        \(raidMapScript(stages: stages, tile: tile, accent: accent))
        </body>
        </html>
        """
    }

    private static func raidStatCards(_ members: [ActivitySummary]) -> [String] {
        let totalDist = members.reduce(0) { $0 + $1.distance }
        let totalGain = members.reduce(0) { $0 + $1.elevationGain }
        let totalLoss = members.reduce(0) { $0 + $1.elevationLoss }
        let totalDur = members.reduce(0) { $0 + $1.duration }
        let totalMov = members.reduce(0) { $0 + $1.movingDuration }
        return [
            metricCard("📍", "Étapes", "\(members.count)"),
            metricCard("📏", "Distance", fmtDistance(totalDist)),
            metricCard("⬆️", "Dénivelé +", "\(Int(totalGain.rounded())) m"),
            metricCard("⬇️", "Dénivelé −", "\(Int(totalLoss.rounded())) m"),
            metricCard("🕐", "Durée totale", fmtDuration(totalDur)),
            metricCard("⏱️", "En mouvement", fmtDuration(totalMov))
        ]
    }

    /// Coquille split-view : barre latérale (identité + liste des étapes), iframe de l'étape sélectionnée.
    private static func buildRaidShellHTML(raid: Raid, members: [ActivitySummary], coverRef: String?, stages: [RaidStage]) -> String {
        let accent = hex(members.first?.activityType.trackColor ?? .systemBlue)
        let dateText: String = {
            if let s = raid.startDate, let e = raid.endDate { return "\(fmtDateShort(s)) → \(fmtDateShort(e))" }
            if let s = raid.startDate { return fmtDateShort(s) }
            return ""
        }()
        let subtitle = [raid.subtitle, raid.place].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        let sub = [subtitle, dateText].filter { !$0.isEmpty }.joined(separator: " · ")

        let coverThumb = coverRef.map { "<div class=\"side-cover\" style=\"background-image:url('\($0)')\"></div>" } ?? ""
        let totalDist = members.reduce(0) { $0 + $1.distance }

        let overviewItem = "<a class=\"nav\" href=\"apercu/\" data-target=\"apercu/\"><span class=\"sb sb-ov\">🗺️</span><div class=\"si\"><span class=\"st\">Carte d'ensemble</span><span class=\"sm\">\(members.count) étapes · \(esc(fmtDistance(totalDist)))</span></div></a>"
        let stageItems = stages.map { s in
            "<a class=\"nav\" href=\"etape-\(s.index)/\" data-target=\"etape-\(s.index)/\"><span class=\"sb\" style=\"background:\(s.color)\">J\(s.index)</span><div class=\"si\"><span class=\"st\">\(esc(s.title))</span><span class=\"sm\">\(esc(s.dateText)) · \(esc(fmtDistance(s.distance))) · \(Int(s.gain.rounded())) m D+</span></div></a>"
        }.joined()

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(raid.name))</title>
        <style>\(css(accent: accent))\(raidCSS)</style>
        </head>
        <body>
        <div class="raid-shell">
          <aside class="raid-side">
            \(coverThumb)
            <h1 class="side-title">\(esc(raid.name))</h1>
            \(sub.isEmpty ? "" : "<p class=\"side-sub\">\(esc(sub))</p>")
            <nav class="raid-nav">\(overviewItem)\(stageItems)</nav>
            <footer class="side-foot"><span class="madeby">GPXManagement</span></footer>
          </aside>
          <main class="raid-main"><iframe id="stageframe" title="Étape"></iframe></main>
        </div>
        <script>
        (function(){
          var frame = document.getElementById('stageframe');
          var navs = Array.prototype.slice.call(document.querySelectorAll('.nav'));
          function split(){ return window.matchMedia('(min-width: 920px)').matches; }
          function select(a){ navs.forEach(function(n){ n.classList.toggle('active', n === a); }); if (frame) frame.src = a.getAttribute('data-target'); }
          navs.forEach(function(a){ a.addEventListener('click', function(e){ if (split()) { e.preventDefault(); select(a); } }); });
          var overview = navs.filter(function(n){ return n.getAttribute('data-target') === 'apercu/'; })[0] || navs[0];
          if (split() && overview) select(overview);
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func raidMapScript(stages: [RaidStage], tile: WebTileLayer, accent: String) -> String {
        let groups = stages.map { s -> String in
            let coords = "[" + s.coords.map { String(format: "[%.6f,%.6f]", $0.lat, $0.lon) }.joined(separator: ",") + "]"
            return "{color:\(jsString(s.color)),coords:\(coords)}"
        }.joined(separator: ",")
        return """
        <script>
        (function(){
          var groups = [\(groups)];
          var map = L.map('map', { scrollWheelZoom: false });
          L.tileLayer(\(jsString(tile.urlTemplate)), { maxZoom: \(tile.maxZoom), attribution: \(jsString(tile.attribution)) }).addTo(map);
          var lines = [];
          groups.forEach(function(g){
            if (!g.coords.length) return;
            var line = L.polyline(g.coords, { color: g.color, weight: 4, opacity: 0.9 }).addTo(map);
            lines.push(line);
          });
          if (lines.length) { map.fitBounds(L.featureGroup(lines).getBounds(), { padding: [24, 24] }); }
          var el = document.getElementById('map');
          var pseudo = false;
          function nativeSupported(){ return !!(el.requestFullscreen || el.webkitRequestFullscreen); }
          function isNativeFs(){ return document.fullscreenElement === el || document.webkitFullscreenElement === el; }
          function refresh(){ setTimeout(function(){ map.invalidateSize(); if (lines.length) map.fitBounds(L.featureGroup(lines).getBounds(), { padding: [24, 24] }); if (fsBtn) fsBtn.innerHTML = (pseudo || isNativeFs()) ? '✕' : '⤢'; }, 160); }
          function toggle(){
            if (nativeSupported()) {
              if (!isNativeFs()) { (el.requestFullscreen || el.webkitRequestFullscreen).call(el); }
              else { (document.exitFullscreen || document.webkitExitFullscreen).call(document); }
            } else { pseudo = !pseudo; el.classList.toggle('gpx-pseudo-fs', pseudo); document.body.classList.toggle('gpx-fs-lock', pseudo); refresh(); }
          }
          var fsBtn = null;
          var FsControl = L.Control.extend({
            options: { position: 'topright' },
            onAdd: function(){ fsBtn = L.DomUtil.create('a', 'leaflet-bar leaflet-control gpx-fs'); fsBtn.href = '#'; fsBtn.title = 'Plein écran'; fsBtn.innerHTML = '⤢'; L.DomEvent.on(fsBtn, 'click', function(e){ L.DomEvent.stop(e); toggle(); }); return fsBtn; }
          });
          map.addControl(new FsControl());
          document.addEventListener('fullscreenchange', refresh);
          document.addEventListener('webkitfullscreenchange', refresh);
        })();
        </script>
        """
    }

    private static let raidCSS = """
    .cover { width:100%; aspect-ratio:21/9; background-size:cover; background-position:center; border-radius:16px; margin-bottom:20px; border:1px solid var(--line); }
    .participants { display:flex; flex-wrap:wrap; gap:14px; }
    .pp { display:flex; align-items:center; gap:8px; }
    .pp img, .pp .pp-ph { width:36px; height:36px; border-radius:50%; object-fit:cover; }
    .pp .pp-ph { display:inline-flex; align-items:center; justify-content:center; background:var(--accent); color:#fff; font-weight:700; }
    /* Coquille split-view */
    .raid-shell { display:flex; min-height:100vh; }
    .raid-side { width:320px; flex:0 0 auto; box-sizing:border-box; padding:18px; border-right:1px solid var(--line); height:100vh; overflow-y:auto; position:sticky; top:0; }
    .side-cover { width:100%; aspect-ratio:16/9; background-size:cover; background-position:center; border-radius:12px; margin-bottom:12px; border:1px solid var(--line); }
    .side-title { font-size:20px; font-weight:800; letter-spacing:-.02em; margin:0 0 2px; }
    .side-sub { color:var(--sec); font-size:13px; margin:0 0 14px; }
    .raid-nav { display:flex; flex-direction:column; gap:8px; }
    .nav { display:flex; align-items:center; gap:10px; padding:10px 12px; border-radius:10px; text-decoration:none; color:var(--fg); border:1px solid transparent; }
    .nav:hover { background:var(--card); }
    .nav.active { background:var(--card); border-color:var(--accent); }
    .nav .sb { flex:0 0 auto; width:34px; height:34px; border-radius:9px; color:#fff; font-weight:700; display:inline-flex; align-items:center; justify-content:center; font-size:13px; }
    .nav .sb-ov { background:var(--accent); }
    .nav .si { display:flex; flex-direction:column; min-width:0; }
    .nav .st { font-weight:600; font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .nav .sm { font-size:12px; color:var(--sec); }
    .side-foot { margin-top:16px; padding-top:12px; border-top:1px solid var(--line); font-size:12px; }
    .raid-main { flex:1; min-width:0; }
    .raid-main iframe { width:100%; height:100vh; border:0; display:block; }
    @media (max-width: 919px) {
      .raid-shell { display:block; }
      .raid-side { width:auto; height:auto; position:static; overflow:visible; border-right:0; border-bottom:1px solid var(--line); }
      .raid-main { display:none; }
    }
    """

    private static func fmtDateShort(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: d)
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

    private static func decimatedPoints(_ points: [TrackPoint], max: Int) -> [TrackPoint] {
        guard points.count > max else { return points }
        let step = Double(points.count) / Double(max)
        var out = (0..<max).map { points[Int(Double($0) * step)] }
        if let last = points.last { out.append(last) }
        return out
    }

    private static func hexRGB(_ rgb: (r: Double, g: Double, b: Double)) -> String {
        hex(NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
    }

    /// Couleurs hex par point (vitesse, pente) pour colorer la trace sur la carte interactive.
    private static func trackColorHex(points: [TrackPoint], activityType: ActivityType) -> (speed: [String], slope: [String]) {
        let count = points.count
        var slope: [String] = []
        let prof = ElevationProfileBuilder.build(points: points)
        if prof.count == count {
            let s = SlopeScale.percent
            slope = prof.map { hexRGB(s.category(for: $0.slope).rgb) }
        }
        var speed: [String] = []
        let motion = ElevationProfileBuilder.buildMotion(points: points)
        if motion.count == count, count >= 2 {
            let sc = activityType.speedScale
            let usesNM = activityType.usesNauticalUnits
            var raw = [Double](repeating: 0, count: count)
            for i in 1..<count {
                if let t0 = motion[i - 1].timestamp, let t1 = motion[i].timestamp {
                    let dt = t1.timeIntervalSince(t0)
                    let dd = motion[i].distanceFromStart - motion[i - 1].distanceFromStart
                    raw[i] = (dt > 0 && dt <= 600) ? dd / dt : raw[i - 1]
                } else { raw[i] = raw[i - 1] }
            }
            if count > 1 { raw[0] = raw[1] }
            speed = (0..<count).map { i in
                let lo = max(0, i - 2), hi = min(count - 1, i + 2)
                var sum = 0.0; for k in lo...hi { sum += raw[k] }
                let kmh = (sum / Double(hi - lo + 1)) * 3.6
                return hexRGB(sc.category(for: usesNM ? kmh / 1.852 : kmh).rgb)
            }
        }
        return (speed, slope)
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

    /// Sérialise le profil (décimé) en objet JS : altitude/pente + vitesse par distance et par temps + FC, lat/lon pour la synchro carte.
    private static func profilePayloadJSON(_ profile: [ElevationProfilePoint], activity: ActivitySummary, hasAltitude: Bool) -> String {
        guard profile.count >= 2 else { return "" }
        let pts = hasAltitude
            ? ElevationProfileBuilder.decimate(profile, tolerance: 1.0, maxPoints: 1200)
            : strideCap(profile, maxN: 1200)
        let scale = activity.activityType.slopeScale
        let at = activity.activityType
        let usesNM = at.usesNauticalUnits

        func arr(_ values: [String]) -> String { "[" + values.joined(separator: ",") + "]" }
        func num(_ d: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", d) }

        let order = scale.categories
        let cats = order.map { "\"\(hex($0.color))\"" }
        let catLabels = order.map { "\"\(scale.label(for: $0))\"" }

        // Pauses calculées sur le profil PLEIN (la décimation fausse la détection par rayon) → plages temporelles, classement par point.
        let pausedRanges = ElevationProfileBuilder.pausedTimeRanges(profile, pauseMinSeconds: PDFReportRenderer.pauseMinSeconds, pauseRadiusMeters: PDFReportRenderer.pauseRadiusMeters)
        func isPausedPt(_ i: Int) -> Bool {
            guard !pausedRanges.isEmpty, let t = pts[i].timestamp else { return false }
            return pausedRanges.contains { $0.contains(t) }
        }
        let pausedArr = pts.indices.map { isPausedPt($0) ? "1" : "0" }

        // Vitesse (unité d'affichage) + catégorie par point
        let sScale = at.speedScale
        var rawMps = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count {
            if let t0 = pts[i - 1].timestamp, let t1 = pts[i].timestamp {
                let dt = t1.timeIntervalSince(t0)
                let dd = pts[i].distanceFromStart - pts[i - 1].distanceFromStart
                rawMps[i] = (dt > 0 && dt <= 600) ? dd / dt : rawMps[i - 1]
            } else { rawMps[i] = rawMps[i - 1] }
        }
        if pts.count > 1 { rawMps[0] = rawMps[1] }
        func dispSpeed(_ mps: Double) -> Double { let kmh = mps * 3.6; return usesNM ? kmh / 1.852 : kmh }
        var spd = [Double](repeating: 0, count: pts.count)
        for i in 0..<pts.count {
            let lo = max(0, i - 2), hi = min(pts.count - 1, i + 2)
            var sum = 0.0; for k in lo...hi { sum += rawMps[k] }
            // En pause, la vitesse réelle est nulle (jitter GPS) → on la force à 0.
            spd[i] = isPausedPt(i) ? 0 : dispSpeed(sum / Double(hi - lo + 1))
        }
        let speedArr = spd.map { num($0, 1) }
        let scatArr = spd.map { String(sScale.category(for: $0).rawValue) }
        let speedCats = sScale.categories.map { c -> String in let v = c.rgb; return "\"\(hex(NSColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 1)))\"" }
        let speedLabels = sScale.categories.map { "\"\(sScale.label(for: $0))\"" }

        // Distance / pente
        let dx = pts.map { num($0.distanceFromStart / 1000, 3) }
        let dAlt = pts.map { num($0.altitude, 1) }
        let dCat = pts.map { String(order.firstIndex(of: scale.category(for: $0.slope)) ?? 0) }
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
            let moving = pts.indices.map { isPausedPt($0) ? "0" : "1" } // = non-pause (cohérent avec les cartes)
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

        let distUnit = usesNM ? "NM" : "km"
        let distFactor = usesNM ? (1.0 / 1.852) : 1.0
        return "{hasAlt:\(hasAltitude),cats:[\(cats.joined(separator: ","))],catLabels:[\(catLabels.joined(separator: ","))],"
            + "speedCats:[\(speedCats.joined(separator: ","))],speedLabels:[\(speedLabels.joined(separator: ","))],"
            + "spd:\(arr(speedArr)),scat:\(arr(scatArr)),speedUnit:\"\(at.speedUnitLabel)\",distUnit:\"\(distUnit)\",distFactor:\(num(distFactor, 6)),"
            + "paused:\(arr(pausedArr)),distance:\(distanceObj),time:\(timeObj)}"
    }

    /// Sous-échantillonnage uniforme (profils sans altitude : Douglas-Peucker écraserait une courbe plate).
    private static func strideCap(_ a: [ElevationProfilePoint], maxN: Int) -> [ElevationProfilePoint] {
        guard a.count > maxN else { return a }
        let step = Int((Double(a.count) / Double(maxN)).rounded(.up))
        var r = stride(from: 0, to: a.count, by: step).map { a[$0] }
        if let last = a.last, r.last?.distanceFromStart != last.distanceFromStart { r.append(last) }
        return r
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

    private struct PhotoItem { let data: Data; let isVideo: Bool; let poster: Data?; let lat: Double?; let lon: Double? }

    private struct HTMLAssets {
        let map: Data?
        let distanceProfile: Data?
        let timeProfile: Data?
        let photos: [PhotoItem]
    }

    private struct LegendItem { let label: String; let color: String }

    private static func slopeLegendItems(distanceScale: [String: Color], scale: SlopeScale) -> [LegendItem] {
        guard !distanceScale.isEmpty else { return [] }
        return scale.categories.map { LegendItem(label: scale.label(for: $0), color: hex($0.color)) }
    }

    private static func buildHTML(activity: ActivitySummary, assets: HTMLAssets, options: WebExportOptions, slopeLegend: [LegendItem], movement: (moving: TimeInterval, paused: TimeInterval), hasHeartRate: Bool, layer: MapLayer, trackCoords: [(lat: Double, lon: Double)], trackSpeedColors: [String] = [], trackSlopeColors: [String] = [], profilePayload: String) -> String {
        let accent = hex(activity.activityType.trackColor)
        let interactiveMap = options.map == .interactive && !trackCoords.isEmpty
        let interactiveProfile = options.profile == .interactive && !profilePayload.isEmpty

        func imgTag(_ data: Data?, file: String, mime: String, alt: String, cssClass: String) -> String {
            guard data != nil else { return "" }
            return "<img class=\"\(cssClass)\" src=\"\(file)\" alt=\"\(esc(alt))\" loading=\"lazy\">"
        }

        // En-tête
        let tagsHTML = activity.tags.isEmpty ? "" :
            "<div class=\"tags\">" + activity.tags.map { "<span class=\"tag\">\(esc($0))</span>" }.joined() + "</div>"

        // Métriques (unités nautiques pour la voile)
        let usesNM = activity.activityType.usesNauticalUnits
        let distStr = usesNM ? String(format: "%.2f NM", activity.distance / 1852) : fmtDistance(activity.distance)
        func speedStr(_ mps: Double) -> String {
            let kmh = mps * 3.6
            return usesNM ? String(format: "%.1f nœuds", kmh / 1.852) : String(format: "%.1f km/h", kmh)
        }
        var cards: [String] = [
            metricCard("📏", "Distance", distStr),
            metricCard("⬆️", "Dénivelé +", "\(Int(activity.elevationGain.rounded())) m"),
            metricCard("⬇️", "Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m"),
            metricCard("🕐", "Durée totale", fmtDuration(activity.duration)),
            metricCard("⏱️", "En mouvement", fmtDuration(movement.moving)),
            metricCard("💨", "Vitesse moy.", speedStr(activity.avgSpeed)),
            metricCard("⚡️", "Vitesse max", speedStr(activity.maxSpeed))
        ]
        if let hr = activity.avgHeartRate { cards.append(metricCard("❤️", "FC moyenne", "\(Int(hr.rounded())) bpm")) }
        if let hr = activity.maxHeartRate { cards.append(metricCard("❤️", "FC max", "\(Int(hr.rounded())) bpm")) }

        // Profils (statiques en images, ou graphique interactif canvas)
        var profileSection = ""
        var profileScript = ""
        if interactiveProfile {
            profileSection = """
            <section class="section"><h2 id="profile-title">Profil</h2>
              <div class="chart-block">
                <div class="chart-toolbar">
                  <button class="segm active" data-metric="altitude">Altitude</button>
                  <button class="segm" data-metric="speed">Vitesse</button>
                  <span style="width:12px"></span>
                  <button class="seg active" data-mode="distance">Distance</button>
                  <button class="seg" data-mode="time">Temps</button>
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
            let speedColorsJSON = trackSpeedColors.isEmpty ? "null" : "[" + trackSpeedColors.map { jsString($0) }.joined(separator: ",") + "]"
            let slopeColorsJSON = trackSlopeColors.isEmpty ? "null" : "[" + trackSlopeColors.map { jsString($0) }.joined(separator: ",") + "]"
            // Couleur de trace par défaut, adaptée au type : voile → vitesse, terrestre → pente (si dispo).
            let defaultTrackColor: String = {
                if activity.activityType.usesNauticalUnits { return trackSpeedColors.isEmpty ? "uniform" : "speed" }
                if !trackSlopeColors.isEmpty { return "slope" }
                if !trackSpeedColors.isEmpty { return "speed" }
                return "uniform"
            }()
            mapSection = "<section class=\"section\"><h2>Carte</h2><div id=\"map\" class=\"map interactive\"></div></section>"
            mapScript = """
            <script>
            (function(){
              var coords = \(coordsJSON);
              var trackColors = { speed: \(speedColorsJSON), slope: \(slopeColorsJSON) };
              var defaultMode = \(jsString(defaultTrackColor));
              var accentColor = \(jsString(accent));
              var map = L.map('map', { scrollWheelZoom: false });
              L.tileLayer(\(jsString(tile.urlTemplate)), { maxZoom: \(tile.maxZoom), attribution: \(jsString(tile.attribution)) }).addTo(map);
              var trackLayers = [];
              function clearTrack(){ trackLayers.forEach(function(l){ map.removeLayer(l); }); trackLayers = []; }
              function drawTrack(mode){
                clearTrack();
                var cols = (mode === 'speed') ? trackColors.speed : (mode === 'slope') ? trackColors.slope : null;
                if (!cols) {
                  trackLayers.push(L.polyline(coords, { color: accentColor, weight: 4, opacity: 0.9 }).addTo(map));
                } else {
                  var i = 0;
                  while (i < coords.length - 1) {
                    var c = cols[i], j = i;
                    while (j < coords.length - 1 && cols[j] === c) j++;
                    trackLayers.push(L.polyline(coords.slice(i, j + 1), { color: c, weight: 4, opacity: 0.95 }).addTo(map));
                    i = j;
                  }
                }
              }
              drawTrack(defaultMode);
              var line = trackLayers[0];
              map.fitBounds(L.latLngBounds(coords), { padding: [24, 24] });
              L.circleMarker(coords[0], { radius: 6, color: '#fff', weight: 2, fillColor: '#34c759', fillOpacity: 1 }).addTo(map);
              L.circleMarker(coords[coords.length - 1], { radius: 6, color: '#fff', weight: 2, fillColor: '#ff3b30', fillOpacity: 1 }).addTo(map);

              // Marqueurs aux positions des médias (réutilise les vignettes de la galerie, sans dupliquer les images).
              Array.prototype.forEach.call(document.querySelectorAll('.media.locatable'), function(el){
                var plat = parseFloat(el.getAttribute('data-lat')), plon = parseFloat(el.getAttribute('data-lon'));
                if (isNaN(plat) || isNaN(plon)) return;
                var thumb = el.querySelector('img');
                var icon = L.divIcon({ className: 'gpx-photo-pin', html: '📷', iconSize: [26,26], iconAnchor: [13,13] });
                var mk = L.marker([plat, plon], { icon: icon }).addTo(map);
                if (thumb) mk.bindPopup('<img src="' + thumb.src + '" style="max-width:220px;max-height:220px;border-radius:6px;display:block">', { autoPan: true });
              });

              var el = document.getElementById('map');
              var fsBtn = null, pseudo = false;
              function nativeSupported(){ return !!(el.requestFullscreen || el.webkitRequestFullscreen); }
              function isNativeFs(){ return document.fullscreenElement === el || document.webkitFullscreenElement === el; }
              function active(){ return pseudo || isNativeFs(); }
              function refresh(){ setTimeout(function(){ map.invalidateSize(); map.fitBounds(L.latLngBounds(coords), { padding: [24, 24] }); if (fsBtn) fsBtn.innerHTML = active() ? '✕' : '⤢'; }, 160); }
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

              if (trackColors.speed || trackColors.slope) {
                var TrackCtl = L.Control.extend({
                  options: { position: 'topleft' },
                  onAdd: function(){
                    var div = L.DomUtil.create('div', 'leaflet-bar gpx-trackctl');
                    [['uniform','Uniforme'],['speed','Vitesse'],['slope','Pente']].forEach(function(m){
                      if ((m[0]==='speed' && !trackColors.speed) || (m[0]==='slope' && !trackColors.slope)) return;
                      var a = L.DomUtil.create('a', '', div); a.href = '#'; a.innerHTML = m[1];
                      if (m[0]===defaultMode) a.className = 'active';
                      L.DomEvent.on(a, 'click', function(e){ L.DomEvent.stop(e); drawTrack(m[0]); Array.prototype.forEach.call(div.children, function(c){ c.className=''; }); a.className='active'; });
                    });
                    L.DomEvent.disableClickPropagation(div);
                    return div;
                  }
                });
                map.addControl(new TrackCtl());
              }

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
                let loc = (item.lat != nil && item.lon != nil)
                let locAttrs = loc ? " data-lat=\"\(String(format: "%.6f", item.lat!))\" data-lon=\"\(String(format: "%.6f", item.lon!))\"" : ""
                let locClass = loc ? " locatable" : ""
                if item.isVideo {
                    let videoSrc = "images/video-\(i + 1).mp4"
                    let poster = item.poster != nil ? "images/poster-\(i + 1).jpg" : ""
                    return "<a class=\"media video\(locClass)\" data-type=\"video\" data-src=\"\(videoSrc)\"\(locAttrs) title=\"Lire la vidéo\"><img class=\"photo\" src=\"\(poster)\" alt=\"Vidéo \(i + 1)\" loading=\"lazy\"><span class=\"playbadge\">▶</span></a>"
                }
                let src = "images/photo-\(i + 1).jpg"
                return "<a class=\"media\(locClass)\" data-type=\"image\" data-src=\"\(src)\"\(locAttrs) title=\"Agrandir\"><img class=\"photo\" src=\"\(src)\" alt=\"Photo \(i + 1)\" loading=\"lazy\"></a>"
            }.joined()
            photosSection = "<section class=\"section\"><h2>Photos</h2><div class=\"photos\">\(grid)</div></section>"
                + "<div id=\"lightbox\" class=\"lightbox\"><span class=\"lb-close\">✕</span><div class=\"lb-content\"></div></div>"
            var scripts = lightboxJS
            if interactiveMap, assets.photos.contains(where: { $0.lat != nil }) { scripts += "\n" + photoMapJS }
            photoScript = "<script>\n\(scripts)\n</script>"
        }

        // Notes + source
        var notesSection = ""
        if options.includeNotes, let notes = activity.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
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
      var title = document.getElementById('profile-title');
      var ctx = canvas.getContext('2d');
      var mode = 'distance';
      var metric = D.hasAlt ? 'altitude' : 'speed';
      var dpr = window.devicePixelRatio || 1;
      var pad = { l: 54, r: 16, t: 12, b: 30 };
      var hover = -1;

      function series(){ return mode === 'distance' ? D.distance : D.time; }
      function css(v){ return getComputedStyle(document.body).getPropertyValue(v).trim() || '#999'; }
      function yAt(i){ return metric === 'speed' ? D.spd[i] : series().alt[i]; }
      function xDisp(x){ return mode === 'distance' ? x * D.distFactor : x; }
      function yUnit(){ return metric === 'speed' ? D.speedUnit : 'm'; }
      function segColor(s, i){
        if (metric === 'speed') return D.speedCats[D.scat[i]] || '#888';
        if (mode === 'distance') return D.cats[s.cat[i]] || '#888';
        return (D.paused && D.paused[i]==1) ? '#8e8e93' : (s.moving[i]==1 ? '#34c759' : '#8e8e93');
      }

      function resize(){
        var w = canvas.clientWidth;
        canvas.width = w * dpr; canvas.height = 300 * dpr;
        ctx.setTransform(dpr,0,0,dpr,0,0);
        draw();
      }

      function bounds(s){
        var xmin = s.x[0], xmax = s.x[s.x.length-1];
        var amin = Infinity, amax = -Infinity;
        for (var i=0;i<s.x.length;i++){ var y=yAt(i); if(y<amin)amin=y; if(y>amax)amax=y; }
        if (metric === 'speed') { amin = 0; }
        var padA = (amax-amin)*0.08 || 10;
        return { xmin:xmin, xmax:xmax, ymin:amin-(metric==='speed'?0:padA), ymax:amax+padA };
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
          var color = segColor(s, i);
          ctx.beginPath();
          ctx.moveTo(X(s.x[i]), pbt);
          ctx.lineTo(X(s.x[i]), Y(yAt(i)));
          ctx.lineTo(X(s.x[i+1]), Y(yAt(i+1)));
          ctx.lineTo(X(s.x[i+1]), pbt);
          ctx.closePath();
          ctx.fillStyle = color; ctx.globalAlpha = 0.75; ctx.fill(); ctx.globalAlpha = 1;
        }

        if (metric==='altitude' && mode==='time' && s.hr){
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
        for (var t=0;t<=4;t++){ var yv=b.ymin+(b.ymax-b.ymin)*t/4; var yy2=Y(yv); ctx.fillText(yv.toFixed(metric==='speed'?(yv<10?1:0):0)+' '+yUnit(), 4, yy2+3); ctx.globalAlpha=0.35; ctx.beginPath(); ctx.moveTo(pl,yy2); ctx.lineTo(pr,yy2); ctx.stroke(); ctx.globalAlpha=1; }
        for (var tx=0;tx<=5;tx++){ var xv=b.xmin+(b.xmax-b.xmin)*tx/5; var xx2=X(xv); var xd=xDisp(xv); ctx.fillText(xd.toFixed(xd<10?1:0), xx2-8, pbt+16); }
        var xlabel = mode==='distance' ? ('Distance ('+D.distUnit+')') : (s.axisLabel||'Temps');
        ctx.fillText(xlabel, (pl+pr)/2-30, H-4);

        if (hover>=0 && hover<s.x.length){
          var hx=X(s.x[hover]), hy=Y(yAt(hover));
          ctx.strokeStyle=css('--accent'); ctx.lineWidth=1; ctx.beginPath(); ctx.moveTo(hx,pt); ctx.lineTo(hx,pbt); ctx.stroke();
          ctx.fillStyle=css('--accent'); ctx.beginPath(); ctx.arc(hx,hy,4,0,Math.PI*2); ctx.fill();
        }
      }

      function showTip(s,i,px){
        var html;
        if (metric==='speed'){ html = '<b>'+D.spd[i].toFixed(1)+' '+D.speedUnit+'</b>'; }
        else { html = '<b>'+s.alt[i].toFixed(0)+' m</b>'; }
        if (mode==='distance'){ html += '  '+xDisp(s.x[i]).toFixed(2)+' '+D.distUnit; if (metric==='altitude') html += '  '+D.catLabels[s.cat[i]]; }
        else { html += '  '+s.x[i].toFixed(1)+((s.axisLabel||'').indexOf('min')>=0?' min':' h'); if (metric==='altitude' && s.hr && s.hr[i]!=null) html += '  '+s.hr[i]+' bpm'; }
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
        if (metric==='speed'){ for (var j=0;j<D.speedCats.length;j++){ html += '<span class="li"><i style="background:'+D.speedCats[j]+'"></i>'+D.speedLabels[j]+'</span>'; } }
        else if (mode==='distance'){ for (var i=0;i<D.cats.length;i++){ html += '<span class="li"><i style="background:'+D.cats[i]+'"></i>'+D.catLabels[i]+'</span>'; } }
        else { html += '<span class="li"><i style="background:#34c759"></i>En mouvement</span><span class="li"><i style="background:#8e8e93"></i>Pause</span>'; if (D.time.hr) html += '<span class="li"><i style="background:#ff3b30"></i>Fréquence cardiaque</span>'; }
        legend.innerHTML = html;
        if (title) title.textContent = metric==='speed' ? 'Profil de vitesse' : 'Profil altimétrique';
      }

      var modeBtns = Array.prototype.slice.call(document.querySelectorAll('.seg'));
      modeBtns.forEach(function(btn){
        btn.addEventListener('click', function(){
          var m = btn.getAttribute('data-mode');
          if (m==='time' && !D.time.available) return;
          mode = m;
          modeBtns.forEach(function(b){ b.classList.toggle('active', b===btn); });
          hover=-1; tip.style.opacity=0; buildLegend(); draw();
        });
      });
      if (!D.time.available){ modeBtns.forEach(function(b){ if(b.getAttribute('data-mode')==='time'){ b.disabled=true; b.style.opacity=0.4; b.style.cursor='not-allowed'; } }); }

      var metricBtns = Array.prototype.slice.call(document.querySelectorAll('.segm'));
      metricBtns.forEach(function(btn){
        btn.addEventListener('click', function(){
          var m = btn.getAttribute('data-metric');
          if (m==='altitude' && !D.hasAlt) return;
          metric = m;
          metricBtns.forEach(function(b){ b.classList.toggle('active', b===btn); });
          hover=-1; tip.style.opacity=0; buildLegend(); draw();
        });
      });
      if (!D.hasAlt){ metricBtns.forEach(function(b){ if(b.getAttribute('data-metric')==='altitude'){ b.disabled=true; b.style.opacity=0.4; b.style.cursor='not-allowed'; } b.classList.toggle('active', b.getAttribute('data-metric')==='speed'); }); }

      buildLegend();
      window.addEventListener('resize', resize);
      resize();
    })();
    """

    private static let photoMapJS = """
    (function(){
      var items = Array.prototype.slice.call(document.querySelectorAll('.media.locatable'));
      items.forEach(function(el){
        var lat = parseFloat(el.getAttribute('data-lat'));
        var lon = parseFloat(el.getAttribute('data-lon'));
        el.addEventListener('mouseenter', function(){ if (window.gpxShowPhoto) window.gpxShowPhoto(lat, lon, false); });
      });
    })();
    """

    /// Lightbox : clic sur une vignette → photo agrandie ou vidéo lisible en plein cadre.
    private static let lightboxJS = """
    (function(){
      var lb = document.getElementById('lightbox'); if (!lb) return;
      var content = lb.querySelector('.lb-content');
      function close(){ content.innerHTML = ''; lb.classList.remove('open'); }
      lb.addEventListener('click', function(e){ if (e.target === lb || e.target.classList.contains('lb-close')) close(); });
      document.addEventListener('keydown', function(e){ if (e.key === 'Escape') close(); });
      Array.prototype.forEach.call(document.querySelectorAll('.media'), function(el){
        el.addEventListener('click', function(e){
          e.preventDefault();
          var type = el.getAttribute('data-type'), src = el.getAttribute('data-src');
          content.innerHTML = (type === 'video')
            ? '<video src="' + src + '" controls autoplay playsinline></video>'
            : '<img src="' + src + '" alt="">';
          lb.classList.add('open');
        });
      });
    })();
    """

    private static func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func metricCard(_ icon: String, _ label: String, _ value: String) -> String {
        "<div class=\"card\"><span class=\"ic\">\(icon)</span><div class=\"mc\"><span class=\"v\">\(esc(value))</span><span class=\"l\">\(esc(label))</span></div></div>"
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
        .metrics { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:10px; margin-bottom:8px; }
        .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:10px 14px; display:flex; align-items:center; gap:10px; }
        .card .ic { font-size:18px; flex:0 0 auto; line-height:1; }
        .card .mc { display:flex; flex-direction:column; line-height:1.25; min-width:0; }
        .card .v { font-size:17px; font-weight:700; }
        .card .l { font-size:12px; color:var(--sec); }
        .section { margin-top:32px; }
        .section h2 { font-size:13px; text-transform:uppercase; letter-spacing:0.06em; color:var(--sec); margin:0 0 12px; }
        .section h3 { font-size:15px; font-weight:600; margin:18px 0 8px; }
        .map { width:100%; aspect-ratio:16/10; object-fit:cover; border-radius:14px; border:1px solid var(--line); display:block; background:var(--card); }
        .map.interactive { overflow:hidden; z-index:0; }
        .leaflet-container { background:var(--card); font:inherit; }
        .gpx-fs { font-size:18px; line-height:28px; text-align:center; width:30px; height:30px; cursor:pointer; text-decoration:none; color:#333; background:#fff; }
        .gpx-trackctl a { display:inline-block; padding:4px 9px; font:12px -apple-system,sans-serif; text-decoration:none; color:#333; background:#fff; border-right:1px solid #ccc; }
        .gpx-trackctl a:last-child { border-right:none; }
        .gpx-trackctl a.active { background:#0a84ff; color:#fff; }
        .gpx-photo-pin { font-size:18px; text-align:center; line-height:26px; cursor:pointer; filter:drop-shadow(0 1px 1px rgba(0,0,0,.5)); }
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
        .seg, .segm { font:13px inherit; padding:5px 12px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--fg); cursor:pointer; }
        .seg.active, .segm.active { background:var(--accent); color:#fff; border-color:var(--accent); }
        .chart-wrap { position:relative; width:100%; }
        #profile { width:100%; height:300px; display:block; cursor:crosshair; }
        .tip { position:absolute; pointer-events:none; background:rgba(0,0,0,0.82); color:#fff; font-size:12px; padding:6px 9px; border-radius:8px; transform:translate(-50%,-115%); white-space:nowrap; opacity:0; transition:opacity .08s; z-index:5; }
        .photos { display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:10px; }
        .photo { width:100%; aspect-ratio:1; object-fit:cover; border-radius:12px; border:1px solid var(--line); display:block; }
        .media { position:relative; display:block; cursor:pointer; }
        .media:hover .photo { filter:brightness(0.92); }
        .playbadge { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); width:46px; height:46px; line-height:46px; text-align:center; font-size:18px; color:#fff; background:rgba(0,0,0,0.5); border-radius:50%; }
        .lightbox { position:fixed; inset:0; background:rgba(0,0,0,0.88); display:none; align-items:center; justify-content:center; z-index:9999; }
        .lightbox.open { display:flex; }
        .lightbox .lb-content img, .lightbox .lb-content video { max-width:92vw; max-height:92vh; border-radius:8px; box-shadow:0 8px 40px rgba(0,0,0,0.5); }
        .lb-close { position:absolute; top:16px; right:20px; color:#fff; font-size:26px; cursor:pointer; opacity:0.85; }
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
