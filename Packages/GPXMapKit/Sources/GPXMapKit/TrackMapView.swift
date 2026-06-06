import SwiftUI
import MapKit
import AppKit
import GPXCore

public struct TrackOverlayInput: Sendable {
    public let activityId: UUID
    public let activityType: ActivityType
    public let coordinates: [CLLocationCoordinate2D]

    public init(activityId: UUID, activityType: ActivityType, coordinates: [CLLocationCoordinate2D]) {
        self.activityId = activityId
        self.activityType = activityType
        self.coordinates = coordinates
    }

    public static func fromTrackData(_ data: Data, activityId: UUID, activityType: ActivityType) throws -> TrackOverlayInput {
        let points = try TrackPointCodec.decode(data)
        let coords = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return TrackOverlayInput(activityId: activityId, activityType: activityType, coordinates: coords)
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

    public init(tracks: [TrackOverlayInput], layer: Binding<MapLayer>, proxy: MapViewProxy? = nil, highlight: CLLocationCoordinate2D? = nil, photos: [PhotoMapItem] = [], onSelectActivity: ((UUID) -> Void)? = nil, onSelectPhoto: ((String) -> Void)? = nil) {
        self.tracks = tracks
        self._layer = layer
        self.proxy = proxy
        self.highlight = highlight
        self.photos = photos
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
            // canReplaceMapContent=true → la tuile sert de fond et masque les labels Apple ;
            // les polylines (ajoutées ensuite, même niveau) se dessinent par-dessus.
            let overlay: MKTileOverlay
            if let template = layer.tileURLTemplate {
                let tile = MKTileOverlay(urlTemplate: template)
                tile.canReplaceMapContent = true
                tile.maximumZ = layer.maxZoom
                overlay = tile
            } else {
                overlay = IGNTileOverlay(layer: layer)
            }
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    public final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var currentLayer: MapLayer = .ignPlanV2
        var lastTrackIds: Set<UUID> = []
        private let onSelectActivity: ((UUID) -> Void)?
        private let onSelectPhoto: ((String) -> Void)?
        private var highlightAnnotation: HighlightAnnotation?
        private var photoAnnotations: [String: PhotoAnnotation] = [:]
        private var slopeBands: [UUID: [SlopeBand]] = [:]
        private var slopeSampling: UUID?
        private var slopeTask: Task<Void, Never>?

        init(onSelectActivity: ((UUID) -> Void)?, onSelectPhoto: ((String) -> Void)? = nil) {
            self.onSelectActivity = onSelectActivity
            self.onSelectPhoto = onSelectPhoto
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

        func applyTracks(_ tracks: [TrackOverlayInput], to mapView: MKMapView, fitOnChange: Bool) {
            let existingPolylines = mapView.overlays.compactMap { $0 as? IdentifiedPolyline }
            mapView.removeOverlays(existingPolylines)

            let nonEmpty = tracks.filter { !$0.coordinates.isEmpty }
            let distinctTypes = Set(nonEmpty.map(\.activityType))
            // Plusieurs traces toutes du même type → la couleur de type ne distingue rien → rotation de 4 couleurs.
            // Types différents (ou trace unique) → couleur du type d'activité.
            let useRotation = nonEmpty.count > 1 && distinctTypes.count == 1

            var allCoords: [CLLocationCoordinate2D] = []
            for (index, track) in nonEmpty.enumerated() {
                let baseColor = useRotation ? MapTrackPalette.color(at: index) : track.activityType.trackColor
                allCoords.append(contentsOf: track.coordinates)

                if shouldColorBySlope(track, trackCount: nonEmpty.count),
                   let bands = slopeBands[track.activityId], bands.count == track.coordinates.count {
                    addSlopeSegments(track.coordinates, bands: bands, baseColor: baseColor, activityId: track.activityId, to: mapView)
                } else {
                    addPlainPolyline(track, baseColor: baseColor, to: mapView)
                    if shouldColorBySlope(track, trackCount: nonEmpty.count) {
                        scheduleSlopeSampling(track, baseColor: baseColor, mapView: mapView)
                    }
                }
            }

            if fitOnChange, !allCoords.isEmpty {
                let rect = polylineRect(allCoords)
                mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
            }
        }

        /// La trace neige est colorée par la pente du terrain IGN seulement sur un fond IGN, et en affichage unitaire.
        private func shouldColorBySlope(_ track: TrackOverlayInput, trackCount: Int) -> Bool {
            currentLayer.isIGN && trackCount == 1 && track.activityType.isSnow
        }

        private func addPlainPolyline(_ track: TrackOverlayInput, baseColor: NSColor, to mapView: MKMapView) {
            let polyline = IdentifiedPolyline(coordinates: track.coordinates, count: track.coordinates.count)
            polyline.activityId = track.activityId
            polyline.activityType = track.activityType
            polyline.color = baseColor
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        /// Découpe la trace en segments contigus de même bande de pente, chacun coloré (hors `< 30°` → couleur normale).
        private func addSlopeSegments(_ coords: [CLLocationCoordinate2D], bands: [SlopeBand], baseColor: NSColor, activityId: UUID, to mapView: MKMapView) {
            guard coords.count >= 2 else { return }
            var i = 0
            while i < coords.count - 1 {
                let band = bands[i]
                var j = i
                while j < coords.count - 1 && bands[j] == band { j += 1 }
                let slice = Array(coords[i...j]) // inclut le point frontière → segments jointifs
                let poly = IdentifiedPolyline(coordinates: slice, count: slice.count)
                poly.activityId = activityId
                poly.color = band.color ?? baseColor
                mapView.addOverlay(poly, level: .aboveLabels)
                i = j
            }
        }

        private func scheduleSlopeSampling(_ track: TrackOverlayInput, baseColor: NSColor, mapView: MKMapView) {
            let id = track.activityId
            if slopeBands[id] != nil || slopeSampling == id { return }
            slopeSampling = id
            let coords = track.coordinates
            slopeTask = Task { [weak self, weak mapView] in
                let bands = await IGNSlopeSampler.shared.bands(for: coords, zoom: 16)
                await MainActor.run { [weak self, weak mapView] in
                    guard let self else { return }
                    self.slopeSampling = nil
                    guard bands.count == coords.count else { return }
                    self.slopeBands[id] = bands
                    guard let mapView, self.currentLayer.isIGN, self.lastTrackIds.contains(id) else { return }
                    let toRemove = mapView.overlays.compactMap { $0 as? IdentifiedPolyline }.filter { $0.activityId == id }
                    mapView.removeOverlays(toRemove)
                    self.addSlopeSegments(coords, bands: bands, baseColor: baseColor, activityId: id, to: mapView)
                }
            }
        }

        public func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
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
            return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
