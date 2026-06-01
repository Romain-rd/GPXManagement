import Foundation

public struct RaidParticipant: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var avatarImageData: Data?

    public init(id: UUID = UUID(), name: String, avatarImageData: Data? = nil) {
        self.id = id
        self.name = name
        self.avatarImageData = avatarImageData
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
    public var coverImageData: Data?
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
        coverImageData: Data? = nil,
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
        self.coverImageData = coverImageData
        self.participants = participants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
