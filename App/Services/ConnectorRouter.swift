import Foundation
import GPXCore
import MapKit

/// Fournisseur de routage (choix global, dans les Préférences). Certains demandent une clé API perso.
enum RoutingProvider: String, CaseIterable, Identifiable {
    case mapkit, ign, ors, graphhopper, brouter, line
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mapkit: return "Apple Plans (MapKit)"
        case .ign: return "IGN Géoplateforme"
        case .ors: return "OpenRouteService"
        case .graphhopper: return "GraphHopper"
        case .brouter: return "BRouter"
        case .line: return "Ligne droite"
        }
    }
    var note: String {
        switch self {
        case .mapkit: return "Sans clé. À pied / route. Peut être saturé (limite Apple) sur de longs parcours."
        case .ign: return "Sans clé, idéal en France. Route / à pied (vélo routé comme à pied)."
        case .ors: return "Clé gratuite requise. Tous profils, transfrontalier, dénivelé."
        case .graphhopper: return "Clé gratuite requise. Tous profils, quota journalier plus serré."
        case .brouter: return "Sans clé (serveur public). Tous profils, qualité variable."
        case .line: return "Relie les points en ligne droite (aucun routage)."
        }
    }
    var needsKey: Bool { self == .ors || self == .graphhopper }
    var keyDefaultsKey: String? {
        switch self {
        case .ors: return "orsApiKey"
        case .graphhopper: return "graphHopperApiKey"
        default: return nil
        }
    }
    var helpURL: URL? {
        switch self {
        case .ors: return URL(string: "https://openrouteservice.org/dev/#/signup")
        case .graphhopper: return URL(string: "https://www.graphhopper.com/")
        default: return nil
        }
    }
}

/// Profil de déplacement (choix par parcours, dans l'éditeur).
enum RouteProfile: String, CaseIterable, Identifiable {
    case foot, bike, car, line
    var id: String { rawValue }
    var label: String {
        switch self {
        case .foot: return "À pied"
        case .bike: return "Vélo"
        case .car: return "Route & moto"
        case .line: return "Ligne droite"
        }
    }
}

enum ConnectorRouter {
    // Provider/clés lus globalement ; le profil vient du parcours (éditeur).
    private static var provider: RoutingProvider { RoutingProvider(rawValue: UserDefaults.standard.string(forKey: "routingProvider") ?? "") ?? .mapkit }
    /// Seul MapKit est limité en débit → ne temporiser entre segments que pour lui.
    static var needsPacing: Bool { provider == .mapkit }
    private static func key(_ p: RoutingProvider) -> String? {
        guard let k = p.keyDefaultsKey, let v = UserDefaults.standard.string(forKey: k)?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    /// `fellBack` : le fournisseur principal a échoué et on a utilisé un repli (BRouter) → route potentiellement moins bonne.
    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: RouteProfile) async -> (coords: [CLLocationCoordinate2D], fellBack: Bool) {
        if profile == .line { return ([from, to], false) }
        let prov = provider
        if prov == .line { return ([from, to], false) }

        if let primary = await routeWith(prov, from: from, to: to, profile: profile), primary.count >= 2 {
            return (primary, false)
        }
        // Repli BRouter (sans clé, transfrontalier) avant la ligne droite.
        if prov != .brouter, let b = await brouterRoute(from: from, to: to, profile: brouterProfile(profile)), b.count >= 2 {
            print("⚠️ [ConnectorRouter] \(prov.label) indisponible → repli BRouter")
            return (b, true)
        }
        return ([from, to], true)
    }

    private static func routeWith(_ prov: RoutingProvider, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: RouteProfile) async -> [CLLocationCoordinate2D]? {
        switch prov {
        case .line: return [from, to]
        case .mapkit: return await mapkitRoute(from: from, to: to, transportType: profile == .car ? .automobile : .walking)
        case .ign: return await ignRoute(from: from, to: to, profile: profile)
        case .brouter: return await brouterRoute(from: from, to: to, profile: brouterProfile(profile))
        case .ors:
            guard let k = key(.ors) else { return nil }
            return await orsRoute(from: from, to: to, profile: profile, key: k)
        case .graphhopper:
            guard let k = key(.graphhopper) else { return nil }
            return await graphHopperRoute(from: from, to: to, profile: profile, key: k)
        }
    }

