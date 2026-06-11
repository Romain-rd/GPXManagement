import Foundation
import GPXCore

/// État non-UI du détail d'activité : liens publiés (web/film) et métriques dérivées du tracé.
@MainActor
@Observable
final class ActivityDetailViewModel {
    private let repository: CoreDataActivityRepository

    var publishedURL: String?
    var filmPublishedURL: String?
    var publishConfigJSON: String?

    var climbCount: Int?
    var ascentTime: TimeInterval?
    var descentTime: TimeInterval?
    var flatTime: TimeInterval?
    var movingTime: TimeInterval?
    var pausedTime: TimeInterval?

    var segments: [TrackSegment] = []
    var segmentStats: [UUID: ActivityStats] = [:]
    private var segmentPoints: [TrackPoint] = []

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
              let points = try? TrackPointCodec.decode(data) else {
            climbCount = nil; ascentTime = nil; descentTime = nil; return
        }
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
        guard let data = try? await repository.fetchTrackData(id: activityId), !data.isEmpty,
              let points = try? TrackPointCodec.decode(data), points.count > 1 else { return }
        segmentPoints = points
        let segmentsData = (try? await repository.fetchSegmentsData(id: activityId)) ?? nil
        segments = TrackSegment.decode(segmentsData)
        recomputeSegmentStats()
    }

    func splitSegments(every meters: Double, activityId: UUID) async {
        segments = TrackSegmentBuilder.byDistance(points: segmentPoints, every: meters)
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
