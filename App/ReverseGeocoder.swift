import Foundation
import CoreLocation
import GPXCore

@MainActor
enum ReverseGeocoder {
    static func placeName(latitude: Double, longitude: Double, preferPOI: Bool) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "fr_FR"))
            guard let placemark = placemarks.first else { return nil }
            return bestName(from: placemark, preferPOI: preferPOI)
        } catch {
            NSLog("GPXManagement: reverse geocode failed (\(latitude),\(longitude)): \(error)")
            return nil
        }
    }

    private static func bestName(from placemark: CLPlacemark, preferPOI: Bool) -> String? {
        if preferPOI, let aoi = placemark.areasOfInterest?.first { return aoi }
        if let locality = placemark.locality { return locality }
        if let subLocality = placemark.subLocality { return subLocality }
        if let aoi = placemark.areasOfInterest?.first { return aoi }
        if let inlandWater = placemark.inlandWater { return inlandWater }
        if let name = placemark.name { return name }
        return nil
    }
}

@MainActor
enum RouteNamer {
    static func suggestName(points: [TrackPoint]) async -> String? {
        guard let wp = WaypointSelector.waypoints(from: points) else { return nil }

        let startName = await ReverseGeocoder.placeName(latitude: wp.start.latitude, longitude: wp.start.longitude, preferPOI: false)

        var viaName: String?
        if let via = wp.via {
            viaName = await ReverseGeocoder.placeName(latitude: via.latitude, longitude: via.longitude, preferPOI: true)
        }

        let endName = wp.isLoop
            ? startName
            : await ReverseGeocoder.placeName(latitude: wp.end.latitude, longitude: wp.end.longitude, preferPOI: false)

        return RouteNameBuilder.build(startName: startName, viaName: viaName, endName: endName, isLoop: wp.isLoop)
    }
}
