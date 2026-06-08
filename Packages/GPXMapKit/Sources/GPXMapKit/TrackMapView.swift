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

public struct TrackMapView: NSViewRepresentable {
    public let tracks: [TrackOverlayInput]
    @Binding public var layer: MapLayer
    public var onSelectActivity: ((UUID) -> Void)?
    public var proxy: MapViewProxy?
    public var highlight: CLLocationCoordinate2D?
    public var photos: [PhotoMapItem]
    public var onSelectPhoto: ((String) -> Void)?
    /// Opacité (0…1) de la couche « pentes » IGN superposée au fond. 0 = masquée.
    public var slopeOverlayOpacity: Double

    public init(tracks: [TrackOverlayInput], layer: Binding<MapLayer>, proxy: MapViewProxy? = nil, highlight: CLLocationCoordinate2D? = nil, photos: [PhotoMapItem] = [], slopeOverlayOpacity: Double = 0, onSelectActivity: ((UUID) -> Void)? = nil, onSelectPhoto: ((String) -> Void)? = nil) {
        self.tracks = tracks
        self._layer = layer
        self.proxy = proxy
        self.highlight = highlight
        self.photos = photos
        self.slopeOverlayOpacity = slopeOverlayOpacity
        self.onSelectActivity = onSelectActivity
        self.onSelectPhoto = onSelectPhoto
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
        if onSelectActivity != nil {
            let tap = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
            tap.delegate = context.coordinator
            mapView.addGestureRecognizer(tap)
        }
        return mapView
    }

    public func updateNSView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.currentLayer != layer {
            configure(mapView: mapView, layer: layer)
            context.coordinator.currentLayer = layer
        }
        context.coordinator.applySlopeOverlay(opacity: slopeOverlayOpacity, to: mapView)
        context.coordinator.applyTracks(tracks, to: mapView, fitOnChange: context.coordinator.lastTrackIds != Set(tracks.map(\.activityId)))
        context.coordinator.lastTrackIds = Set(tracks.map(\.activityId))
        context.coordinator.applyHighlight(highlight, to: mapView)
        context.coordinator.applyPhotos(photos, to: mapView)
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
        weak var mapView: MKMapView?
        private let onSelectActivity: ((UUID) -> Void)?
        private let onSelectPhoto: ((String) -> Void)?
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
                let c = t.segmentColors
                let colorKey = c == nil ? "u" : "\(c!.count):\(c!.first?.description ?? ""):\(c!.last?.description ?? "")"
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
            return nil
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let photo = view.annotation as? PhotoAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onSelectPhoto?(photo.id)
            }
        }

        public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard let mapView = gestureRecognizer.view, let superview = mapView.superview else { return true }
            let superPoint = superview.convert(event.locationInWindow, from: nil)
            guard let hit = mapView.hitTest(superPoint) else { return true }
            var view: NSView? = hit
            while let current = view, current !== mapView {
                if current is NSControl { return false }
                view = current.superview
            }
            return true
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView,
                  let callback = onSelectActivity else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
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

final class PhotoAnnotation: MKPointAnnotation {
    var id: String = ""
    var image: NSImage?
    var isVideo = false
}
