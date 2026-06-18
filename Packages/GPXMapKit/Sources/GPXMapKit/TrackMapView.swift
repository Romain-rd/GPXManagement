import SwiftUI
import MapKit
import AppKit
import GPXCore

/// Mode de coloration de la trace sur la carte.
public enum TrackColorMode: String, Sendable, CaseIterable, Identifiable {
    case uniform, speed, slope
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .uniform: return "Uniforme"
        case .speed:   return "Vitesse"
        case .slope:   return "Pente"
        }
    }
}

public struct TrackOverlayInput: Sendable {
    public let activityId: UUID
    public let activityType: ActivityType
    public let coordinates: [CLLocationCoordinate2D]
    /// Couleur par coordonnée (même cardinalité que `coordinates`) si coloration vitesse/pente ; sinon nil.
    public let segmentColors: [NSColor]?

    public init(activityId: UUID, activityType: ActivityType, coordinates: [CLLocationCoordinate2D], segmentColors: [NSColor]? = nil) {
        self.activityId = activityId
        self.activityType = activityType
        self.coordinates = coordinates
        self.segmentColors = segmentColors
    }

    public static func fromTrackData(_ data: Data, activityId: UUID, activityType: ActivityType, colorMode: TrackColorMode = .uniform) throws -> TrackOverlayInput {
        let points = try TrackPointCodec.decode(data)
        let coords = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let colors = Self.segmentColors(points: points, count: coords.count, activityType: activityType, mode: colorMode)
        return TrackOverlayInput(activityId: activityId, activityType: activityType, coordinates: coords, segmentColors: colors)
    }

    private static func nsColor(_ rgb: (r: Double, g: Double, b: Double)) -> NSColor {
        NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    private static func segmentColors(points: [TrackPoint], count: Int, activityType: ActivityType, mode: TrackColorMode) -> [NSColor]? {
        switch mode {
        case .uniform:
            return nil
        case .slope:
            let profile = ElevationProfileBuilder.build(points: points)
            guard profile.count == count else { return nil } // alignement points↔altitude requis
            let scale = SlopeScale.percent
            return profile.map { nsColor(scale.category(for: $0.slope).rgb) }
        case .speed:
            let profile = ElevationProfileBuilder.buildMotion(points: points)
            guard profile.count == count, count >= 2 else { return nil }
            let scale = activityType.speedScale
            let toDisplay: (Double) -> Double = { mps in
                let kmh = mps * 3.6
                return activityType.usesNauticalUnits ? kmh / 1.852 : kmh
            }
            // vitesse m/s lissée par point
            var raw = [Double](repeating: 0, count: count)
            for i in 1..<count {
                guard let t0 = profile[i - 1].timestamp, let t1 = profile[i].timestamp else { raw[i] = raw[i - 1]; continue }
                let dt = t1.timeIntervalSince(t0)
                let dd = profile[i].distanceFromStart - profile[i - 1].distanceFromStart
                raw[i] = (dt > 0 && dt <= 600) ? dd / dt : raw[i - 1]
            }
            raw[0] = count > 1 ? raw[1] : 0
            let w = 5
            return (0..<count).map { i in
                let lo = max(0, i - w / 2), hi = min(count - 1, i + w / 2)
                var sum = 0.0
                for k in lo...hi { sum += raw[k] }
                let cat = scale.category(for: toDisplay(sum / Double(hi - lo + 1)))
                return nsColor(cat.rgb)
            }
        }
    }
}

public struct PhotoMapItem: Identifiable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D
    public let image: NSImage?
    public let isVideo: Bool

    public init(id: String, coordinate: CLLocationCoordinate2D, image: NSImage?, isVideo: Bool = false) {
        self.id = id
        self.coordinate = coordinate
        self.image = image
        self.isVideo = isVideo
    }
}

@MainActor
public extension Notification.Name {
    /// Force le rechargement des tuiles de toutes les cartes visibles (déclenché par Cmd+R).
    static let reloadMapTiles = Notification.Name("GPXReloadMapTiles")
}

public final class MapViewProxy {
    public weak var mapView: MKMapView?
    public init() {}

    public var visibleMapRect: MKMapRect? { mapView?.visibleMapRect }
    public var boundsSize: CGSize? { mapView?.bounds.size }
}

