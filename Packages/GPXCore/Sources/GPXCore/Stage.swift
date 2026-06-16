import Foundation

/// Étape d'un parcours : plage de points `[startIndex...endIndex]` d'une trace, avec nom, notes et photo.
/// Persistée comme entité Core Data « Stage » (parent = `activityId`).
public struct Stage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let activityId: UUID
    public var order: Int
    public var name: String
    public var notes: String?
    public var startIndex: Int
    public var endIndex: Int
    public var coverImageData: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), activityId: UUID, order: Int, name: String, notes: String? = nil,
                startIndex: Int, endIndex: Int, coverImageData: Data? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.activityId = activityId
        self.order = order
        self.name = name
        self.notes = notes
        self.startIndex = Swift.min(startIndex, endIndex)
        self.endIndex = Swift.max(startIndex, endIndex)
        self.coverImageData = coverImageData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Points couverts, bornés au tableau (robuste si la trace a changé).
    public func slice(of points: [TrackPoint]) -> [TrackPoint] {
        guard !points.isEmpty else { return [] }
        let lo = Swift.max(0, Swift.min(startIndex, points.count - 1))
        let hi = Swift.max(lo, Swift.min(endIndex, points.count - 1))
        return Array(points[lo...hi])
    }

    public func stats(in points: [TrackPoint]) -> ActivityStats {
        ActivityStatsCalculator.compute(points: slice(of: points))
    }
}
