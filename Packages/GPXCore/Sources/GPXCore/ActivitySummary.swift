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
    public let sourceApp: String?
    public let tags: [String]
    public let notes: String?
    public let raidId: UUID?

    /// Catégorie dérivée de `sourceApp` pour l'affichage et le filtrage.
    public var source: ActivitySource { ActivitySource(rawCreator: sourceApp) }

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
        sourceApp: String? = nil,
        tags: [String],
        notes: String?,
        raidId: UUID? = nil
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
        self.sourceApp = sourceApp
        self.tags = tags
        self.notes = notes
        self.raidId = raidId
    }

    public func updatingTitle(_ newTitle: String) -> ActivitySummary {
        ActivitySummary(id: id, title: newTitle, activityType: activityType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: notes, raidId: raidId)
    }

    public func updatingNotes(_ newNotes: String?) -> ActivitySummary {
        ActivitySummary(id: id, title: title, activityType: activityType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: newNotes, raidId: raidId)
    }

    public func updatingActivityType(_ newType: ActivityType) -> ActivitySummary {
        ActivitySummary(id: id, title: title, activityType: newType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: notes, raidId: raidId)
    }
}
