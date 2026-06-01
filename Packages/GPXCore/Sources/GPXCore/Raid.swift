import Foundation

public struct RaidParticipant: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var avatarAssetId: String?

    public init(id: UUID = UUID(), name: String, avatarAssetId: String? = nil) {
        self.id = id
        self.name = name
        self.avatarAssetId = avatarAssetId
    }
}

public struct Raid: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var subtitle: String?
    public var place: String?
    public var notes: String?
    public var startDate: Date?
    public var endDate: Date?
    public var coverAssetId: String?
    public var participants: [RaidParticipant]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String? = nil,
        place: String? = nil,
        notes: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        coverAssetId: String? = nil,
        participants: [RaidParticipant] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.place = place
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.coverAssetId = coverAssetId
        self.participants = participants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
