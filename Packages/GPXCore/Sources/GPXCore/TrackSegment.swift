import Foundation

/// Segment d'une trace : plage de points `[startIndex...endIndex]` nommée, persistée en JSON dans `Activity.segmentsData`.
public struct TrackSegment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let startIndex: Int
    public let endIndex: Int

    public init(id: UUID = UUID(), name: String, startIndex: Int, endIndex: Int) {
        self.id = id
        self.name = name
        self.startIndex = Swift.min(startIndex, endIndex)
        self.endIndex = Swift.max(startIndex, endIndex)
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

    /// Nom par défaut d'un segment (« Km 2 – 7,5 »), partagé entre découpe auto et création manuelle.
    public static func defaultName(fromMeters start: Double, toMeters end: Double) -> String {
        "Km \(kmLabel(start)) – \(kmLabel(end))"
    }

    private static func kmLabel(_ meters: Double) -> String {
        let km = (meters / 100).rounded() / 10
        return km == km.rounded() ? String(Int(km)) : String(format: "%.1f", locale: Locale(identifier: "fr_FR"), km)
    }
}
