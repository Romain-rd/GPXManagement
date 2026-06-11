import Foundation

/// Segment d'une trace : plage de points `[startIndex...endIndex]` nommée, persistée en JSON dans `Activity.segmentsData`.
public struct TrackSegment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let startIndex: Int
    public let endIndex: Int
    /// Phase d'origine si le segment vient de la découpe par phase (la vitesse n'a pas de sens pour une pause).
    public let phase: TrackPhase?

    public init(id: UUID = UUID(), name: String, startIndex: Int, endIndex: Int, phase: TrackPhase? = nil) {
        self.id = id
        self.name = name
        self.startIndex = Swift.min(startIndex, endIndex)
        self.endIndex = Swift.max(startIndex, endIndex)
        self.phase = phase
    }

    /// Points couverts, bornés au tableau — robuste si la trace a changé depuis la création du segment.
    public func slice(of points: [TrackPoint]) -> [TrackPoint] {
        guard !points.isEmpty else { return [] }
        let lower = Swift.max(0, Swift.min(startIndex, points.count - 1))
        let upper = Swift.max(lower, Swift.min(endIndex, points.count - 1))
        return Array(points[lower...upper])
    }

    public func stats(in points: [TrackPoint]) -> ActivityStats {
        ActivityStatsCalculator.compute(points: slice(of: points))
    }

    public static func encode(_ segments: [TrackSegment]) -> Data? {
        segments.isEmpty ? nil : try? JSONEncoder().encode(segments)
    }

    public static func decode(_ data: Data?) -> [TrackSegment] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([TrackSegment].self, from: data)) ?? []
    }
}

/// Phase d'une portion de trace, pour la découpe automatique par changement de type.
public enum TrackPhase: String, Codable, Sendable, Hashable {
    case ascent, descent, flat, pause

    public var label: String {
        switch self {
        case .ascent: return "Montée"
        case .descent: return "Descente"
        case .flat: return "Plat"
        case .pause: return "Pause"
        }
    }
}

public enum TrackSegmentBuilder {
    /// Découpe la trace en segments consécutifs de `meters` ; le dernier segment porte le reliquat.
    public static func byDistance(points: [TrackPoint], every meters: Double) -> [TrackSegment] {
        guard points.count > 1, meters > 0 else { return [] }
        var segments: [TrackSegment] = []
        var startIndex = 0
        var startDistance: Double = 0
        var cumulative: Double = 0
        for i in 1..<points.count {
            cumulative += GeoMath.distance(points[i - 1], points[i])
            if cumulative - startDistance >= meters {
                segments.append(TrackSegment(name: defaultName(fromMeters: startDistance, toMeters: cumulative), startIndex: startIndex, endIndex: i))
                startIndex = i
                startDistance = cumulative
            }
        }
        if startIndex < points.count - 1 {
            segments.append(TrackSegment(name: defaultName(fromMeters: startDistance, toMeters: cumulative), startIndex: startIndex, endIndex: points.count - 1))
        }
        return segments
    }

    /// Découpe la trace en segments consécutifs de `seconds` de temps écoulé ; le dernier porte le reliquat.
    public static func byDuration(points: [TrackPoint], every seconds: TimeInterval) -> [TrackSegment] {
        guard points.count > 1, seconds > 0,
              let t0 = points.first(where: { $0.timestamp != nil })?.timestamp else { return [] }
        var segments: [TrackSegment] = []
        var startIndex = 0
        var startElapsed: TimeInterval = 0
        var lastElapsed: TimeInterval = 0
        for i in 1..<points.count {
            guard let t = points[i].timestamp else { continue }
            let elapsed = t.timeIntervalSince(t0)
            lastElapsed = elapsed
            if elapsed - startElapsed >= seconds {
                segments.append(TrackSegment(name: durationName(from: startElapsed, to: elapsed), startIndex: startIndex, endIndex: i))
                startIndex = i
                startElapsed = elapsed
            }
        }
        if startIndex < points.count - 1 {
            segments.append(TrackSegment(name: durationName(from: startElapsed, to: lastElapsed), startIndex: startIndex, endIndex: points.count - 1))
        }
        return segments
    }

