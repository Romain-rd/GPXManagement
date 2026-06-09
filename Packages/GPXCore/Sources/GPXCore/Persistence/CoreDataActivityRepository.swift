import Foundation
import CoreData
import GPXCore

public final class CoreDataActivityRepository: ActivityRepository, @unchecked Sendable {
    public let persistence: PersistenceController

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    public func findActivity(stravaId: String) async throws -> UUID? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "stravaId == %@", stravaId)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "id") as? UUID
        }
    }

    public func findDuplicate(sha256: String, startDate: Date, distance: Double) async throws -> UUID? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            let lo = startDate.addingTimeInterval(-2)
            let hi = startDate.addingTimeInterval(2)
            let minD = distance * 0.99
            let maxD = distance * 1.01
            fetch.predicate = NSPredicate(
                format: "startDate >= %@ AND startDate <= %@ AND distance >= %f AND distance <= %f",
                lo as NSDate, hi as NSDate, minD, maxD
            )
            fetch.fetchLimit = 1
            let results = try context.fetch(fetch)
            return results.first?.value(forKey: "id") as? UUID
        }
    }

    public func createActivity(_ payload: ActivityCreationPayload) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let activity = NSEntityDescription.insertNewObject(forEntityName: "Activity", into: context)
            activity.setValue(payload.id, forKey: "id")
            activity.setValue(payload.title, forKey: "title")
            activity.setValue(payload.activityType.rawValue, forKey: "activityType")
            activity.setValue(payload.origin.rawValue, forKey: "origin")
            activity.setValue(payload.stravaId, forKey: "stravaId")
            activity.setValue(payload.sourceFileName, forKey: "sourceFileName")
            activity.setValue(payload.sourceFileFormat.rawValue, forKey: "sourceFileFormat")
            activity.setValue(payload.sourceApp, forKey: "sourceApp")
            activity.setValue(payload.startDate, forKey: "startDate")
            activity.setValue(payload.endDate, forKey: "endDate")
            activity.setValue(payload.stats.distance, forKey: "distance")
            activity.setValue(payload.stats.duration, forKey: "duration")
            activity.setValue(payload.stats.movingDuration, forKey: "movingDuration")
            activity.setValue(payload.stats.elevationGain, forKey: "elevationGain")
            activity.setValue(payload.stats.elevationLoss, forKey: "elevationLoss")
            activity.setValue(payload.stats.avgSpeed, forKey: "avgSpeed")
            activity.setValue(payload.stats.maxSpeed, forKey: "maxSpeed")
            activity.setValue(payload.stats.maxSlope, forKey: "maxSlope")
            activity.setValue(payload.stats.avgHeartRate, forKey: "avgHeartRate")
            activity.setValue(payload.stats.maxHeartRate, forKey: "maxHeartRate")
            activity.setValue(payload.stats.boundingBox.minLatitude, forKey: "minLatitude")
            activity.setValue(payload.stats.boundingBox.maxLatitude, forKey: "maxLatitude")
            activity.setValue(payload.stats.boundingBox.minLongitude, forKey: "minLongitude")
            activity.setValue(payload.stats.boundingBox.maxLongitude, forKey: "maxLongitude")
            activity.setValue(payload.trackData, forKey: "trackData")
            let now = Date()
            activity.setValue(now, forKey: "createdAt")
            activity.setValue(now, forKey: "updatedAt")
            try context.save()
        }
    }
}
