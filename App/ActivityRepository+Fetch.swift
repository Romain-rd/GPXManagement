import Foundation
import CoreData
import GPXCore

struct SourceRecomputeEntry: Sendable {
    let id: UUID
    let relativePath: String
    let format: SourceFileFormat
    let origin: ActivityOrigin
    let activityType: ActivityType
}

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

    func deleteAllActivities() async throws -> Int {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            let all = try context.fetch(fetch)
            for object in all { context.delete(object) }
            if context.hasChanges { try context.save() }
            return all.count
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

    /// Date de départ la plus récente parmi les activités importées depuis Strava (curseur de sync).
    func latestStravaActivityDate() async throws -> Date? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "origin == %@", ActivityOrigin.strava.rawValue)
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "startDate") as? Date
        }
    }

    func fetchTrackData(id: UUID) async throws -> Data? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "trackData") as? Data
        }
    }

    func updateTitle(id: UUID, title: String) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(title, forKey: "title")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    func updateSourceFileName(id: UUID, relativePath: String) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(relativePath, forKey: "sourceFileName")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    func updateActivityType(id: UUID, rawValue: String) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(rawValue, forKey: "activityType")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    /// Touche `updatedAt` sur chaque Activity par lots — sert à forcer NSPersistentCloudKitContainer
    /// à republier tous les enregistrements (ex. machine où le mirroring n'a jamais poussé l'historique).
    func touchAllActivitiesForResync(batchSize: Int = 100, onBatch: @MainActor @Sendable (Int, Int) -> Void) async throws -> Int {
        let context = persistence.container.newBackgroundContext()
        let total: Int = try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            return try context.count(for: fetch)
        }
        guard total > 0 else { return 0 }

        var processed = 0
        while processed < total {
            let offset = processed
            let limit = min(batchSize, total - offset)
            try await context.perform {
                let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
                fetch.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                fetch.fetchOffset = offset
                fetch.fetchLimit = limit
                let rows = try context.fetch(fetch)
                let now = Date()
                for row in rows {
                    row.setValue(now, forKey: "updatedAt")
                }
                if context.hasChanges { try context.save() }
                context.reset()
            }
            processed += limit
            let snapshot = processed
            await MainActor.run { onBatch(snapshot, total) }
        }
        return total
    }

    func updateSourceApp(id: UUID, sourceApp: String?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(sourceApp, forKey: "sourceApp")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    /// Données minimales nécessaires pour recalculer l'application source en relisant les fichiers stockés.
    func fetchSourceRecomputeEntries() async throws -> [SourceRecomputeEntry] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            let results = try context.fetch(fetch)
            return results.compactMap { object -> SourceRecomputeEntry? in
                guard let id = object.value(forKey: "id") as? UUID,
                      let path = object.value(forKey: "sourceFileName") as? String, !path.isEmpty,
                      let formatRaw = object.value(forKey: "sourceFileFormat") as? String,
                      let format = SourceFileFormat(rawValue: formatRaw)
                else { return nil }
                let originRaw = object.value(forKey: "origin") as? String ?? ActivityOrigin.manualImport.rawValue
                let origin = ActivityOrigin(rawValue: originRaw) ?? .manualImport
                let typeRaw = object.value(forKey: "activityType") as? String ?? ActivityType.other.rawValue
                let type = ActivityType(rawValue: typeRaw) ?? .other
                return SourceRecomputeEntry(id: id, relativePath: path, format: format, origin: origin, activityType: type)
            }
        }
    }

    func applyReprocess(id: UUID, result: ReprocessResult, newType: ActivityType?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            guard let activity = try context.fetch(fetch).first else { return }
            let stats = result.stats
            activity.setValue(result.startDate, forKey: "startDate")
            activity.setValue(result.endDate, forKey: "endDate")
            activity.setValue(stats.distance, forKey: "distance")
            activity.setValue(stats.duration, forKey: "duration")
            activity.setValue(stats.movingDuration, forKey: "movingDuration")
            activity.setValue(stats.elevationGain, forKey: "elevationGain")
            activity.setValue(stats.elevationLoss, forKey: "elevationLoss")
            activity.setValue(stats.avgSpeed, forKey: "avgSpeed")
            activity.setValue(stats.maxSpeed, forKey: "maxSpeed")
            activity.setValue(stats.avgHeartRate, forKey: "avgHeartRate")
            activity.setValue(stats.maxHeartRate, forKey: "maxHeartRate")
            activity.setValue(stats.boundingBox.minLatitude, forKey: "minLatitude")
            activity.setValue(stats.boundingBox.maxLatitude, forKey: "maxLatitude")
            activity.setValue(stats.boundingBox.minLongitude, forKey: "minLongitude")
            activity.setValue(stats.boundingBox.maxLongitude, forKey: "maxLongitude")
            activity.setValue(result.trackData, forKey: "trackData")
            activity.setValue(result.sourceApp, forKey: "sourceApp")
            if let newType { activity.setValue(newType.rawValue, forKey: "activityType") }
            activity.setValue(Date(), forKey: "updatedAt")
            try context.save()
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
            sourceApp: object.value(forKey: "sourceApp") as? String,
            tags: tags,
            notes: object.value(forKey: "notes") as? String
        )
    }
}
