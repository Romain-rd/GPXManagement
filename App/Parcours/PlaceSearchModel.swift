import MapKit
import Observation

/// Autocomplétion de lieux au fur et à mesure de la saisie (MKLocalSearchCompleter), pour l'éditeur de parcours.
@MainActor
@Observable
final class PlaceSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" { didSet { completer.queryFragment = query } }
    var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Biaise les suggestions vers la zone visible de la carte.
    func bias(to region: MKCoordinateRegion?) { if let region { completer.region = region } }

    func clear() { query = ""; suggestions = [] }

    /// Résout une suggestion en coordonnée (titre + position).
    func resolve(_ completion: MKLocalSearchCompletion) async -> (name: String, coordinate: CLLocationCoordinate2D)? {
        guard let response = try? await MKLocalSearch(request: .init(completion: completion)).start(),
              let item = response.mapItems.first else { return nil }
        return (completion.title, item.placemark.coordinate)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