public struct WaypointMarker: Sendable, Identifiable {
    public let id: UUID
    public let coordinate: CLLocationCoordinate2D
    public let index: Int
    public let role: RouteWaypoint.Role
    public let name: String?
    public let label: String?     // numéro d'ordre affiché dans l'épingle (nil = icône par rôle)
    public let isPreview: Bool    // repère d'aperçu (recherche) déplaçable, pas encore dans le tracé
    public let isSelected: Bool   // pastille sélectionnée (mise en évidence sur la carte)
    public init(id: UUID, coordinate: CLLocationCoordinate2D, index: Int, role: RouteWaypoint.Role = .shaping, name: String? = nil, label: String? = nil, isPreview: Bool = false, isSelected: Bool = false) {
        self.id = id; self.coordinate = coordinate; self.index = index; self.role = role; self.name = name; self.label = label; self.isPreview = isPreview; self.isSelected = isSelected
    }
}

final class WaypointAnnotation: MKPointAnnotation {
    let waypointId: UUID
    let index: Int
    let role: RouteWaypoint.Role
    let label: String?
    let isPreview: Bool
    let isSelected: Bool
    init(id: UUID, coordinate: CLLocationCoordinate2D, index: Int, role: RouteWaypoint.Role, name: String?, label: String?, isPreview: Bool, isSelected: Bool) {
        self.waypointId = id; self.index = index; self.role = role; self.label = label; self.isPreview = isPreview; self.isSelected = isSelected
        super.init()
        self.coordinate = coordinate
        self.title = name
    }
}

/// Reconnaisseur des interactions sur un point : revendique dès le `mouseDown` s'il est sur/près d'un marqueur
/// (ce qui coupe le défilement interne de MKMapView avant qu'il démarre). Tap = sélection, glissement = déplacement.
final class WaypointInteractionRecognizer: NSGestureRecognizer {
    weak var map: MKMapView?
    var pick: ((NSPoint) -> WaypointAnnotation?)?
    private(set) var picked: WaypointAnnotation?
    private(set) var moved = false
    private(set) var current: NSPoint = .zero
    private var down: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        guard let map else { state = .failed; return }
        down = map.convert(event.locationInWindow, from: nil)
        current = down
        moved = false
        picked = pick?(down)
        state = picked != nil ? .began : .failed
    }
    override func mouseDragged(with event: NSEvent) {
        guard picked != nil, let map else { return }
        current = map.convert(event.locationInWindow, from: nil)
        if !moved, hypot(current.x - down.x, current.y - down.y) > 8 { moved = true }
        state = .changed
    }
    override func mouseUp(with event: NSEvent) {
        guard picked != nil, let map else { state = .failed; return }
        current = map.convert(event.locationInWindow, from: nil)
        state = .ended
    }
}

public struct TrackMapView: NSViewRepresentable {
    public let tracks: [TrackOverlayInput]
    @Binding public var layer: MapLayer
    public var onSelectActivity: ((UUID) -> Void)?
    public var proxy: MapViewProxy?
    public var highlight: CLLocationCoordinate2D?
    /// Portion de trace surlignée (segment survolé) — polyline épaisse dessinée par-dessus le tracé.
    public var highlightRange: [CLLocationCoordinate2D]
    public var photos: [PhotoMapItem]
    public var onSelectPhoto: ((String) -> Void)?
    /// Opacité (0…1) de la couche « pentes » IGN superposée au fond. 0 = masquée.
    public var slopeOverlayOpacity: Double
    /// Si défini, un clic sur la carte renvoie la coordonnée (mode « poser un point ») plutôt que de sélectionner une trace.
    public var onMapClick: ((CLLocationCoordinate2D) -> Void)?
    /// Si vrai, la carte ne se cadre qu'une seule fois (au premier affichage) et ne re-zoome plus aux mises à jour.
    public var fitsOnce: Bool = false
    /// Points de passage éditables (pins numérotés déplaçables).
    public var waypoints: [WaypointMarker] = []
    public var onWaypointMoved: ((UUID, CLLocationCoordinate2D) -> Void)?
    public var onWaypointTapped: ((UUID) -> Void)?