    private static func brouterProfile(_ p: RouteProfile) -> String {
        switch p {
        case .foot: return "hiking-mountain"
        case .bike: return "trekking"
        case .car, .line: return "car-fast"
        }
    }

    // MARK: - MapKit (Apple Plans)

    private static func mapkitRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, transportType: MKDirectionsTransportType) async -> [CLLocationCoordinate2D]? {
        let maxAttempts = 7
        for attempt in 0..<maxAttempts {
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
                let permanent = code == MKError.directionsNotFound.rawValue || code == MKError.placemarkNotFound.rawValue
                guard !permanent, attempt < maxAttempts - 1 else { return nil }
                try? await Task.sleep(nanoseconds: UInt64(min(3.0, 0.6 * Double(attempt + 1)) * 1_000_000_000))
            }
        }
        return nil
    }

    // MARK: - IGN Géoplateforme (public, sans clé ; France)

    private static func ignRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: RouteProfile) async -> [CLLocationCoordinate2D]? {
        let ignProfile = profile == .car ? "car" : "pedestrian"   // pas de vélo dédié → à pied
        let urlStr = "https://data.geopf.fr/navigation/itineraire?resource=bdtopo-osrm&start=\(from.longitude),\(from.latitude)&end=\(to.longitude),\(to.latitude)&profile=\(ignProfile)&optimization=fastest&geometryFormat=geojson"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct R: Decodable { let geometry: Geom; struct Geom: Decodable { let coordinates: [[Double]] } }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return lonLat(r.geometry.coordinates)
    }

    // MARK: - OpenRouteService (clé)

    private static func orsRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: RouteProfile, key: String) async -> [CLLocationCoordinate2D]? {
        let orsProfile: String
        switch profile {
        case .foot: orsProfile = "foot-hiking"
        case .bike: orsProfile = "cycling-mountain"
        case .car, .line: orsProfile = "driving-car"
        }
        guard let url = URL(string: "https://api.openrouteservice.org/v2/directions/\(orsProfile)/geojson") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["coordinates": [[from.longitude, from.latitude], [to.longitude, to.latitude]]])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct R: Decodable { let features: [F]; struct F: Decodable { let geometry: Geom; struct Geom: Decodable { let coordinates: [[Double]] } } }
        guard let r = try? JSONDecoder().decode(R.self, from: data), let coords = r.features.first?.geometry.coordinates else { return nil }
        return lonLat(coords)
    }

    // MARK: - GraphHopper (clé)

    private static func graphHopperRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: RouteProfile, key: String) async -> [CLLocationCoordinate2D]? {
        let ghProfile: String
        switch profile {
        case .foot: ghProfile = "hike"
        case .bike: ghProfile = "bike"
        case .car, .line: ghProfile = "car"
        }
        let urlStr = "https://graphhopper.com/api/1/route?point=\(from.latitude),\(from.longitude)&point=\(to.latitude),\(to.longitude)&profile=\(ghProfile)&points_encoded=false&key=\(key)"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct R: Decodable { let paths: [P]; struct P: Decodable { let points: Geom; struct Geom: Decodable { let coordinates: [[Double]] } } }
        guard let r = try? JSONDecoder().decode(R.self, from: data), let coords = r.paths.first?.points.coordinates else { return nil }
        return lonLat(coords)
    }

    // MARK: - BRouter (public, sans clé ; repli universel)

    private static func brouterRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, profile: String) async -> [CLLocationCoordinate2D]? {
        let urlStr = "https://brouter.de/brouter?lonlats=\(from.longitude),\(from.latitude)|\(to.longitude),\(to.latitude)&profile=\(profile)&alternativeidx=0&format=geojson"
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct GeoJSON: Decodable { let features: [Feature]; struct Feature: Decodable { let geometry: Geometry }; struct Geometry: Decodable { let coordinates: [[Double]] } }
        guard let gj = try? JSONDecoder().decode(GeoJSON.self, from: data), let coords = gj.features.first?.geometry.coordinates else { return nil }
        return lonLat(coords)
    }

    /// [[lon, lat, (ele)], …] → [CLLocationCoordinate2D].
    private static func lonLat(_ coords: [[Double]]) -> [CLLocationCoordinate2D]? {
        let out = coords.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        return out.count >= 2 ? out : nil
    }
}
