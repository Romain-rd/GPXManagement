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
    public let maxSlope: Double
    public let avgHeartRate: Double?
    public let maxHeartRate: Double?
    public let sourceFileName: String
    public let sourceFileFormat: SourceFileFormat
    public let sourceApp: String?
    public let tags: [String]
    public let notes: String?
    public let raidId: UUID?
    /// `true` = parcours (préparation, trace sans horodatage) ; `false` = activité réellement effectuée.
    public let isCourse: Bool
    /// `true` si l'activité a une page web ou un film publié sur GPXManagement.net.
    public let isPublished: Bool
    /// `true` si la trace est un parcours organisé en étapes.
    public let isStagedRoute: Bool
    /// `true` si la géométrie du parcours est modifiable (re-routage entre points de passage). `false` = trace
    /// fidèle (GR importé) : seules les annotations (stops/POI) sont éditables, jamais le tracé.
    public let isEditableRoute: Bool

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
        maxSlope: Double = 0,
        avgHeartRate: Double?,
        maxHeartRate: Double?,
        sourceFileName: String,
        sourceFileFormat: SourceFileFormat,
        sourceApp: String? = nil,
        tags: [String],
        notes: String?,
        raidId: UUID? = nil,
        isCourse: Bool = false,
        isPublished: Bool = false,
        isStagedRoute: Bool = false,
        isEditableRoute: Bool = false
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
        self.maxSlope = maxSlope
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.sourceFileName = sourceFileName
        self.sourceFileFormat = sourceFileFormat
        self.sourceApp = sourceApp
        self.tags = tags
        self.notes = notes
        self.raidId = raidId
        self.isCourse = isCourse
        self.isPublished = isPublished
        self.isStagedRoute = isStagedRoute
        self.isEditableRoute = isEditableRoute
    }

    public func updatingTitle(_ newTitle: String) -> ActivitySummary {
        ActivitySummary(id: id, title: newTitle, activityType: activityType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, maxSlope: maxSlope, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: notes, raidId: raidId, isCourse: isCourse, isPublished: isPublished, isStagedRoute: isStagedRoute, isEditableRoute: isEditableRoute)
    }

    public func updatingNotes(_ newNotes: String?) -> ActivitySummary {
        ActivitySummary(id: id, title: title, activityType: activityType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, maxSlope: maxSlope, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: newNotes, raidId: raidId, isCourse: isCourse, isPublished: isPublished, isStagedRoute: isStagedRoute, isEditableRoute: isEditableRoute)
    }

    public func updatingActivityType(_ newType: ActivityType) -> ActivitySummary {
        ActivitySummary(id: id, title: title, activityType: newType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, maxSlope: maxSlope, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: notes, raidId: raidId, isCourse: isCourse, isPublished: isPublished, isStagedRoute: isStagedRoute, isEditableRoute: isEditableRoute)
    }

    public func updatingIsCourse(_ newIsCourse: Bool) -> ActivitySummary {
        ActivitySummary(id: id, title: title, activityType: activityType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, maxSlope: maxSlope, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: notes, raidId: raidId, isCourse: newIsCourse, isPublished: isPublished, isStagedRoute: isStagedRoute, isEditableRoute: isEditableRoute)
    }

    public func updatingIsEditableRoute(_ newValue: Bool) -> ActivitySummary {
        ActivitySummary(id: id, title: title, activityType: activityType, startDate: startDate, endDate: endDate, distance: distance, duration: duration, movingDuration: movingDuration, elevationGain: elevationGain, elevationLoss: elevationLoss, avgSpeed: avgSpeed, maxSpeed: maxSpeed, maxSlope: maxSlope, avgHeartRate: avgHeartRate, maxHeartRate: maxHeartRate, sourceFileName: sourceFileName, sourceFileFormat: sourceFileFormat, sourceApp: sourceApp, tags: tags, notes: notes, raidId: raidId, isCourse: isCourse, isPublished: isPublished, isStagedRoute: isStagedRoute, isEditableRoute: newValue)
    }
}
