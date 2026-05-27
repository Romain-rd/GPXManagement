import Foundation

public struct ActivityDescriptor: Sendable, Equatable {
    public let id: UUID
    public let startDate: Date
    public let activityType: ActivityType
    public let title: String
    public let sourceFileFormat: SourceFileFormat

    public init(
        id: UUID,
        startDate: Date,
        activityType: ActivityType,
        title: String,
        sourceFileFormat: SourceFileFormat
    ) {
        self.id = id
        self.startDate = startDate
        self.activityType = activityType
        self.title = title
        self.sourceFileFormat = sourceFileFormat
    }
}