    /// Découpe par changement de phase (montée/descente/plat/pause), avec la même classification que
    /// `timeBreakdown` (pente lissée, zone morte `flatPercent`, pauses par cluster/trou).
    /// Les phases plus courtes que `minPhaseDuration` (hors pauses, longues par construction) sont
    /// fusionnées dans leur voisin le plus long pour éviter l'émiettement en terrain vallonné.
    public static func byPhase(points: [TrackPoint],
                               pauseMinSeconds: Double = 300, pauseRadiusMeters: Double = 40,
                               flatPercent: Double = 1.0, minPhaseDuration: TimeInterval = 90) -> [TrackSegment] {
        guard points.count > 1 else { return [] }
        let motion = ElevationProfileBuilder.buildMotion(points: points)
        let paused = ElevationProfileBuilder.pausedSegmentFlags(motion, pauseMinSeconds: pauseMinSeconds, pauseRadiusMeters: pauseRadiusMeters)
        // Pentes alignées sur les indices originaux : le profil altimétrique ignore les points sans altitude,
        // donc on ne classe par pente que si l'alignement est garanti (sinon tout est « plat », pauses conservées).
        let altProfile = ElevationProfileBuilder.build(points: points)
        let slopes = altProfile.count == points.count ? altProfile.map(\.slope) : [Double](repeating: 0, count: points.count)

        var phases: [TrackPhase] = []
        phases.reserveCapacity(points.count - 1)
        for s in 0..<(points.count - 1) {
            if paused[s] { phases.append(.pause) }
            else if slopes[s] > flatPercent { phases.append(.ascent) }
            else if slopes[s] < -flatPercent { phases.append(.descent) }
            else { phases.append(.flat) }
        }

        struct Run { var phase: TrackPhase; var start: Int; var end: Int } // indices inter-points inclus
        var runs: [Run] = []
        var s = 0
        while s < phases.count {
            var e = s
            while e + 1 < phases.count, phases[e + 1] == phases[s] { e += 1 }
            runs.append(Run(phase: phases[s], start: s, end: e))
            s = e + 1
        }

        func duration(_ run: Run) -> TimeInterval? {
            guard let a = points[run.start].timestamp, let b = points[run.end + 1].timestamp else { return nil }
            return b.timeIntervalSince(a)
        }
        while runs.count > 1 {
            var shortest: (index: Int, duration: TimeInterval)?
            for (i, run) in runs.enumerated() where run.phase != .pause {
                guard let d = duration(run), d < minPhaseDuration else { continue }
                if shortest == nil || d < shortest!.duration { shortest = (i, d) }
            }
            guard let victim = shortest else { break }
            let i = victim.index
            // Voisin préféré : hors pause si possible (pour ne pas étirer une pause), sinon le plus long.
            let candidates = [i - 1, i + 1].filter { runs.indices.contains($0) }
            let nonPause = candidates.filter { runs[$0].phase != .pause }
            let pool = nonPause.isEmpty ? candidates : nonPause
            let target = pool.max { (duration(runs[$0]) ?? .greatestFiniteMagnitude) < (duration(runs[$1]) ?? .greatestFiniteMagnitude) }!
            if target < i { runs[target].end = runs[i].end } else { runs[target].start = runs[i].start }
            runs.remove(at: i)
            var k = 0
            while k + 1 < runs.count {
                if runs[k].phase == runs[k + 1].phase {
                    runs[k].end = runs[k + 1].end
                    runs.remove(at: k + 1)
                } else { k += 1 }
            }
        }

        var counters: [TrackPhase: Int] = [:]
        return runs.map { run in
            counters[run.phase, default: 0] += 1
            return TrackSegment(name: "\(run.phase.label) \(counters[run.phase]!)", startIndex: run.start, endIndex: run.end + 1, phase: run.phase)
        }
    }

    /// Nom par défaut d'un segment (« Km 2 – 7,5 »), partagé entre découpe auto et création manuelle.
    public static func defaultName(fromMeters start: Double, toMeters end: Double) -> String {
        "Km \(kmLabel(start)) – \(kmLabel(end))"
    }

    private static func durationName(from start: TimeInterval, to end: TimeInterval) -> String {
        "\(clockLabel(start)) – \(clockLabel(end))"
    }

    /// Temps écoulé au format « 1h30 », arrondi à la minute.
    private static func clockLabel(_ t: TimeInterval) -> String {
        let minutes = Int((t / 60).rounded())
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    private static func kmLabel(_ meters: Double) -> String {
        let km = (meters / 100).rounded() / 10
        return km == km.rounded() ? String(Int(km)) : String(format: "%.1f", locale: Locale(identifier: "fr_FR"), km)
    }
}
