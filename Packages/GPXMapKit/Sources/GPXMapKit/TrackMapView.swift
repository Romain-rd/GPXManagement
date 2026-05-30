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

    public init(tracks: [TrackOverlayInput], layer: Binding<MapLayer>, proxy: MapViewProxy? = nil, highlight: CLLocationCoordinate2D? = nil, onSelectActivity: ((UUID) -> Void)? = nil) {
        self.tracks = tracks
        self._layer = layer
        self.proxy = proxy
        self.highlight = highlight
        self.onSelectActivity = onSelectActivity
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSelectActivity: onSelectActivity)
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
            let overlay = IGNTileOverlay(layer: layer)
            // canReplaceMapContent=true → la tuile sert de fond et masque les labels Apple ;
            // les polylines (ajoutées ensuite, même niveau) se dessinent par-dessus.
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    public final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var currentLayer: MapLayer = .ignPlanV2
        var lastTrackIds: Set<UUID> = []
        private let onSelectActivity: ((UUID) -> Void)?
        private var highlightAnnotation: HighlightAnnotation?

        init(onSelectActivity: ((UUID) -> Void)?) {
            self.onSelectActivity = onSelectActivity
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
                let polyline = IdentifiedPolyline(coordinates: track.coordinates, count: track.coordinates.count)
                polyline.activityId = track.activityId
                polyline.activityType = track.activityType
                polyline.color = useRotation ? MapTrackPalette.color(at: index) : track.activityType.trackColor
                mapView.addOverlay(polyline, level: .aboveLabels)
                allCoords.append(contentsOf: track.coordinates)
            }

            if fitOnChange, !allCoords.isEmpty {
                let rect = polylineRect(allCoords)
                mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
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
            guard annotation is HighlightAnnotation else { return nil }
            let identifier = "highlight"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.image = Self.highlightImage
            view.centerOffset = .zero
            view.canShowCallout = false
            return view
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
