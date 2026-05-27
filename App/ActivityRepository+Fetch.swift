import Foundation
import CoreData
import GPXCore

extension CoreDataActivityRepository {
    func fetchAllSummaries() async throws -> [ActivitySummary] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            let results = try context.fetch(fetch)
            return results.compactMap(ActivitySummaryMapper.map)
        }
    }

    func deleteActivity(id: UUID) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                context.delete(activity)
                try context.save()
            }
        }
    }

    func updateNotes(id: UUID, notes: String) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(notes, forKey: "notes")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }
}

enum ActivitySummaryMapper {
    static func map(_ object: NSManagedObject) -> ActivitySummary? {
        guard
            let id = object.value(forKey: "id") as? UUID,
            let title = object.value(forKey: "title") as? String,
            let typeRaw = object.value(forKey: "activityType") as? String,
            let type = ActivityType(rawValue: typeRaw),
            let startDate = object.value(forKey: "startDate") as? Date,
            let endDate = object.value(forKey: "endDate") as? Date,
            let formatRaw = object.value(forKey: "sourceFileFormat") as? String,
            let format = SourceFileFormat(rawValue: formatRaw)
        else { return nil }

        let tags = (object.value(forKey: "tags") as? [String]) ?? []
        return ActivitySummary(
            id: id,
            title: title,
            activityType: type,
            startDate: startDate,
            endDate: endDate,
            distance: object.value(forKey: "distance") as? Double ?? 0,
            duration: object.value(forKey: "duration") as? Double ?? 0,
            movingDuration: object.value(forKey: "movingDuration") as? Double ?? 0,
            elevationGain: object.value(forKey: "elevationGain") as? Double ?? 0,
            elevationLoss: object.value(forKey: "elevationLoss") as? Double ?? 0,
            avgSpeed: object.value(forKey: "avgSpeed") as? Double ?? 0,
            maxSpeed: object.value(forKey: "maxSpeed") as? Double ?? 0,
            avgHeartRate: object.value(forKey: "avgHeartRate") as? Double,
            maxHeartRate: object.value(forKey: "maxHeartRate") as? Double,
            sourceFileName: object.value(forKey: "sourceFileName") as? String ?? "",
            sourceFileFormat: format,
            tags: tags,
            notes: object.value(forKey: "notes") as? String
        )
    }
}
