import Foundation

public struct ActivitySummary: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let activityType: ActivityType
    public let startDate: Date
    public let endDate: Date
    public let distance: Double
    public let duration: Double
    public let movingDuration: Double
    public let elevationGain: Double
    public let elevationLoss: Double
    public let avgSpeed: Double
    public let maxSpeed: Double
    public let avgHeartRate: Double?
    public let maxHeartRate: Double?
    public let sourceFileName: String
    public let sourceFileFormat: SourceFileFormat
    public let tags: [String]
    public let notes: String?

    public init(
        id: UUID,
        title: String,
        activityType: ActivityType,
        startDate: Date,
        endDate: Date,
        distance: Double,
        duration: Double,
        movingDuration: Double,
        elevationGain: Double,
        elevationLoss: Double,
        avgSpeed: Double,
        maxSpeed: Double,
        avgHeartRate: Double?,
        maxHeartRate: Double?,
        sourceFileName: String,
        sourceFileFormat: SourceFileFormat,
        tags: [String],
        notes: String?
    ) {
        self.id = id
        self.title = title
        self.activityType = activityType
        self.startDate = startDate
        self.endDate = endDate
        self.distance = distance
        self.duration = duration
        self.movingDuration = movingDuration
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.avgSpeed = avgSpeed
        self.maxSpeed = maxSpeed
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.sourceFileName = sourceFileName
        self.sourceFileFormat = sourceFileFormat
        self.tags = tags
        self.notes = notes
    }
}
