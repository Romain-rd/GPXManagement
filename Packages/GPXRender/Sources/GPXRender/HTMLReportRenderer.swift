import SwiftUI
import Charts
import AppKit
import MapKit
import Photos
import GPXCore
import GPXMapKit

public struct WebExportOptions: Codable {
    public init() {}

    public enum MapRendering: String, CaseIterable, Identifiable, Codable {
        case staticImage, interactive
        public var id: String { rawValue }
        public var label: String { self == .staticImage ? "Image statique" : "Carte interactive" }
    }
    public enum ProfileRendering: String, CaseIterable, Identifiable, Codable {
        case staticImage, interactive
        public var id: String { rawValue }
        public var label: String { self == .staticImage ? "Image statique" : "Graphique interactif" }
    }
    public enum Output: String, CaseIterable, Identifiable, Codable {
        case folder, publishBunny
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .folder:       return "Dossier"
            case .publishBunny: return "GPXManagement.net"
            }
        }
    }

    public var map: MapRendering = .interactive
    public var profile: ProfileRendering = .interactive
    public var output: Output = .folder
    public var includePhotos: Bool = true
    public var includeNotes: Bool = true
}

public enum HTMLReportError: Error, LocalizedError {
    case noTrackData
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .noTrackData:  return "Cette activité ne contient pas de trace."
        case .renderFailed: return "Échec de la génération de la page web."
        }
    }
}

@MainActor
public enum HTMLReportRenderer {
    public enum Output {
        case folder(files: [String: Data]) // contient "index.html"
    }

