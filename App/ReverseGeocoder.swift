import Foundation
import CoreLocation
import GPXCore

/// Limiteur à fenêtre glissante pour respecter le quota CLGeocoder (~50 req/60 s).
/// On vise 45 pour garder une marge.
actor GeocodeThrottler {
    private var timestamps: [Date] = []
    private let maxRequests: Int
    private let window: TimeInterval

    init(maxRequests: Int = 45, window: TimeInterval = 60) {
        self.maxRequests = maxRequests
        self.window = window
    }

    func waitForSlot() async {
        prune()
        if timestamps.count >= maxRequests, let oldest = timestamps.first {
            let wait = window - Date().timeIntervalSince(oldest) + 0.5
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            prune()
        }
        timestamps.append(Date())
    }

    private func prune() {
        let now = Date()
        timestamps.removeAll { now.timeIntervalSince($0) >= window }
    }
}

@MainActor
enum ReverseGeocoder {
    private static var cache: [String: String] = [:]
    private static let throttler = GeocodeThrottler()

    static func placeName(latitude: Double, longitude: Double, preferPOI: Bool) async -> String? {
        let key = cacheKey(latitude: latitude, longitude: longitude, preferPOI: preferPOI)
        if let cached = cache[key] {
            return cached.isEmpty ? nil : cached
        }

        await throttler.waitForSlot()

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "fr_FR"))
            let name = placemarks.first.flatMap { bestName(from: $0, preferPOI: preferPOI) }
            cache[key] = name ?? ""
            return name
        } catch {
            NSLog("GPXManagement: reverse geocode failed (\(latitude),\(longitude)): \(error.localizedDescription)")
            // On ne met pas en cache les échecs (réseau/throttle) pour pouvoir réessayer plus tard.
            return nil
        }
    }

    private static func cacheKey(latitude: Double, longitude: Double, preferPOI: Bool) -> String {
        // ~3 décimales ≈ 110 m : suffisant pour regrouper départs/arrivées d'un même lieu.
        String(format: "%.3f,%.3f,%d", latitude, longitude, preferPOI ? 1 : 0)
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
