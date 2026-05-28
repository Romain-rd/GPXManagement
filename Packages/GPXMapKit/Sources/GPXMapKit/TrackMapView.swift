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

public struct TrackMapView: NSViewRepresentable {
    public let tracks: [TrackOverlayInput]
    @Binding public var layer: MapLayer
    public var onSelectActivity: ((UUID) -> Void)?

    public init(tracks: [TrackOverlayInput], layer: Binding<MapLayer>, onSelectActivity: ((UUID) -> Void)? = nil) {
        self.tracks = tracks
        self._layer = layer
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
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    public final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var currentLayer: MapLayer = .ignPlanV2
        var lastTrackIds: Set<UUID> = []
        private let onSelectActivity: ((UUID) -> Void)?

        init(onSelectActivity: ((UUID) -> Void)?) {
            self.onSelectActivity = onSelectActivity
        }

        func applyTracks(_ tracks: [TrackOverlayInput], to mapView: MKMapView, fitOnChange: Bool) {
            let existingPolylines = mapView.overlays.compactMap { $0 as? IdentifiedPolyline }
            mapView.removeOverlays(existingPolylines)

            var allCoords: [CLLocationCoordinate2D] = []
            for track in tracks where !track.coordinates.isEmpty {
                let polyline = IdentifiedPolyline(coordinates: track.coordinates, count: track.coordinates.count)
                polyline.activityId = track.activityId
                polyline.activityType = track.activityType
                mapView.addOverlay(polyline)
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
                renderer.strokeColor = identified.activityType?.trackColor ?? .systemBlue
                renderer.lineWidth = 4
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
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
}