    public static func render(activity: ActivitySummary, repository: CoreDataActivityRepository, layer: MapLayer, options: WebExportOptions, photos: [PHAsset], publicBaseURL: String? = nil, hideDynamics: Bool = false) async throws -> Output {
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
        // Aperçu du lien partagé (og:image) : la carte du tracé sur fond IGN. En mode image statique on
        // réutilise la carte déjà produite ; en interactif on en génère une dédiée, uniquement à la publication.
        var previewRef: String?
        var previewPNG: Data?
        if mapPNG != nil {
            previewRef = "images/carte.png"
        } else if publicBaseURL != nil {
            previewPNG = await previewSnapshotPNG(points: points, activity: activity, layer: layer)
            if previewPNG != nil { previewRef = "images/apercu.png" }
        }
        let mapPoints = options.map == .interactive ? decimatedPoints(points, max: 2000) : []
        let trackCoords = mapPoints.map { (lat: $0.latitude, lon: $0.longitude) }
        let trackColors = mapPoints.isEmpty ? (speed: [String](), slope: [String]()) : trackColorHex(points: mapPoints, activityType: activity.activityType)

        let profile = ElevationProfileBuilder.build(points: points)
        let hasAltitude = !profile.isEmpty
        let workingProfile = hasAltitude ? profile : ElevationProfileBuilder.buildMotion(points: points)
        let (distanceSamples, distanceScale) = PDFReportRenderer.slopeRuns(from: profile, scale: activity.activityType.slopeScale)
        let timeProfile = PDFReportRenderer.movementRuns(from: profile)
        let bd = ElevationProfileBuilder.timeBreakdown(workingProfile, pauseMinSeconds: PDFReportRenderer.pauseMinSeconds, pauseRadiusMeters: PDFReportRenderer.pauseRadiusMeters)
        let movement = (moving: bd.ascending + bd.descending + bd.flat, paused: bd.paused,
                        ascending: bd.ascending, descending: bd.descending, flat: bd.flat)
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
            let mediaState = MediaStateCodec.decode(try? await repository.fetchMediaState(id: activity.id))
            let resolver = MediaTrackResolver(points: points)
            for asset in photos {
                let manual = mediaState[PhotoLibraryService.stableKey(for: asset)]?.posMeters
                let coord = PhotoLibraryService.resolvedCoordinate(for: asset, using: resolver, manualMeters: manual)
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
                             layer: layer, trackCoords: trackCoords, trackSpeedColors: trackColors.speed, trackSlopeColors: trackColors.slope, profilePayload: profilePayload,
                             ogImageRef: previewRef, publicBaseURL: publicBaseURL, hideDynamics: hideDynamics)

        do {
            var files: [String: Data] = ["index.html": html.data(using: .utf8) ?? Data()]
            if let map = mapPNG { files["images/carte.png"] = map }
            if let p = previewPNG { files["images/apercu.png"] = p }
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
    // Palette des étapes de PARCOURS : identique (couleurs et ordre) à MapTrackPalette de l'app (bleu, rouge, vert, orange).
    private static let routePalette = ["#1E88E5", "#E53935", "#43A047", "#FB8C00"]

    /// Génère le dossier d'un raid : page d'ensemble + une page complète par étape (réutilise `render`).
    public static func renderRaid(raid: Raid, members: [ActivitySummary], repository: CoreDataActivityRepository, layer: MapLayer, options: WebExportOptions, stagePhotos: [UUID: [PHAsset]], onProgress: ((Double, String) -> Void)? = nil) async throws -> [String: Data] {
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

    // MARK: - Parcours en étapes (page web mono-page, style app iPhone)

    private struct RouteStageVM {
        let index: Int; let name: String; let departure: String; let arrival: String; let dateText: String; let notes: String
        let distance: Double; let gain: Double; let coords: [(lat: Double, lon: Double)]; let color: String
        let pois: [(name: String, lat: Double, lon: Double)]
        let profile: [(d: Double, e: Double)]   // distance (m depuis le début de l'étape), altitude (m)
        let coverRef: String?                   // chemin relatif de la photo de couverture de l'étape, si présente
    }

    /// Profil altimétrique décimé d'une portion de trace : (distance depuis le début, altitude).
    private static func stageProfile(_ pts: [TrackPoint], max: Int = 140) -> [(d: Double, e: Double)] {
        let prof = ElevationProfileBuilder.build(points: pts)
        guard prof.count >= 2 else { return [] }
        let step = prof.count > max ? Double(prof.count) / Double(max) : 1
        var out: [(Double, Double)] = []
        var i = 0.0
        while Int(i) < prof.count { let p = prof[Int(i)]; out.append((p.distanceFromStart, p.altitude)); i += step }
        if let last = prof.last { out.append((last.distanceFromStart, last.altitude)) }
        return out
    }
    private struct RouteMarkerVM {
        let lat: Double; let lon: Double; let kind: String; let label: String; let name: String
    }

    /// Génère la page web d'un parcours en étapes : un seul `index.html`, tab bar fixe (Carte/Étapes/Profil/Infos),
    /// carte interactive colorée par étape. Phase 1 : onglet Carte complet ; Étapes/Infos basiques ; Profil à venir.
    public static func renderRoute(activity: ActivitySummary, repository: CoreDataActivityRepository, layer: MapLayer, options: WebExportOptions, stagePhotos: [UUID: [PHAsset]] = [:], publicBaseURL: String? = nil, onProgress: ((Double, String) -> Void)? = nil) async throws -> [String: Data] {
        guard let data = try await repository.fetchTrackData(id: activity.id), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data), points.count >= 2 else {
            throw HTMLReportError.noTrackData
        }
        onProgress?(0.2, "Étapes…")
        let stages = ((try? await repository.fetchStagesResolved(activityId: activity.id, points: points)) ?? []).sorted { $0.order < $1.order }
        let waypoints = RouteWaypointCodec.decode(try await repository.fetchRouteWaypointsData(id: activity.id))
        let tile = webTileLayer(for: layer)
        let accent = hex(activity.activityType.trackColor)

        // POIs (lieux nommés traversés) par étape (1-based), selon l'ordre des waypoints le long du parcours.
        var poisByStage: [Int: [(name: String, lat: Double, lon: Double)]] = [:]
        var sc = 1
        for (i, wp) in waypoints.enumerated() where i > 0 {
            let isLast = i == waypoints.count - 1
            if wp.role == .poi && !isLast {   // le dernier point = arrivée, jamais un POI
                poisByStage[sc, default: []].append(((wp.name ?? "").isEmpty ? "Point d'intérêt" : wp.name!, wp.latitude, wp.longitude))
            } else if wp.role == .stageStop || isLast {
                sc += 1
            }
        }

        let maxPerStage = max(200, 1800 / max(stages.count, 1))
        var stageVMs: [RouteStageVM] = []
        var files: [String: Data] = [:]
        if stages.isEmpty {
            stageVMs.append(RouteStageVM(index: 1, name: activity.title, departure: "", arrival: "", dateText: fmtDateShort(activity.startDate),
                                         notes: "", distance: activity.distance, gain: activity.elevationGain,
                                         coords: decimatedCoords(points, max: 1800), color: routePalette[0], pois: poisByStage[1] ?? [],
                                         profile: stageProfile(points), coverRef: nil))
        } else {
            let wpById = Dictionary(waypoints.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var prevArrival = waypoints.first?.name ?? ""
            for (i, s) in stages.enumerated() {
                let lo = max(0, min(s.startIndex, points.count - 1)), hi = max(0, min(s.endIndex, points.count - 1))
                let slice = lo <= hi ? Array(points[lo...hi]) : []
                let st = s.stats(in: points)
                // Dernière étape : elle se termine à l'arrivée du parcours (pas d'arrêt interne), son arrivée = dernier waypoint.
                var arrival = s.stopWaypointId.flatMap { wpById[$0]?.name } ?? ""
                if arrival.isEmpty, i == stages.count - 1 { arrival = waypoints.last?.name ?? "" }
                var coverRef: String?
                if options.includePhotos, let cov = s.coverImageData, !cov.isEmpty {
                    let rel = "images/etape-\(i + 1).\(imageExt(cov))"; files[rel] = cov; coverRef = rel
                }
                stageVMs.append(RouteStageVM(index: i + 1, name: s.name.isEmpty ? "Étape \(i + 1)" : s.name,
                                             departure: prevArrival, arrival: arrival,
                                             dateText: s.plannedDate.map { fmtDateShort($0) } ?? "",
                                             notes: options.includeNotes ? (s.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : "",
                                             distance: st.distance, gain: st.elevationGain,
                                             coords: decimatedCoords(slice, max: maxPerStage), color: routePalette[i % routePalette.count],
                                             pois: poisByStage[i + 1] ?? [], profile: stageProfile(slice), coverRef: coverRef))
                if !arrival.isEmpty { prevArrival = arrival }
            }
        }

        // Marqueurs : départ/arrivée/arrêts/POI (les points de tracé « shaping » ne sont pas montrés).
        var markers: [RouteMarkerVM] = []
        for (i, wp) in waypoints.enumerated() {
            let isFirst = i == 0, isLast = i == waypoints.count - 1
            let kind: String
            if isLast { kind = "arrival" } else if isFirst { kind = "departure" }
            else if wp.role == .stageStop { kind = "stop" } else if wp.role == .poi { kind = "poi" } else { continue }
            markers.append(RouteMarkerVM(lat: wp.latitude, lon: wp.longitude, kind: kind, label: "\(i + 1)", name: wp.name ?? ""))
        }

        var previewRef: String?
        if publicBaseURL != nil, let png = await previewSnapshotPNG(points: points, activity: activity, layer: layer) {
            files["images/apercu.png"] = png
            previewRef = "images/apercu.png"
        }

        onProgress?(0.6, "Page web…")
        let html = buildRouteHTML(activity: activity, stages: stageVMs, markers: markers, tile: tile, accent: accent,
                                  ogImageRef: previewRef, publicBaseURL: publicBaseURL)
        files["index.html"] = html.data(using: .utf8) ?? Data()
        return files
    }

    private static func buildRouteHTML(activity: ActivitySummary, stages: [RouteStageVM], markers: [RouteMarkerVM], tile: WebTileLayer, accent: String, ogImageRef: String? = nil, publicBaseURL: String? = nil) -> String {
        let totalKm = fmtDistance(activity.distance)
        let totalGain = "\(Int(activity.elevationGain.rounded())) m"
        let n = stages.count
        let dates = stages.compactMap { $0.dateText.isEmpty ? nil : $0.dateText }
        let dateRange = dates.first.map { f in dates.count > 1 ? "\(f) → \(dates.last!)" : f } ?? fmtDateShort(activity.startDate)
        let summary = "\(totalKm) · +\(totalGain) · \(n) étape\(n > 1 ? "s" : "")" + (dateRange.isEmpty ? "" : " · " + dateRange)

        let stageRows = stages.map { s -> String in
            let meta = [s.dateText, fmtDistance(s.distance), "+\(Int(s.gain.rounded())) m"].filter { !$0.isEmpty }.joined(separator: " · ")
            let route = (s.departure.isEmpty || s.arrival.isEmpty) ? esc(s.name) : "\(esc(s.departure)) → \(esc(s.arrival))"
            return "<a class=\"st-row\" data-stage=\"\(s.index)\"><span class=\"st-badge\" style=\"background:\(s.color)\">J\(s.index)</span><div class=\"st-info\"><span class=\"st-title\">\(route)</span><span class=\"st-meta\">\(esc(meta))</span></div><span class=\"st-chev\">›</span></a>"
        }.joined()
        let chips = stages.map { "<a class=\"ed-chip\" data-go=\"\($0.index)\">J\($0.index)</a>" }.joined()
        let stagesJS = stages.map { s -> String in
            let coords = "[" + s.coords.map { String(format: "[%.6f,%.6f]", $0.lat, $0.lon) }.joined(separator: ",") + "]"
            let pois = "[" + s.pois.map { "{name:\(jsString($0.name)),lat:\(String(format: "%.6f", $0.lat)),lon:\(String(format: "%.6f", $0.lon))}" }.joined(separator: ",") + "]"
            let prof = "[" + s.profile.map { "[\(Int($0.d)),\(Int($0.e))]" }.joined(separator: ",") + "]"
            let cover = s.coverRef.map { jsString($0) } ?? "null"
            return "{i:\(s.index),name:\(jsString(s.name)),dep:\(jsString(s.departure)),arr:\(jsString(s.arrival)),date:\(jsString(s.dateText)),dist:\(jsString(fmtDistance(s.distance))),gain:\(jsString("+\(Int(s.gain.rounded())) m")),color:\(jsString(s.color)),notes:\(jsString(s.notes)),coords:\(coords),pois:\(pois),prof:\(prof),cover:\(cover)}"
        }.joined(separator: ",")

        let infoCards = [
            metricCard("📏", "Distance", totalKm),
            metricCard("⬆️", "Dénivelé +", totalGain),
            metricCard("📍", "Étapes", "\(n)"),
            metricCard("📅", "Dates", dateRange.isEmpty ? "—" : dateRange)
        ].joined()
        let covers = stages.compactMap { s in s.coverRef.map { (s.index, $0) } }
        let gallery = covers.isEmpty ? "" : "<section class=\"section gallery-sec\"><h2>Photos</h2><div class=\"gallery\">" + covers.map { "<a class=\"gthumb\" data-go=\"\($0.0)\"><img src=\"\($0.1)\" alt=\"\" loading=\"lazy\"></a>" }.joined() + "</div></section>"

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(esc(activity.title))</title>
        \(ogMeta(title: activity.title, description: summary, imageRef: ogImageRef, baseURL: publicBaseURL))
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css">
        <script src="https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"></script>
        <style>\(css(accent: accent))\(routeCSS)</style>
        </head>
        <body>
        <div class="route-app">
          <div class="tab-views">
            <section class="tabview active" id="tab-carte">
              <div id="map" class="route-map"></div>
              <div class="map-banner"><strong>\(esc(activity.title))</strong><span>\(esc(summary))</span></div>
            </section>
            <section class="tabview" id="tab-etapes">
              <div id="etapes-list">
                <header class="tv-head"><h1>Étapes</h1></header>
                <div class="st-list">\(stageRows)</div>
              </div>
              <div id="etape-detail" hidden>
                <header class="ed-head">
                  <a class="ed-back">‹ Étapes</a>
                  <div class="ed-chips">\(chips)</div>
                </header>
                <div id="stage-map" class="ed-map"></div>
                <div class="ed-body">
                  <h2 id="ed-title"></h2>
                  <p id="ed-meta"></p>
                  <div id="ed-profile" class="prof"></div>
                  <img id="ed-cover" class="ed-cover" hidden alt="">
                  <div id="ed-pois"></div>
                  <p id="ed-notes" class="notes"></p>
                </div>
                <div class="ed-nav"><a id="ed-prev" class="ed-navbtn"></a><a id="ed-next" class="ed-navbtn"></a></div>
              </div>
            </section>
            <section class="tabview" id="tab-profil">
              <header class="tv-head"><h1>Profil</h1><p class="tv-sub">\(esc("\(totalKm) · +\(totalGain)"))</p></header>
              <div id="global-profile" class="prof prof-global"></div>
              <div class="prof-legend">\(stages.map { "<span class=\"li\"><i style=\"background:\($0.color)\"></i>J\($0.index)</span>" }.joined())</div>
            </section>
            <section class="tabview" id="tab-infos">
              <header class="tv-head"><h1>\(esc(activity.title))</h1><p class="tv-sub">\(esc(summary))</p></header>
              <section class="metrics">\(infoCards)</section>
              \(gallery)
            </section>
          </div>
          <nav class="tabbar">
            <a class="tabitem active" data-tab="carte">\(tabIcon("carte"))<span class="ti-l">Carte</span></a>
            <a class="tabitem" data-tab="etapes">\(tabIcon("etapes"))<span class="ti-l">Étapes</span></a>
            <a class="tabitem" data-tab="profil">\(tabIcon("profil"))<span class="ti-l">Profil</span></a>
            <a class="tabitem" data-tab="infos">\(tabIcon("infos"))<span class="ti-l">Infos</span></a>
          </nav>
        </div>
        <script>window.__stages=[\(stagesJS)];</script>
        \(routeMapScript(stages: stages, markers: markers, tile: tile, accent: accent))
        \(stageDetailScript(tile: tile))
        \(profileScript())
        <script>
        (function(){
          var items = [].slice.call(document.querySelectorAll('.tabitem'));
          var views = {};
          [].slice.call(document.querySelectorAll('.tabview')).forEach(function(v){ views[v.id.replace('tab-','')] = v; });
          function show(tab){
            items.forEach(function(it){ it.classList.toggle('active', it.getAttribute('data-tab') === tab); });
            Object.keys(views).forEach(function(k){ views[k].classList.toggle('active', k === tab); });
            if (tab === 'etapes' && window.__closeStage) window.__closeStage();
            if (tab === 'carte' && window.__routeMap) { setTimeout(function(){ window.__routeMap.invalidateSize(); }, 60); }
          }
          window.__showTab = show;
          items.forEach(function(it){ it.addEventListener('click', function(){ show(it.getAttribute('data-tab')); }); });
          [].slice.call(document.querySelectorAll('.st-row')).forEach(function(r){ r.addEventListener('click', function(){ if (window.__openStage) window.__openStage(+r.getAttribute('data-stage') - 1); }); });
          [].slice.call(document.querySelectorAll('.gthumb')).forEach(function(g){ g.addEventListener('click', function(){ show('etapes'); if (window.__openStage) window.__openStage(+g.getAttribute('data-go') - 1); }); });
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func routeMapScript(stages: [RouteStageVM], markers: [RouteMarkerVM], tile: WebTileLayer, accent: String) -> String {
        let groups = stages.map { s -> String in
            let coords = "[" + s.coords.map { String(format: "[%.6f,%.6f]", $0.lat, $0.lon) }.joined(separator: ",") + "]"
            return "{color:\(jsString(s.color)),coords:\(coords)}"
        }.joined(separator: ",")
        let mk = markers.map { m in
            "{lat:\(String(format: "%.6f", m.lat)),lon:\(String(format: "%.6f", m.lon)),kind:\(jsString(m.kind)),label:\(jsString(m.label)),name:\(jsString(m.name))}"
        }.joined(separator: ",")
        return """
        <script>
        (function(){
          var groups = [\(groups)];
          var markers = [\(mk)];
          var map = L.map('map', { scrollWheelZoom: true });
          window.__routeMap = map;
          L.tileLayer(\(jsString(tile.urlTemplate)), { maxZoom: \(tile.maxZoom), attribution: \(jsString(tile.attribution)) }).addTo(map);
          var lines = [];
          groups.forEach(function(g){ if (g.coords.length) { lines.push(L.polyline(g.coords, { color:g.color, weight:5, opacity:0.95 }).addTo(map)); } });
          function badge(txt,color){ return L.divIcon({ className:'rm-wrap', html:'<div class="rm-badge" style="background:'+color+'">'+txt+'</div>', iconSize:[30,22], iconAnchor:[15,11] }); }
          function dot(color){ return L.divIcon({ className:'rm-wrap', html:'<div class="rm-dot" style="background:'+color+'"></div>', iconSize:[14,14], iconAnchor:[7,7] }); }
          var S = window.__stages || [];
          // Départ
          if (groups.length && groups[0].coords.length) {
            L.marker(groups[0].coords[0], { icon: L.divIcon({ className:'rm-wrap', html:'<div class="rm-pin" style="background:#3cb44b">⚑</div>', iconSize:[24,24], iconAnchor:[12,12] }) }).addTo(map).bindTooltip('Départ');
          }
          // Badge Jn (couleur de l'étape) à l'arrivée de chaque étape — clic → ouvre l'étape.
          groups.forEach(function(g,i){ var c=g.coords; if(!c.length) return;
            var b = L.marker(c[c.length-1], { icon: badge('J'+(i+1), g.color) }).addTo(map);
            var s = S[i]; if (s) b.bindTooltip('J'+(i+1)+' · '+((s.dep && s.arr) ? (s.dep + ' → ' + s.arr) : (s.name||'')));
            b.on('click', function(){ if (window.__showTab) window.__showTab('etapes'); if (window.__openStage) window.__openStage(i); });
          });
          // POI
          markers.forEach(function(m){ if(m.kind!=='poi') return; var mk = L.marker([m.lat, m.lon], { icon: dot('#f58231') }).addTo(map); if (m.name) mk.bindTooltip(m.name); });
          if (lines.length) map.fitBounds(L.featureGroup(lines).getBounds(), { padding:[28,28] });
          var el = document.getElementById('map'), pseudo=false, fsBtn=null;
          function nat(){ return !!(el.requestFullscreen||el.webkitRequestFullscreen); }
          function isFs(){ return document.fullscreenElement===el||document.webkitFullscreenElement===el; }
          function refresh(){ setTimeout(function(){ map.invalidateSize(); if(fsBtn) fsBtn.innerHTML=(pseudo||isFs())?'✕':'⤢'; },160); }
          function toggle(){ if(nat()){ if(!isFs()){(el.requestFullscreen||el.webkitRequestFullscreen).call(el);} else {(document.exitFullscreen||document.webkitExitFullscreen).call(document);} } else { pseudo=!pseudo; el.classList.toggle('gpx-pseudo-fs',pseudo); document.body.classList.toggle('gpx-fs-lock',pseudo); refresh(); } }
          var Fs=L.Control.extend({ options:{position:'topright'}, onAdd:function(){ fsBtn=L.DomUtil.create('a','leaflet-bar leaflet-control gpx-fs'); fsBtn.href='#'; fsBtn.innerHTML='⤢'; L.DomEvent.on(fsBtn,'click',function(e){ L.DomEvent.stop(e); toggle(); }); return fsBtn; } });
          map.addControl(new Fs());
          document.addEventListener('fullscreenchange',refresh); document.addEventListener('webkitfullscreenchange',refresh);
        })();
        </script>
        """
    }

    private static func stageDetailScript(tile: WebTileLayer) -> String {
        return """
        <script>
        (function(){
          var S = window.__stages || [];
          var detail = document.getElementById('etape-detail'), list = document.getElementById('etapes-list');
          if (!detail || !list) return;
          var smap = null, slayers = [], cur = 0;
          function pin(glyph,bg){ return L.divIcon({ className:'rm-wrap', html:'<div class="rm-pin" style="background:'+bg+'">'+glyph+'</div>', iconSize:[24,24], iconAnchor:[12,12] }); }
          function poiDot(){ return L.divIcon({ className:'rm-wrap', html:'<div class="rm-dot" style="background:#f58231"></div>', iconSize:[14,14], iconAnchor:[7,7] }); }
          function ensureMap(){
            if (smap) return;
            smap = L.map('stage-map', { scrollWheelZoom:true });
            L.tileLayer(\(jsString(tile.urlTemplate)), { maxZoom:\(tile.maxZoom), attribution:\(jsString(tile.attribution)) }).addTo(smap);
          }
          function draw(i){
            ensureMap();
            slayers.forEach(function(l){ smap.removeLayer(l); }); slayers = [];
            S.forEach(function(s,k){ if (!s.coords.length) return; var a = k===i;
              slayers.push(L.polyline(s.coords, { color: a ? s.color : '#b9b9bd', weight: a ? 6 : 3, opacity: a ? 0.95 : 0.45 }).addTo(smap)); });
            (S[i].pois||[]).forEach(function(p){ var m = L.marker([p.lat,p.lon], { icon: poiDot() }).addTo(smap); if (p.name) m.bindTooltip(p.name); slayers.push(m); });
            var c = S[i].coords;
            if (c.length){
              slayers.push(L.marker(c[0], { icon: pin('⚑','#3cb44b') }).addTo(smap));
              slayers.push(L.marker(c[c.length-1], { icon: L.divIcon({ className:'rm-wrap', html:'<div class="rm-badge" style="background:'+S[i].color+'">J'+(i+1)+'</div>', iconSize:[30,22], iconAnchor:[15,11] }) }).addTo(smap));
              setTimeout(function(){ smap.invalidateSize(); smap.fitBounds(L.latLngBounds(c), { padding:[26,26] }); }, 30);
            }
          }
          function open(i){
            if (i<0 || i>=S.length) return;
            cur = i; var s = S[i];
            document.getElementById('ed-title').textContent = (s.dep && s.arr) ? (s.dep + ' → ' + s.arr) : (s.name || 'Étape');
            document.getElementById('ed-meta').textContent = [s.date, s.dist, s.gain].filter(Boolean).join(' · ');
            if (window.__buildProfile) window.__buildProfile(document.getElementById('ed-profile'), [{ color: s.color, pts: s.prof || [] }]);
            var cv = document.getElementById('ed-cover'); if (s.cover){ cv.src = s.cover; cv.hidden = false; } else { cv.hidden = true; cv.removeAttribute('src'); }
            var pe = document.getElementById('ed-pois'); pe.innerHTML = '';
            if (s.pois && s.pois.length){
              var t = document.createElement('div'); t.className = 'ed-poi-title'; t.textContent = 'Points d\\u2019intérêt'; pe.appendChild(t);
              s.pois.forEach(function(p){ var d = document.createElement('div'); d.className = 'ed-poi'; d.textContent = '\\uD83D\\uDCCD ' + (p.name || ''); pe.appendChild(d); });
            }
            var notes = document.getElementById('ed-notes'); notes.textContent = s.notes || ''; notes.style.display = s.notes ? '' : 'none';
            [].slice.call(document.querySelectorAll('.ed-chip')).forEach(function(c){ c.classList.toggle('active', +c.getAttribute('data-go') === i+1); });
            var p = document.getElementById('ed-prev'), n = document.getElementById('ed-next');
            p.textContent = i>0 ? '‹ J'+i : ''; p.style.visibility = i>0 ? 'visible' : 'hidden';
            n.textContent = i<S.length-1 ? 'J'+(i+2)+' ›' : ''; n.style.visibility = i<S.length-1 ? 'visible' : 'hidden';
            list.hidden = true; detail.hidden = false;
            var tv = document.getElementById('tab-etapes'); if (tv) tv.scrollTop = 0;
            draw(i);
          }
          window.__openStage = open;
          window.__closeStage = function(){ detail.hidden = true; list.hidden = false; };
          var back = document.querySelector('.ed-back'); if (back) back.addEventListener('click', window.__closeStage);
          document.getElementById('ed-prev').addEventListener('click', function(){ if (cur>0) open(cur-1); });
          document.getElementById('ed-next').addEventListener('click', function(){ if (cur<S.length-1) open(cur+1); });
          [].slice.call(document.querySelectorAll('.ed-chip')).forEach(function(c){ c.addEventListener('click', function(){ open(+c.getAttribute('data-go')-1); }); });
          var sx=0, sy=0;
          detail.addEventListener('touchstart', function(e){ sx=e.touches[0].clientX; sy=e.touches[0].clientY; }, {passive:true});
          detail.addEventListener('touchend', function(e){ var dx=e.changedTouches[0].clientX-sx, dy=e.changedTouches[0].clientY-sy; if (Math.abs(dx)>60 && Math.abs(dx)>Math.abs(dy)){ if (dx<0) open(cur+1); else open(cur-1); } }, {passive:true});
        })();
        </script>
        """
    }

    /// Icône d'onglet, style SF Symbols (trait monochrome `currentColor`).
    private static func tabIcon(_ id: String) -> String {
        let body: String
        switch id {
        case "carte":  body = #"<path d="M9 4 3.5 6v14L9 18l6 2 5.5-2V4L15 6 9 4Z"/><path d="M9 4v14M15 6v14"/>"#
        case "etapes": body = #"<path d="M8.5 6h11M8.5 12h11M8.5 18h11" stroke-linecap="round"/><circle cx="4.3" cy="6" r="1.15" fill="currentColor" stroke="none"/><circle cx="4.3" cy="12" r="1.15" fill="currentColor" stroke="none"/><circle cx="4.3" cy="18" r="1.15" fill="currentColor" stroke="none"/>"#
        case "profil": body = #"<path d="M3.5 4v15a1 1 0 0 0 1 1H20" stroke-linecap="round"/><path d="M7 14.5l3.2-4 3 2 4.3-6.2" stroke-linecap="round" stroke-linejoin="round"/>"#
        default:       body = #"<circle cx="12" cy="12" r="8.4"/><path d="M12 11v5" stroke-linecap="round"/><circle cx="12" cy="7.6" r="1.05" fill="currentColor" stroke="none"/>"#
        }
        return "<svg class=\"ti-ic\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\">\(body)</svg>"
    }

    private static func profileScript() -> String {
        return """
        <script>
        window.__buildProfile = function(container, segments){
          if (!container) return;
          var all = []; segments.forEach(function(s){ all = all.concat(s.pts || []); });
          if (all.length < 2){ container.innerHTML = ''; return; }
          var W = 1000, H = 200, pad = 16;
          var minX = all[0][0], maxX = all[all.length-1][0];
          var minE = Infinity, maxE = -Infinity;
          all.forEach(function(p){ if (p[1] < minE) minE = p[1]; if (p[1] > maxE) maxE = p[1]; });
          if (maxE - minE < 1) maxE = minE + 1; if (maxX - minX < 1) maxX = minX + 1;
          function X(x){ return (pad + (x - minX) / (maxX - minX) * (W - 2*pad)); }
          function Y(e){ return (H - pad - (e - minE) / (maxE - minE) * (H - 2*pad)); }
          var svg = '<svg viewBox="0 0 '+W+' '+H+'" preserveAspectRatio="none" class="prof-svg">';
          segments.forEach(function(s){ var pts = s.pts || []; if (pts.length < 2) return;
            var area = 'M' + X(pts[0][0]).toFixed(1) + ' ' + (H-pad);
            pts.forEach(function(p){ area += ' L' + X(p[0]).toFixed(1) + ' ' + Y(p[1]).toFixed(1); });
            area += ' L' + X(pts[pts.length-1][0]).toFixed(1) + ' ' + (H-pad) + ' Z';
            svg += '<path d="'+area+'" fill="'+s.color+'" fill-opacity="0.22"/>';
            var line = ''; pts.forEach(function(p,i){ line += (i?' L':'M') + X(p[0]).toFixed(1) + ' ' + Y(p[1]).toFixed(1); });
            svg += '<path d="'+line+'" fill="none" stroke="'+s.color+'" stroke-width="2" vector-effect="non-scaling-stroke"/>';
          });
          svg += '</svg>';
          container.innerHTML = svg + '<div class="prof-cap"><span>'+Math.round(maxE)+' m</span><span>'+Math.round(minE)+' m</span></div>';
        };
        (function(){
          var S = window.__stages || [], segs = [], off = 0;
          S.forEach(function(s){ var pts = (s.prof || []).map(function(p){ return [off + p[0], p[1]]; }); segs.push({ color: s.color, pts: pts }); if (s.prof && s.prof.length) off += s.prof[s.prof.length-1][0]; });
          window.__buildProfile(document.getElementById('global-profile'), segs);
        })();
        </script>
        """
    }

    private static let routeCSS = """
    /* Mobile : c'est le DOCUMENT qui défile (la barre Safari se replie au scroll), tab bar en position fixe. */
    :root { --tabbar-h:56px; }
    html, body { margin:0; }
    .route-app { display:block; }
    .tab-views { display:block; }
    .tabview { display:none; }
    .tabview.active { display:block; padding-bottom:calc(var(--tabbar-h) + env(safe-area-inset-bottom)); }
    #tab-carte.active { display:block; }
    /* Carte d'accueil : plein écran immersif, sous le notch en haut, jusqu'à la tab bar en bas. */
    .route-map { position:fixed; top:0; left:0; right:0; bottom:calc(var(--tabbar-h) + env(safe-area-inset-bottom)); width:auto; height:auto; background:var(--card); z-index:0; }
    .route-map .leaflet-top { padding-top:env(safe-area-inset-top); }
    .route-map .leaflet-bottom { margin-bottom:52px; }
    .map-banner { position:fixed; left:0; right:0; bottom:calc(var(--tabbar-h) + env(safe-area-inset-bottom)); z-index:5; background:color-mix(in srgb, var(--card) 82%, transparent); -webkit-backdrop-filter:saturate(180%) blur(16px); backdrop-filter:saturate(180%) blur(16px); border-top:1px solid color-mix(in srgb, var(--line) 55%, transparent); padding:10px 16px; display:flex; flex-direction:column; gap:1px; }
    .map-banner strong { font-size:16px; font-weight:700; letter-spacing:-.01em; }
    .map-banner span { font-size:13px; color:var(--sec); }
    .tv-head { padding:18px 16px 6px; }
    .tv-head h1 { margin:0; font-size:24px; font-weight:800; letter-spacing:-.02em; }
    .tv-sub { margin:5px 0 0; color:var(--sec); font-size:14px; }
    .tv-empty { padding:24px 16px; color:var(--sec); }
    .metrics { padding:10px 16px 28px; }
    .st-list { padding:4px 12px 28px; }
    .st-row { display:flex; align-items:center; gap:12px; padding:13px 8px; text-decoration:none; color:var(--fg); border-bottom:1px solid var(--line); cursor:pointer; }
    .st-row:active { background:var(--card); }
    .st-badge { flex:0 0 auto; width:38px; height:38px; border-radius:10px; color:#fff; font-weight:700; display:inline-flex; align-items:center; justify-content:center; font-size:13px; }
    .st-info { display:flex; flex-direction:column; min-width:0; flex:1; }
    .st-title { font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .st-meta { font-size:13px; color:var(--sec); }
    .st-chev { color:var(--sec); font-size:22px; flex:0 0 auto; }
    .tabbar { position:fixed; left:0; right:0; bottom:0; z-index:100; display:flex; background:color-mix(in srgb, var(--card) 78%, transparent); -webkit-backdrop-filter:saturate(180%) blur(20px); backdrop-filter:saturate(180%) blur(20px); border-top:1px solid color-mix(in srgb, var(--line) 55%, transparent); padding-bottom:env(safe-area-inset-bottom); }
    .tabitem { flex:1; display:flex; flex-direction:column; align-items:center; gap:3px; padding:8px 0 6px; color:var(--sec); text-decoration:none; font-size:10px; font-weight:500; letter-spacing:.01em; cursor:pointer; -webkit-tap-highlight-color:transparent; transition:color .15s; }
    .tabitem.active { color:var(--accent); }
    .tabitem .ti-ic { width:27px; height:27px; display:block; }
    .rm-wrap { background:transparent; border:0; }
    .rm-pin { width:24px; height:24px; border-radius:50%; color:#fff; font-size:12px; font-weight:700; display:flex; align-items:center; justify-content:center; border:2px solid #fff; box-shadow:0 1px 3px rgba(0,0,0,.4); }
    .rm-badge { min-width:22px; height:22px; padding:0 6px; border-radius:7px; color:#fff; font-size:12px; font-weight:700; display:flex; align-items:center; justify-content:center; border:2px solid #fff; box-shadow:0 1px 3px rgba(0,0,0,.45); white-space:nowrap; }
    .rm-dot { width:14px; height:14px; border-radius:50%; border:2px solid #fff; box-shadow:0 1px 2px rgba(0,0,0,.4); }
    /* Détail d'étape */
    #etape-detail:not([hidden]) { display:block; }
    .ed-head { display:flex; align-items:center; gap:10px; padding:9px 12px; border-bottom:1px solid var(--line); flex:0 0 auto; position:sticky; top:0; background:var(--bg); z-index:3; }
    .ed-back { color:var(--accent); cursor:pointer; font-weight:600; white-space:nowrap; }
    .ed-chips { display:flex; gap:6px; overflow-x:auto; -webkit-overflow-scrolling:touch; }
    .ed-chip { flex:0 0 auto; padding:5px 12px; border-radius:999px; background:var(--card); border:1px solid var(--line); color:var(--sec); cursor:pointer; font-size:13px; font-weight:600; text-decoration:none; }
    .ed-chip.active { background:var(--accent); color:#fff; border-color:var(--accent); }
    .ed-map { width:100%; height:55vh; min-height:300px; background:var(--card); z-index:0; }
    .ed-body { padding:18px 16px; flex:0 0 auto; }
    .ed-body h2 { margin:0 0 6px; font-size:22px; font-weight:700; letter-spacing:-.01em; }
    #ed-meta { margin:0 0 14px; color:var(--sec); font-size:15px; }
    .prof { position:relative; margin:0 0 16px; }
    .prof-svg { width:100%; height:130px; display:block; border-radius:10px; background:var(--card); border:1px solid var(--line); }
    .prof-global { padding:0 16px; }
    .prof-global .prof-svg { height:210px; }
    .prof-cap span { position:absolute; left:8px; font-size:11px; color:var(--sec); background:var(--card); padding:0 3px; border-radius:3px; }
    .prof-global .prof-cap span { left:24px; }
    .prof-cap span:first-child { top:5px; }
    .prof-cap span:last-child { bottom:8px; }
    .prof-legend { display:flex; flex-wrap:wrap; gap:12px; padding:10px 16px 24px; font-size:13px; color:var(--sec); }
    .prof-legend .li { display:inline-flex; align-items:center; gap:5px; }
    .prof-legend i { width:11px; height:11px; border-radius:3px; display:inline-block; }
    .ed-cover { width:100%; border-radius:12px; border:1px solid var(--line); display:block; margin:0 0 16px; max-height:340px; object-fit:cover; }
    .gallery-sec { padding:0 16px 28px; }
    .gallery { display:grid; grid-template-columns:repeat(auto-fill,minmax(120px,1fr)); gap:8px; }
    .gthumb { display:block; cursor:pointer; }
    .gthumb img { width:100%; aspect-ratio:1; object-fit:cover; border-radius:10px; border:1px solid var(--line); }
    #ed-pois { margin:0 0 14px; }
    .ed-poi-title { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--sec); margin:0 0 6px; }
    .ed-poi { padding:4px 0; border-bottom:1px solid var(--line); }
    .ed-poi:last-child { border-bottom:0; }
    .ed-nav { display:flex; justify-content:space-between; align-items:center; gap:10px; padding:12px 14px; background:var(--card); border-top:1px solid var(--line); min-height:22px; }
    .ed-navbtn { color:var(--accent); cursor:pointer; font-weight:600; padding:6px 8px; }
    @media (min-width:920px) {
      /* Desktop : coquille à hauteur fixe, rail à gauche, contenu en scroll interne (pas de scroll document). */
      .route-app { display:flex; flex-direction:row; height:100dvh; }
      .tab-views { flex:1; position:relative; min-width:0; }
      .tabview { position:absolute; inset:0; overflow-y:auto; }
      .tabview.active { padding-bottom:0; }
      #tab-carte.active { display:flex; flex-direction:column; }
      .route-map { position:static; inset:auto; flex:1; width:100%; height:auto; min-height:0; }
      .route-map .leaflet-top { padding-top:0; }
      .route-map .leaflet-bottom { margin-bottom:0; }
      .map-banner { position:static; }
      .tabbar { position:static; order:-1; flex-direction:column; width:210px; flex:0 0 auto; height:auto; border-top:0; border-right:1px solid var(--line); padding:18px 10px; gap:4px; align-content:flex-start; }
      .tabitem { flex:0 0 auto; flex-direction:row; gap:12px; justify-content:flex-start; padding:12px 16px; font-size:15px; border-radius:10px; }
      .tabitem.active { background:var(--bg); }
      .tabitem .ti-ic { width:23px; height:23px; }
      #etape-detail:not([hidden]) { display:flex; flex-direction:column; min-height:100%; }
      .ed-map { flex:1 0 auto; height:auto; min-height:60vh; }
      .ed-head { position:sticky; top:0; }
      .ed-nav { position:sticky; bottom:0; }
    }
    """

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

        // Pauses calculées sur le profil PLEIN (la décimation fausse la détection par rayon) → plages temporelles.
        // Un point est « en pause » s'il borde un segment du profil décimé qui chevauche une plage → bande plate à zéro.
        let pausedRanges = ElevationProfileBuilder.pausedTimeRanges(profile, pauseMinSeconds: PDFReportRenderer.pauseMinSeconds, pauseRadiusMeters: PDFReportRenderer.pauseRadiusMeters)
        func segOverlapsPause(_ a: Int, _ b: Int) -> Bool {
            guard !pausedRanges.isEmpty, let ta = pts[a].timestamp, let tb = pts[b].timestamp else { return false }
            return pausedRanges.contains { ta < $0.upperBound && $0.lowerBound < tb }
        }
        func isPausedPt(_ i: Int) -> Bool {
            (i + 1 < pts.count && segOverlapsPause(i, i + 1)) || (i > 0 && segOverlapsPause(i - 1, i))
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

    private static func buildHTML(activity: ActivitySummary, assets: HTMLAssets, options: WebExportOptions, slopeLegend: [LegendItem], movement: (moving: TimeInterval, paused: TimeInterval, ascending: TimeInterval, descending: TimeInterval, flat: TimeInterval), hasHeartRate: Bool, layer: MapLayer, trackCoords: [(lat: Double, lon: Double)], trackSpeedColors: [String] = [], trackSlopeColors: [String] = [], profilePayload: String, ogImageRef: String? = nil, publicBaseURL: String? = nil, hideDynamics: Bool = false) -> String {
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
            metricCard("⬇️", "Dénivelé −", "\(Int(activity.elevationLoss.rounded())) m")
        ]
        // Parcours planifié (hideDynamics) : pas de temps / vitesse / FC (aucune donnée réelle enregistrée).
        if !hideDynamics {
            cards.append(metricCard("🕐", "Durée totale", fmtDuration(activity.duration)))
            cards.append(metricCard("⏱️", "En mouvement", fmtDuration(movement.moving)))
            // Mêmes temps que l'app : pause + répartition montée/descente/à plat (somme = durée totale), quand disponibles.
            if movement.paused > 0 { cards.append(metricCard("⏸️", "En pause", fmtDuration(movement.paused))) }
            if movement.ascending > 0 { cards.append(metricCard("↗️", "Temps en montée", fmtDuration(movement.ascending))) }
            if movement.descending > 0 { cards.append(metricCard("↘️", "Temps en descente", fmtDuration(movement.descending))) }
            if movement.flat > 0 { cards.append(metricCard("➡️", "Temps à plat", fmtDuration(movement.flat))) }
            cards.append(metricCard("💨", "Vitesse moy.", speedStr(activity.avgSpeed)))
            cards.append(metricCard("⚡️", "Vitesse max", speedStr(activity.maxSpeed)))
            if let hr = activity.avgHeartRate { cards.append(metricCard("❤️", "FC moyenne", "\(Int(hr.rounded())) bpm")) }
            if let hr = activity.maxHeartRate { cards.append(metricCard("❤️", "FC max", "\(Int(hr.rounded())) bpm")) }
        }

        // Profils (statiques en images, ou graphique interactif canvas)
        var profileSection = ""
        var profileScript = ""
        if interactiveProfile {
            // Parcours planifié : pas de choix Vitesse/Temps (aucune donnée temporelle) → uniquement altitude/distance.
            let toolbar = hideDynamics ? "" : """
                <div class="chart-toolbar">
                  <button class="segm active" data-metric="altitude">Altitude</button>
                  <button class="segm" data-metric="speed">Vitesse</button>
                  <span style="width:12px"></span>
                  <button class="seg active" data-mode="distance">Distance</button>
                  <button class="seg" data-mode="time">Temps</button>
                </div>
            """
            profileSection = """
            <section class="section"><h2 id="profile-title">Profil</h2>
              <div class="chart-block">
                \(toolbar)
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
        \(ogMeta(title: activity.title, description: "\(activity.activityType.displayName) · \(fmtDistance(activity.distance)) · +\(Int(activity.elevationGain.rounded())) m · \(fmtDate(activity.startDate))", imageRef: ogImageRef, baseURL: publicBaseURL))
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

    /// Balises Open Graph / Twitter pour l'aperçu du lien partagé. `imageRef` est relatif au dossier publié ;
    /// `baseURL` (URL publique, suffixée « / ») le rend absolu — requis pour que les scrapers chargent l'image.
    private static func ogMeta(title: String, description: String, imageRef: String?, baseURL: String?) -> String {
        var lines = [
            "<meta property=\"og:type\" content=\"website\">",
            "<meta property=\"og:site_name\" content=\"GPXManagement\">",
            "<meta property=\"og:title\" content=\"\(esc(title))\">"
        ]
        if !description.isEmpty {
            lines.append("<meta name=\"description\" content=\"\(esc(description))\">")
            lines.append("<meta property=\"og:description\" content=\"\(esc(description))\">")
        }
        if let base = baseURL { lines.append("<meta property=\"og:url\" content=\"\(esc(base))\">") }
        if let ref = imageRef {
            let img = esc((baseURL ?? "") + ref)
            lines.append("<meta property=\"og:image\" content=\"\(img)\">")
            lines.append("<meta name=\"twitter:card\" content=\"summary_large_image\">")
            lines.append("<meta name=\"twitter:image\" content=\"\(img)\">")
        }
        return lines.joined(separator: "\n")
    }

    /// Snapshot PNG du tracé sur fond IGN, utilisé comme image d'aperçu (og:image) à la publication.
    private static func previewSnapshotPNG(points: [TrackPoint], activity: ActivitySummary, layer: MapLayer) async -> Data? {
        guard let bounds = PDFReportRenderer.boundingMapRect(points) else { return nil }
        let mapRect = framedMapRect(bounds, aspect: mapAspect)
        let overlay = TrackOverlayInput(activityId: activity.id, activityType: activity.activityType,
                                        coordinates: points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        return try? await MapImageExporter.renderPNG(layer: layer, mapRect: mapRect, tracks: [overlay], maxDimension: 1600, trackColor: activity.activityType.trackColor)
    }

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
        .chartXScale(domain: 0...max(samples.map(\.x).max() ?? 1, 1))
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
        .chartXScale(domain: 0...max(time.samples.map(\.x).max() ?? 1, 1))
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
