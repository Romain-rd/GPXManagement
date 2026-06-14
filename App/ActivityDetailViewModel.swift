import Foundation
import CoreLocation
import GPXCore

/// État non-UI du détail d'activité : liens publiés (web/film) et métriques dérivées du tracé.
@MainActor
@Observable
final class ActivityDetailViewModel {
    private let repository: CoreDataActivityRepository

    var publishedURL: String?
    var filmPublishedURL: String?
    var publishConfigJSON: String?

    /// Faux quand l'activité n'a aucun point GPS (séance sans tracé : escalade en salle, fitness…).
    var hasTrack: Bool = true
    var climbCount: Int?
    var ascentTime: TimeInterval?
    var descentTime: TimeInterval?
    var flatTime: TimeInterval?
    var movingTime: TimeInterval?
    var pausedTime: TimeInterval?

    var segments: [TrackSegment] = []
    var segmentStats: [UUID: ActivityStats] = [:]
    private var segmentPoints: [TrackPoint] = []
    private var cumulativeDistances: [Double] = []

    init(repository: CoreDataActivityRepository) {
        self.repository = repository
    }

    func resetPublishState() {
        publishedURL = nil
        publishConfigJSON = nil
    }

    func loadPublishState(activityId: UUID) async {
        publishedURL = try? await repository.fetchWebPublishedURL(id: activityId)
        publishConfigJSON = try? await repository.fetchWebPublishConfig(id: activityId)
        filmPublishedURL = try? await repository.fetchFilmPublishedURL(id: activityId)
    }

    /// UUID du dossier déjà publié (extrait du lien stocké) pour republier au même endroit.
    func existingPublishUUID() -> String? {
        guard let s = publishedURL, let comps = URLComponents(string: s) else { return nil }
        return comps.path.split(separator: "/").map(String.init).last
    }

    func loadDerivedMetrics(for activity: ActivitySummary, pauseMinSeconds: Double, pauseRadiusMeters: Double) async {
        guard let data = try? await repository.fetchTrackData(id: activity.id), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data), !points.isEmpty else {
            hasTrack = false
            climbCount = nil; ascentTime = nil; descentTime = nil
            movingTime = nil; pausedTime = nil; flatTime = nil
            return
        }
        hasTrack = true
        if activity.activityType == .climbing {
            let altitudes = points.compactMap(\.altitude)
            climbCount = altitudes.count >= 2 ? ClimbCounter.count(altitudes: altitudes) : nil
        } else { climbCount = nil }

        if activity.activityType.tracksDistanceAndSpeed {
            // Partition du temps (somme = total) : pause / montée / descente / plat.
            let bd = ElevationProfileBuilder.timeBreakdown(
                ElevationProfileBuilder.build(points: points),
                pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
            ascentTime = bd.ascending > 0 ? bd.ascending : nil
            descentTime = bd.descending > 0 ? bd.descending : nil
            flatTime = bd.flat > 0 ? bd.flat : nil
            let moving = bd.ascending + bd.descending + bd.flat
            movingTime = moving > 0 ? moving : nil
            pausedTime = bd.paused > 0 ? bd.paused : nil
        } else { ascentTime = nil; descentTime = nil; flatTime = nil; movingTime = nil; pausedTime = nil }
    }

    // MARK: - Segments

    func loadSegments(activityId: UUID) async {
        segments = []
        segmentStats = [:]
        segmentPoints = []
        cumulativeDistances = []
        guard let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data), points.count > 1 else { return }
        segmentPoints = points
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + GeoMath.distance(points[i - 1], points[i]))
        }
        cumulativeDistances = cumulative
        let segmentsData = (try? await repository.fetchSegmentsData(id: activityId)) ?? nil
        segments = TrackSegment.decode(segmentsData)
        recomputeSegmentStats()
    }

    /// Création manuelle depuis le profil : convertit les distances (m) en indices de points.
    /// Retourne le segment créé (pour le sélectionner dans l'UI).
    @discardableResult
    func createSegment(fromMeters: Double, toMeters: Double, activityId: UUID) async -> TrackSegment? {
        guard let start = pointIndex(atDistance: fromMeters),
              let end = pointIndex(atDistance: toMeters), end > start else { return nil }
        let segment = TrackSegment(
            name: TrackSegmentBuilder.defaultName(fromMeters: fromMeters, toMeters: toMeters),
            startIndex: start, endIndex: end)
        segments.append(segment)
        segmentStats[segment.id] = segment.stats(in: segmentPoints)
        await persistSegments(activityId: activityId)
        return segment
    }

    /// Coordonnées du segment pour le surlignage sur la carte.
    func segmentCoordinates(id: UUID) -> [CLLocationCoordinate2D] {
        guard let segment = segments.first(where: { $0.id == id }) else { return [] }
        return segment.slice(of: segmentPoints).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Plage du segment en mètres depuis le départ, pour le surlignage sur le profil.
    func segmentDistanceRange(id: UUID) -> ClosedRange<Double>? {
        guard let segment = segments.first(where: { $0.id == id }), !cumulativeDistances.isEmpty else { return nil }
        let lo = max(0, min(segment.startIndex, cumulativeDistances.count - 1))
        let hi = max(lo, min(segment.endIndex, cumulativeDistances.count - 1))
        return cumulativeDistances[lo]...cumulativeDistances[hi]
    }

    /// Index du point le plus proche d'une distance cumulée (recherche binaire).
    private func pointIndex(atDistance meters: Double) -> Int? {
        guard !cumulativeDistances.isEmpty else { return nil }
        var lo = 0, hi = cumulativeDistances.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulativeDistances[mid] < meters { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(cumulativeDistances[lo - 1] - meters) < abs(cumulativeDistances[lo] - meters) { return lo - 1 }
        return lo
    }

    func splitSegments(every meters: Double, activityId: UUID) async {
        segments = TrackSegmentBuilder.byDistance(points: segmentPoints, every: meters)
        recomputeSegmentStats()
        await persistSegments(activityId: activityId)
    }

    func splitSegmentsByDuration(every seconds: TimeInterval, activityId: UUID) async {
        segments = TrackSegmentBuilder.byDuration(points: segmentPoints, every: seconds)
        recomputeSegmentStats()
        await persistSegments(activityId: activityId)
    }

    func splitSegmentsByPhase(pauseMinSeconds: Double, pauseRadiusMeters: Double, activityId: UUID) async {
        segments = TrackSegmentBuilder.byPhase(points: segmentPoints, pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        recomputeSegmentStats()
        await persistSegments(activityId: activityId)
    }

    func setSegmentName(id: UUID, name: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].name = name
    }

    func deleteSegment(id: UUID, activityId: UUID) async {
        segments.removeAll { $0.id == id }
        segmentStats[id] = nil
        await persistSegments(activityId: activityId)
    }

    func deleteAllSegments(activityId: UUID) async {
        segments = []
        segmentStats = [:]
        await persistSegments(activityId: activityId)
    }

    func persistSegments(activityId: UUID) async {
        try? await repository.updateSegmentsData(id: activityId, data: TrackSegment.encode(segments))
    }

    private func recomputeSegmentStats() {
        segmentStats = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.stats(in: segmentPoints)) })
    }
}