    public init(tracks: [TrackOverlayInput], layer: Binding<MapLayer>, proxy: MapViewProxy? = nil, highlight: CLLocationCoordinate2D? = nil, highlightRange: [CLLocationCoordinate2D] = [], photos: [PhotoMapItem] = [], slopeOverlayOpacity: Double = 0, fitsOnce: Bool = false, waypoints: [WaypointMarker] = [], onWaypointMoved: ((UUID, CLLocationCoordinate2D) -> Void)? = nil, onWaypointTapped: ((UUID) -> Void)? = nil, onSelectActivity: ((UUID) -> Void)? = nil, onSelectPhoto: ((String) -> Void)? = nil, onMapClick: ((CLLocationCoordinate2D) -> Void)? = nil) {
        self.tracks = tracks
        self._layer = layer
        self.proxy = proxy
        self.highlight = highlight
        self.highlightRange = highlightRange
        self.photos = photos
        self.slopeOverlayOpacity = slopeOverlayOpacity
        self.fitsOnce = fitsOnce
        self.waypoints = waypoints
        self.onWaypointMoved = onWaypointMoved
        self.onWaypointTapped = onWaypointTapped
        self.onSelectActivity = onSelectActivity
        self.onSelectPhoto = onSelectPhoto
        self.onMapClick = onMapClick
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSelectActivity: onSelectActivity, onSelectPhoto: onSelectPhoto)
    }

    public func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsZoomControls = true
        mapView.showsScale = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        proxy?.mapView = mapView
        context.coordinator.mapView = mapView
        configure(mapView: mapView, layer: layer)
        // Clic « poser un point » / sélection de trace. Le délégué l'empêche de s'activer sur une annotation,
        // pour laisser MapKit gérer NATIVEMENT la sélection et le déplacement des points (approche Apple).
        let tap = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        // Interactions sur un point (sélection + déplacement) : reconnaisseur qui revendique le clic au mouseDown
        // sur un marqueur (coupe le défilement interne de MapKit). Le clic d'ajout attend son échec.
        let wp = WaypointInteractionRecognizer(target: context.coordinator, action: #selector(Coordinator.handleWaypoint(_:)))
        wp.delegate = context.coordinator
        wp.map = mapView
        let coord = context.coordinator
        wp.pick = { [weak coord] p in
            guard let coord, let m = coord.mapView else { return nil }
            return coord.waypointAnnotation(atScreenPoint: p, in: m) ?? coord.nearestWaypointAnnotation(toPoint: p, in: m)
        }
        mapView.addGestureRecognizer(wp)
        return mapView
    }

    public func updateNSView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.currentLayer != layer {
            configure(mapView: mapView, layer: layer)
            context.coordinator.currentLayer = layer
        }
        context.coordinator.applySlopeOverlay(opacity: slopeOverlayOpacity, to: mapView)
        let idsChanged = context.coordinator.lastTrackIds != Set(tracks.map(\.activityId))
        let shouldFit = fitsOnce ? !context.coordinator.hasFitted : idsChanged
        context.coordinator.applyTracks(tracks, to: mapView, fitOnChange: shouldFit)
        context.coordinator.lastTrackIds = Set(tracks.map(\.activityId))
        if shouldFit, !tracks.isEmpty { context.coordinator.hasFitted = true }
        context.coordinator.applyHighlight(highlight, to: mapView)
        context.coordinator.applyHighlightRange(highlightRange, to: mapView)
        context.coordinator.applyPhotos(photos, to: mapView)
        context.coordinator.onMapClick = onMapClick
        context.coordinator.onWaypointMoved = onWaypointMoved
        context.coordinator.onWaypointTapped = onWaypointTapped
        context.coordinator.applyWaypoints(waypoints, to: mapView)
    }

    private func configure(mapView: MKMapView, layer: MapLayer) {
        mapView.removeOverlays(mapView.overlays.filter { $0 is MKTileOverlay })
        switch layer {
        case .mapkitStandard:
            mapView.preferredConfiguration = MKStandardMapConfiguration()
        case .mapkitSatellite:
            mapView.preferredConfiguration = MKHybridMapConfiguration()
        default:
            mapView.preferredConfiguration = MKStandardMapConfiguration()
            // canReplaceMapContent=true → la tuile sert de fond et masque les labels Apple.
            let overlay: MKTileOverlay
            if let template = layer.tileURLTemplate {
                let tile = MKTileOverlay(urlTemplate: template)
                tile.canReplaceMapContent = true
                tile.maximumZ = layer.maxZoom
                overlay = tile
            } else {
                overlay = IGNTileOverlay(layer: layer)
            }
            // Inséré tout en bas du niveau pour rester sous les tracés (sinon, en changeant de fond,
            // la nouvelle tuile recouvrirait la trace déjà ajoutée et la masquerait).
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        }
    }

    public final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var currentLayer: MapLayer = .ignPlanV2
        var lastTrackIds: Set<UUID> = []
        var hasFitted = false
        weak var mapView: MKMapView?
        private let onSelectActivity: ((UUID) -> Void)?
        private let onSelectPhoto: ((String) -> Void)?
        var onMapClick: ((CLLocationCoordinate2D) -> Void)?
        var onWaypointMoved: ((UUID, CLLocationCoordinate2D) -> Void)?
        var onWaypointTapped: ((UUID) -> Void)?
        private var waypointAnnotations: [WaypointAnnotation] = []
        private var highlightAnnotation: HighlightAnnotation?
        private var photoAnnotations: [String: PhotoAnnotation] = [:]
        private var slopeOverlay: IGNTileOverlay?
        private var slopeOpacity: CGFloat = 0
        private var lastTracksSig = ""

        init(onSelectActivity: ((UUID) -> Void)?, onSelectPhoto: ((String) -> Void)? = nil) {
            self.onSelectActivity = onSelectActivity
            self.onSelectPhoto = onSelectPhoto
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(reloadFromNotification), name: .reloadMapTiles, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func reloadFromNotification() { reloadTiles() }

        /// Force MapKit à re-télécharger les tuiles (les tuiles en échec/blanches sont refetch), sans
        /// retirer les tracés ni la surcouche pentes.
        func reloadTiles() {
            guard let mapView else { return }
            for overlay in mapView.overlays where overlay is MKTileOverlay {
                (mapView.renderer(for: overlay) as? MKTileOverlayRenderer)?.reloadData()
            }
        }

        /// Vignettes des photos prises le long du parcours, placées à leur position GPS.
        func applyPhotos(_ items: [PhotoMapItem], to mapView: MKMapView) {
            let incoming = Set(items.map(\.id))
            for (id, annotation) in photoAnnotations where !incoming.contains(id) {
                mapView.removeAnnotation(annotation)
                photoAnnotations[id] = nil
            }
            for item in items {
                if let annotation = photoAnnotations[item.id] {
                    annotation.coordinate = item.coordinate
                    annotation.image = item.image
                    annotation.isVideo = item.isVideo
                    if let view = mapView.view(for: annotation) {
                        view.image = Self.framedThumbnail(item.image, isVideo: item.isVideo)
                    }
                } else {
                    let annotation = PhotoAnnotation()
                    annotation.id = item.id
                    annotation.coordinate = item.coordinate
                    annotation.image = item.image
                    annotation.isVideo = item.isVideo
                    photoAnnotations[item.id] = annotation
                    mapView.addAnnotation(annotation)
                }
            }
        }

        private static func framedThumbnail(_ image: NSImage?, isVideo: Bool) -> NSImage {
            let side: CGFloat = 46
            let result = NSImage(size: NSSize(width: side, height: side))
            result.lockFocus()
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let inner = rect.insetBy(dx: 2, dy: 2)
            let clip = NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6)
            clip.addClip()
            if let image, image.size.width > 0, image.size.height > 0 {
                let scale = max(inner.width / image.size.width, inner.height / image.size.height)
                let dw = image.size.width * scale, dh = image.size.height * scale
                image.draw(in: NSRect(x: inner.midX - dw / 2, y: inner.midY - dh / 2, width: dw, height: dh))
            } else {
                NSColor.systemGray.setFill()
                clip.fill()
            }
            if isVideo {
                let d: CGFloat = 16
                let circle = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: circle).fill()
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: circle.midX - 3, y: circle.midY - 4))
                triangle.line(to: NSPoint(x: circle.midX - 3, y: circle.midY + 4))
                triangle.line(to: NSPoint(x: circle.midX + 4, y: circle.midY))
                triangle.close()
                NSColor.white.setFill()
                triangle.fill()
            }
            result.unlockFocus()
            return result
        }

        /// Marqueur synchronisé avec le survol du profil altimétrique. Mis à jour sans recentrer la carte.
        func applyHighlight(_ coordinate: CLLocationCoordinate2D?, to mapView: MKMapView) {
            guard let coordinate else {
                if let existing = highlightAnnotation {
                    mapView.removeAnnotation(existing)
                    highlightAnnotation = nil
                }
                return
            }
            if let existing = highlightAnnotation {
                existing.coordinate = coordinate
            } else {
                let annotation = HighlightAnnotation()
                annotation.coordinate = coordinate
                highlightAnnotation = annotation
                mapView.addAnnotation(annotation)
            }
        }

        func applyWaypoints(_ markers: [WaypointMarker], to mapView: MKMapView) {
            // Pas de reconstruction pendant un drag (sinon le pin saute) : on diffe sur (id, index, coord).
            let sig = markers.map { "\($0.id.uuidString)|\($0.index)|\($0.role.rawValue)|\($0.coordinate.latitude),\($0.coordinate.longitude)|\($0.isSelected)" }.joined(separator: ";")
            if sig == waypointSignature { return }
            waypointSignature = sig
            mapView.removeAnnotations(waypointAnnotations)
            waypointAnnotations = markers.map { WaypointAnnotation(id: $0.id, coordinate: $0.coordinate, index: $0.index, role: $0.role, name: $0.name, label: $0.label, isPreview: $0.isPreview, isSelected: $0.isSelected) }
            mapView.addAnnotations(waypointAnnotations)
        }
        private var waypointSignature = ""

        public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            NSLog("🟦MAP didChange dragState \(newState.rawValue)")
            guard newState == .ending || newState == .canceling,
                  let wp = view.annotation as? WaypointAnnotation else { return }
            view.setDragState(.none, animated: false)
            if newState == .ending { onWaypointMoved?(wp.waypointId, wp.coordinate) }
        }

        private var rangePolyline: SegmentRangePolyline?
        private var rangeSignature = ""

        /// Polyline de surlignage d'une portion de trace (segment sélectionné), dessinée par-dessus le tracé.
        /// Cadre la carte sur le segment à la sélection, et sur la trace entière à la désélection.
        func applyHighlightRange(_ coords: [CLLocationCoordinate2D], to mapView: MKMapView) {
            let signature = coords.count >= 2
                ? "\(coords.count)|\(coords[0].latitude),\(coords[0].longitude)|\(coords[coords.count - 1].latitude),\(coords[coords.count - 1].longitude)"
                : ""
            guard signature != rangeSignature else { return }
            rangeSignature = signature
            if let existing = rangePolyline {
                mapView.removeOverlay(existing)
                rangePolyline = nil
            }
            guard coords.count >= 2 else {
                let trackRects = mapView.overlays.compactMap { ($0 as? IdentifiedPolyline)?.boundingMapRect }
                if let union = trackRects.dropFirst().reduce(trackRects.first, { $0?.union($1) }) {
                    mapView.setVisibleMapRect(union, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
                }
                return
            }
            let polyline = SegmentRangePolyline(coordinates: coords, count: coords.count)
            rangePolyline = polyline
            mapView.addOverlay(polyline, level: .aboveLabels)
            mapView.setVisibleMapRect(polylineRect(coords), edgePadding: NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60), animated: true)
        }

        /// Superpose (ou retire) la couche « pentes » IGN par-dessus le fond, à l'opacité demandée.
        /// Réinséré sous les polylines pour que la trace reste visible.
        func applySlopeOverlay(opacity: Double, to mapView: MKMapView) {
            let clamped = CGFloat(max(0, min(1, opacity)))
            let shouldShow = clamped > 0 && currentLayer.isIGN // surcouche pentes uniquement sur fond IGN
            let present = slopeOverlay != nil && mapView.overlays.contains { ($0 as AnyObject) === (slopeOverlay as AnyObject) }
            // Rien à faire si l'état n'a pas changé (évite de reconstruire à chaque frame pendant un drag).
            if clamped == slopeOpacity && present == shouldShow { return }
            slopeOpacity = clamped
            if let existing = slopeOverlay {
                mapView.removeOverlay(existing)
                slopeOverlay = nil
            }
            guard shouldShow else { return }
            let overlay = IGNTileOverlay(layer: .ignSlopes)
            overlay.canReplaceMapContent = false // surcouche translucide, ne masque pas le fond
            slopeOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

        private func tracksSignature(_ tracks: [TrackOverlayInput]) -> String {
            tracks.map { t in
                let colorKey: String
                if let c = t.segmentColors {
                    // Positions des frontières de couleur (= jonctions d'étapes) : change quand on déplace une jonction.
                    // Repli sur count:first:last si trop de runs (coloration vitesse/pente par point), qui ne bougent pas.
                    var boundaries: [Int] = []
                    var tooMany = false
                    if c.count > 1 {
                        for i in 1..<c.count where c[i] != c[i - 1] {
                            boundaries.append(i)
                            if boundaries.count > 64 { tooMany = true; break }
                        }
                    }
                    colorKey = tooMany
                        ? "\(c.count):\(c.first?.description ?? ""):\(c.last?.description ?? "")"
                        : "\(c.count):b:" + boundaries.map(String.init).joined(separator: ",")
                } else {
                    colorKey = "u"
                }
                return "\(t.activityId.uuidString)|\(t.coordinates.count)|\(colorKey)"
            }.joined(separator: ";")
        }

        /// Trace découpée en segments contigus de même couleur (coloration vitesse/pente par point).
        private func addColoredSegments(_ coords: [CLLocationCoordinate2D], colors: [NSColor], activityId: UUID, to mapView: MKMapView) {
            var i = 0
            while i < coords.count - 1 {
                let color = colors[i]
                var j = i
                while j < coords.count - 1 && colors[j] == color { j += 1 }
                let slice = Array(coords[i...j]) // inclut le point frontière → segments jointifs
                let poly = IdentifiedPolyline(coordinates: slice, count: slice.count)
                poly.activityId = activityId
                poly.color = color
                mapView.addOverlay(poly, level: .aboveLabels)
                i = j
            }
        }

        func applyTracks(_ tracks: [TrackOverlayInput], to mapView: MKMapView, fitOnChange: Bool) {
            // Ne reconstruit la trace que si elle a changé (sinon updateNSView resterait coûteux à chaque frame).
            let sig = tracksSignature(tracks)
            let hasPolylines = mapView.overlays.contains { $0 is IdentifiedPolyline }
            if sig == lastTracksSig && hasPolylines { return }
            lastTracksSig = sig

            let existingPolylines = mapView.overlays.compactMap { $0 as? IdentifiedPolyline }
            mapView.removeOverlays(existingPolylines)

            let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
            let distinctTypes = Set(nonEmpty.map(\.activityType))
            // Plusieurs traces toutes du même type → la couleur de type ne distingue rien → rotation de 4 couleurs.
            // Types différents (ou trace unique) → couleur du type d'activité.
            let useRotation = nonEmpty.count > 1 && distinctTypes.count == 1

            var allCoords: [CLLocationCoordinate2D] = []
            for (index, track) in nonEmpty.enumerated() {
                allCoords.append(contentsOf: track.coordinates)
                if let colors = track.segmentColors, colors.count == track.coordinates.count, track.coordinates.count >= 2 {
                    addColoredSegments(track.coordinates, colors: colors, activityId: track.activityId, to: mapView)
                } else {
                    let polyline = IdentifiedPolyline(coordinates: track.coordinates, count: track.coordinates.count)
                    polyline.activityId = track.activityId
                    polyline.activityType = track.activityType
                    polyline.color = useRotation ? MapTrackPalette.color(at: index) : track.activityType.trackColor
                    mapView.addOverlay(polyline, level: .aboveLabels)
                }
            }

            if fitOnChange, !allCoords.isEmpty {
                let rect = polylineRect(allCoords)
                mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
            }
        }

        public func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let slope = slopeOverlay, overlay === slope {
                let renderer = MKTileOverlayRenderer(tileOverlay: slope)
                renderer.alpha = slopeOpacity
                return renderer
            }
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let range = overlay as? SegmentRangePolyline {
                // Jaune fluo (même choix que l'export PNG) : reste lisible sur les verts des fonds IGN.
                let renderer = MKPolylineRenderer(polyline: range)
                renderer.strokeColor = NSColor(srgbRed: 1, green: 0.92, blue: 0, alpha: 0.9)
                renderer.lineWidth = 7
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if let identified = overlay as? IdentifiedPolyline {
                let renderer = MKPolylineRenderer(polyline: identified)
                renderer.strokeColor = identified.color ?? identified.activityType?.trackColor ?? .systemBlue
                renderer.lineWidth = 4
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // Petit point discret pour les ancrages de routage muets (`.shaping`).
        private static let shapingImage: NSImage = {
            let size = NSSize(width: 12, height: 12)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 7, height: 7)).fill()
            image.unlockFocus()
            return image
        }()

        private static let highlightImage: NSImage = {
            let size = NSSize(width: 16, height: 16)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 10, height: 10)).fill()
            image.unlockFocus()
            return image
        }()

        public func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let photo = annotation as? PhotoAnnotation {
                let identifier = "photo"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.framedThumbnail(photo.image, isVideo: photo.isVideo)
                view.centerOffset = .zero
                view.canShowCallout = false
                return view
            }
            if annotation is HighlightAnnotation {
                let identifier = "highlight"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.highlightImage
                view.centerOffset = .zero
                view.canShowCallout = false
                return view
            }
            if let wp = annotation as? WaypointAnnotation {
                // Point de routage muet SANS numéro : petit point discret, pas de bulle.
                if wp.role == .shaping && wp.label == nil {
                    let identifier = "waypoint.shaping"
                    let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                        ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view.annotation = annotation
                    view.image = Self.shapingImage
                    view.centerOffset = .zero
                    view.isDraggable = true
                    view.canShowCallout = false
                    view.displayPriority = .defaultLow
                    return view
                }
                // Épingle numérotée, couleur par rôle (gris = tracé, orange = POI, vert = arrêt d'étape).
                let identifier = "waypoint.marker"
                let marker = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                marker.annotation = annotation
                if wp.isPreview {
                    marker.markerTintColor = .systemRed
                    marker.glyphText = nil
                    marker.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
                } else {
                    // Sélectionné → bleu accent (mis en avant) ; sinon couleur par rôle.
                    marker.markerTintColor = wp.isSelected ? .controlAccentColor : (wp.role == .stageStop ? .systemGreen : (wp.role == .poi ? .systemOrange : .systemGray))
                    if let label = wp.label {
                        marker.glyphText = label
                        marker.glyphImage = nil
                    } else {
                        marker.glyphText = nil
                        marker.glyphImage = NSImage(systemSymbolName: wp.role == .stageStop ? "flag.fill" : "mappin", accessibilityDescription: nil)
                    }
                }
                marker.isDraggable = true
                marker.canShowCallout = (wp.title?.isEmpty == false)
                marker.animatesWhenAdded = false
                marker.displayPriority = .required   // ne pas masquer/agréger les pins voisins
                marker.collisionMode = .circle
                return marker
            }
            return nil
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let photo = view.annotation as? PhotoAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onSelectPhoto?(photo.id)
            } else if view.annotation is WaypointAnnotation {
                // Sélection gérée par WaypointInteractionRecognizer ; on annule la sélection native.
                mapView.deselectAnnotation(view.annotation, animated: false)
            }
        }

        public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard let mapView = gestureRecognizer.view as? MKMapView, let superview = mapView.superview else { return true }
            var view = mapView.hitTest(superview.convert(event.locationInWindow, from: nil))
            var onAnnotation = false, onControl = false
            while let current = view, current !== mapView {
                if current is NSControl { onControl = true }
                if current is MKAnnotationView { onAnnotation = true }
                view = current.superview
            }
            if onControl { return false }
            // Clic d'ajout : pas sur une annotation (le reconnaisseur waypoint s'en charge).
            if gestureRecognizer is NSClickGestureRecognizer { return !onAnnotation }
            return true   // reconnaisseur waypoint : tente partout, décide au mouseDown
        }

        /// Le clic d'ajout/sélection-de-trace n'opère que si l'interaction sur un point a échoué (hors point).
        public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
            gestureRecognizer is NSClickGestureRecognizer && other is WaypointInteractionRecognizer
        }

        func waypointAnnotation(atScreenPoint point: CGPoint, in mapView: MKMapView) -> WaypointAnnotation? {
            guard let superview = mapView.superview else { return nil }
            var view = mapView.hitTest(mapView.convert(point, to: superview))
            while let current = view, current !== mapView {
                if let av = current as? MKAnnotationView, let wp = av.annotation as? WaypointAnnotation { return wp }
                view = current.superview
            }
            return nil
        }

        func nearestWaypointAnnotation(toPoint point: CGPoint, in mapView: MKMapView, threshold: CGFloat = 30) -> WaypointAnnotation? {
            var best: (ann: WaypointAnnotation, d: CGFloat)?
            for wp in waypointAnnotations {
                let p = mapView.convert(wp.coordinate, toPointTo: mapView)
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < threshold, best == nil || d < best!.d { best = (wp, d) }
            }
            return best?.ann
        }

        private var grabOffset: CGPoint = .zero

        @objc func handleWaypoint(_ g: WaypointInteractionRecognizer) {
            guard let mapView = g.map, let ann = g.picked else { return }
            switch g.state {
            case .began:
                let ap = mapView.convert(ann.coordinate, toPointTo: mapView)
                grabOffset = CGPoint(x: ap.x - g.current.x, y: ap.y - g.current.y)
                mapView.isScrollEnabled = false
                onWaypointTapped?(ann.waypointId)   // sélection dès qu'on touche le point (clic OU début de drag)
                NSLog("🟦MAP waypoint BEGAN/select wp \(ann.index + 1)")
            case .changed where g.moved:
                let t = CGPoint(x: g.current.x + grabOffset.x, y: g.current.y + grabOffset.y)
                ann.coordinate = mapView.convert(t, toCoordinateFrom: mapView)
            case .ended, .cancelled, .failed:
                if g.moved {
                    let t = CGPoint(x: g.current.x + grabOffset.x, y: g.current.y + grabOffset.y)
                    let c = mapView.convert(t, toCoordinateFrom: mapView)
                    ann.coordinate = c
                    onWaypointMoved?(ann.waypointId, c)
                    NSLog("🟦MAP waypoint MOVED wp \(ann.index + 1)")
                }
                mapView.isScrollEnabled = true
            default: break
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            NSLog("🟦MAP handleClick (clic hors annotation)")
            // Le clic sur une annotation est géré nativement (didSelect / drag). Ici : poser un point, ou sélectionner une trace.
            if let place = onMapClick { place(coord); return } // mode « poser un point »
            guard let callback = onSelectActivity else { return }
            let mapPoint = MKMapPoint(coord)
            let tolerance = 800.0 / Double(mapView.bounds.width) * mapView.visibleMapRect.size.width
            for case let polyline as IdentifiedPolyline in mapView.overlays {
                if polylineHit(polyline: polyline, point: mapPoint, tolerance: tolerance), let id = polyline.activityId {
                    callback(id)
                    return
                }
            }
        }

        private func polylineHit(polyline: MKPolyline, point: MKMapPoint, tolerance: Double) -> Bool {
            let points = polyline.points()
            for i in 0..<polyline.pointCount {
                if points[i].distance(to: point) < tolerance { return true }
            }
            return false
        }

        private func polylineRect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect {
            guard !coords.isEmpty else { return .null }
            let mapPoints = coords.map { MKMapPoint($0) }
            var minX = mapPoints[0].x
            var maxX = mapPoints[0].x
            var minY = mapPoints[0].y
            var maxY = mapPoints[0].y
            for p in mapPoints {
                if p.x < minX { minX = p.x }
                if p.x > maxX { maxX = p.x }
                if p.y < minY { minY = p.y }
                if p.y > maxY { maxY = p.y }
            }
            var rect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            // Trace quasi immobile (escalade sur place…) → étendue ~0 = carte noire. On garantit ~300 m de côté.
            let minSpan = 300 * MKMapPointsPerMeterAtLatitude(coords[0].latitude)
            if rect.size.width < minSpan || rect.size.height < minSpan {
                let w = Swift.max(rect.size.width, minSpan), h = Swift.max(rect.size.height, minSpan)
                rect = MKMapRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
            }
            return rect
        }
    }
}

final class IdentifiedPolyline: MKPolyline {
    var activityId: UUID?
    var activityType: ActivityType?
    var color: NSColor?
}

final class HighlightAnnotation: MKPointAnnotation {}

final class SegmentRangePolyline: MKPolyline {}

final class PhotoAnnotation: MKPointAnnotation {
    var id: String = ""
    var image: NSImage?
    var isVideo = false
}
