import Foundation
import GPXCore
import MapKit

enum ConnectorRouter {
    enum Engine: String, CaseIterable { case mapkit, trail, car, line }

    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, engine: Engine) async -> [CLLocationCoordinate2D] {
        switch engine {
        case .line:
            return [from, to]
        case .mapkit:
            // MapKit refuse les segments très longs / transfrontaliers : repli BRouter avant la ligne droite.
            if let m = await mapkitRoute(from: from, to: to, transportType: .walking) { return m }
            if let b = await trailRoute(from: from, to: to, profile: "trekking") { return b }
            return [from, to]
        case .car:
            if let m = await mapkitRoute(from: from, to: to, transportType: .automobile) { return m }
            if let b = await trailRoute(from: from, to: to, profile: "car-fast") { return b }
            return [from, to]
        case .trail:
            if let t = await trailRoute(from: from, to: to, profile: "hiking-mountain") { return t }
            if let m = await mapkitRoute(from: from, to: to, transportType: .walking) { return m }
            return [from, to]
        }
    }

    private static func mapkitRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, transportType: MKDirectionsTransportType) async -> [CLLocationCoordinate2D]? {
        // MKDirections est limité en débit (throttling) : on réessaie avec un délai croissant.
        for attempt in 0..<4 {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            request.transportType = transportType
            do {
                let response = try await MKDirections(request: request).calculate()
                guard let polyline = response.routes.first?.polyline else { return nil }
                var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
                polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
                return coords.filter { CLLocationCoordinate2DIsValid($0) }
            } catch {
                let code = (error as NSError).code
                // MKError.loadingThrottled (3) / serverFailure : on attend puis on réessaie.
                guard attempt < 3, code == MKError.loadingThrottled.rawValue || code == MKError.serverFailure.rawValue else { return nil }
                try? await Task.sleep(nanoseconds: UInt64(0.7 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        return nil
    }

    private static func trailRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: String = "hiking-mountain") async -> [CLLocationCoordinate2D]? {
        // BRouter (serveur public) → GeoJSON [[lon,lat,(ele)],…]. Pas de limite de distance, transfrontalier.
        let urlStr = "https://brouter.de/brouter?lonlats=\(from.longitude),\(from.latitude)|\(to.longitude),\(to.latitude)&profile=\(profile)&alternativeidx=0&format=geojson"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct GeoJSON: Decodable {
            let features: [Feature]
            struct Feature: Decodable { let geometry: Geometry }
            struct Geometry: Decodable { let coordinates: [[Double]] }
        }
        guard let gj = try? JSONDecoder().decode(GeoJSON.self, from: data),
              let coords = gj.features.first?.geometry.coordinates, coords.count >= 2 else { return nil }
        return coords.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
    }
}
