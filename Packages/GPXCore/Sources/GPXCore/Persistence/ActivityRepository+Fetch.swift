import Foundation
import CoreData
import GPXCore

public struct SourceRecomputeEntry: Sendable {
    public let id: UUID
    public let relativePath: String
    public let format: SourceFileFormat
    public let origin: ActivityOrigin
    public let activityType: ActivityType
}

extension CoreDataActivityRepository {
    public func fetchAllSummaries() async throws -> [ActivitySummary] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            let results = try context.fetch(fetch)
            return results.compactMap(ActivitySummaryMapper.map)
        }
    }

    public func setIsCourse(id: UUID, isCourse: Bool) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(isCourse, forKey: "isCourse")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    /// Réconciliation unique de la catégorie depuis le tracé : parcours = des points GPS mais aucun
    /// horodatage (tracé dessiné). Une séance sans GPS (escalade, fitness… 0 point) reste une activité.
    /// Recalcule dans les deux sens. Renvoie le nombre de traces modifiées.
    @discardableResult
    public func reconcileCoursesFromTracks() async throws -> Int {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            let all = try context.fetch(fetch)
            var changed = 0
            for activity in all {
                var shouldBeCourse = false
                if let data = activity.value(forKey: "trackData") as? Data,
                   let info = TrackPointCodec.headerInfo(in: data) {
                    shouldBeCourse = info.pointCount > 0 && !info.hasTimestamps
                }
                let current = (activity.value(forKey: "isCourse") as? Bool) ?? false
                if current != shouldBeCourse {
                    activity.setValue(shouldBeCourse, forKey: "isCourse")
                    changed += 1
                }
            }
            if context.hasChanges { try context.save() }
            return changed
        }
    }

    public func deleteAllActivities() async throws -> Int {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            let all = try context.fetch(fetch)
            for object in all { context.delete(object) }
            if context.hasChanges { try context.save() }
            return all.count
        }
    }

    public func deleteActivity(id: UUID) async throws {
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
    public func latestStravaActivityDate() async throws -> Date? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "origin == %@", ActivityOrigin.strava.rawValue)
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "startDate") as? Date
        }
    }

    public func fetchTitle(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "title") as? String
        }
    }

    public func fetchMediaState(id: UUID) async throws -> Data? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "mediaState") as? Data
        }
    }

    public func updateMediaState(id: UUID, data: Data?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(data, forKey: "mediaState")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func fetchTrackData(id: UUID) async throws -> Data? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "trackData") as? Data
        }
    }

    public func updateTitle(id: UUID, title: String) async throws {
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

    public func updateSourceFileName(id: UUID, relativePath: String) async throws {
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

    public func updateActivityType(id: UUID, rawValue: String) async throws {
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
    public func touchAllActivitiesForResync(batchSize: Int = 100, onBatch: @MainActor @Sendable (Int, Int) -> Void) async throws -> Int {
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

    public func updateSourceApp(id: UUID, sourceApp: String?) async throws {
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
    public func fetchSourceRecomputeEntries() async throws -> [SourceRecomputeEntry] {
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

    public func fetchSourceRecomputeEntry(id: UUID) async throws -> SourceRecomputeEntry? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            guard let object = try context.fetch(fetch).first,
                  let path = object.value(forKey: "sourceFileName") as? String, !path.isEmpty,
                  let formatRaw = object.value(forKey: "sourceFileFormat") as? String,
                  let format = SourceFileFormat(rawValue: formatRaw) else { return nil }
            let origin = ActivityOrigin(rawValue: object.value(forKey: "origin") as? String ?? "") ?? .manualImport
            let type = ActivityType(rawValue: object.value(forKey: "activityType") as? String ?? "") ?? .other
            return SourceRecomputeEntry(id: id, relativePath: path, format: format, origin: origin, activityType: type)
        }
    }

    public func applyReprocess(id: UUID, result: ReprocessResult, newType: ActivityType?) async throws {
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
            activity.setValue(stats.maxSlope, forKey: "maxSlope")
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

    public func fetchVideoLayoutData(id: UUID) async throws -> Data? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "videoLayoutData") as? Data
        }
    }

    public func updateVideoLayoutData(id: UUID, data: Data?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(data, forKey: "videoLayoutData")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func fetchSegmentsData(id: UUID) async throws -> Data? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "segmentsData") as? Data
        }
    }

    public func updateSegmentsData(id: UUID, data: Data?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(data, forKey: "segmentsData")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func updateNotes(id: UUID, notes: String) async throws {
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

    public func fetchWebPublishedURL(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "webPublishedURL") as? String
        }
    }

    public func fetchWebPublishConfig(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "webPublishConfig") as? String
        }
    }

    public func setWebPublished(id: UUID, url: String, configJSON: String?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(url, forKey: "webPublishedURL")
                activity.setValue(configJSON, forKey: "webPublishConfig")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func clearWebPublished(id: UUID) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(nil, forKey: "webPublishedURL")
                activity.setValue(nil, forKey: "webPublishConfig")
                activity.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func fetchFilmPublishedURL(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "filmPublishedURL") as? String
        }
    }

    public func setFilmPublished(id: UUID, url: String) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let activity = try context.fetch(fetch).first {
                activity.setValue(url, forKey: "filmPublishedURL")
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
            maxSlope: object.value(forKey: "maxSlope") as? Double ?? 0,
            avgHeartRate: object.value(forKey: "avgHeartRate") as? Double,
            maxHeartRate: object.value(forKey: "maxHeartRate") as? Double,
            sourceFileName: object.value(forKey: "sourceFileName") as? String ?? "",
            sourceFileFormat: format,
            sourceApp: object.value(forKey: "sourceApp") as? String,
            tags: tags,
            notes: object.value(forKey: "notes") as? String,
            raidId: object.value(forKey: "raidId") as? UUID,
            isCourse: object.value(forKey: "isCourse") as? Bool ?? false
        )
    }
}

extension CoreDataActivityRepository {
    public func fetchRaids() async throws -> [Raid] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            return try context.fetch(fetch).compactMap(RaidMapper.map)
        }
    }

    public func createRaid(_ raid: Raid) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let object = NSEntityDescription.insertNewObject(forEntityName: "Raid", into: context)
            RaidMapper.apply(raid, to: object)
            try context.save()
        }
    }

    public func updateRaid(_ raid: Raid) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.predicate = NSPredicate(format: "id == %@", raid.id as CVarArg)
            fetch.fetchLimit = 1
            guard let object = try context.fetch(fetch).first else { return }
            RaidMapper.apply(raid, to: object)
            try context.save()
        }
    }

    public func deleteRaid(id: UUID) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let activities = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            activities.predicate = NSPredicate(format: "raidId == %@", id as CVarArg)
            let now = Date()
            for activity in try context.fetch(activities) {
                activity.setValue(nil, forKey: "raidId")
                activity.setValue(now, forKey: "updatedAt")
            }
            let raids = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            raids.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            raids.fetchLimit = 1
            if let object = try context.fetch(raids).first { context.delete(object) }
            if context.hasChanges { try context.save() }
        }
    }

    public func fetchRaidWebPublishedURL(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "webPublishedURL") as? String
        }
    }

    public func fetchRaidWebPublishConfig(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "webPublishConfig") as? String
        }
    }

    public func setRaidWebPublished(id: UUID, url: String, configJSON: String?) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let object = try context.fetch(fetch).first {
                object.setValue(url, forKey: "webPublishedURL")
                object.setValue(configJSON, forKey: "webPublishConfig")
                object.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func fetchRaidFilmPublishedURL(id: UUID) async throws -> String? {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            return try context.fetch(fetch).first?.value(forKey: "filmPublishedURL") as? String
        }
    }

    public func setRaidFilmPublished(id: UUID, url: String) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Raid")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let object = try context.fetch(fetch).first {
                object.setValue(url, forKey: "filmPublishedURL")
                object.setValue(Date(), forKey: "updatedAt")
                try context.save()
            }
        }
    }

    public func setRaid(activityIds: [UUID], raidId: UUID?) async throws {
        guard !activityIds.isEmpty else { return }
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Activity")
            fetch.predicate = NSPredicate(format: "id IN %@", activityIds)
            let now = Date()
            for activity in try context.fetch(fetch) {
                activity.setValue(raidId, forKey: "raidId")
                activity.setValue(now, forKey: "updatedAt")
            }
            if context.hasChanges { try context.save() }
        }
    }
}

extension CoreDataActivityRepository {
    public func fetchSmartFilters() async throws -> [SmartFilter] {
        let context = persistence.container.newBackgroundContext()
        return try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "SmartFilter")
            fetch.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(fetch).compactMap(SmartFilterMapper.map)
        }
    }

    public func createSmartFilter(_ filter: SmartFilter) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let object = NSEntityDescription.insertNewObject(forEntityName: "SmartFilter", into: context)
            SmartFilterMapper.apply(filter, to: object)
            try context.save()
        }
    }

    public func updateSmartFilter(_ filter: SmartFilter) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "SmartFilter")
            fetch.predicate = NSPredicate(format: "id == %@", filter.id as CVarArg)
            fetch.fetchLimit = 1
            guard let object = try context.fetch(fetch).first else { return }
            SmartFilterMapper.apply(filter, to: object)
            try context.save()
        }
    }

    public func deleteSmartFilter(id: UUID) async throws {
        let context = persistence.container.newBackgroundContext()
        try await context.perform {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "SmartFilter")
            fetch.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            fetch.fetchLimit = 1
            if let object = try context.fetch(fetch).first { context.delete(object) }
            if context.hasChanges { try context.save() }
        }
    }
}

enum SmartFilterMapper {
    static func map(_ object: NSManagedObject) -> SmartFilter? {
        guard let id = object.value(forKey: "id") as? UUID,
              let name = object.value(forKey: "name") as? String else { return nil }
        var rules: [SmartFilterRule] = []
        if let data = object.value(forKey: "rulesData") as? Data,
           let decoded = try? JSONDecoder().decode([SmartFilterRule].self, from: data) {
            rules = decoded
        }
        return SmartFilter(
            id: id,
            name: name,
            matchAll: (object.value(forKey: "matchAll") as? Bool) ?? true,
            rules: rules,
            createdAt: object.value(forKey: "createdAt") as? Date ?? Date(),
            updatedAt: object.value(forKey: "updatedAt") as? Date ?? Date()
        )
    }

    static func apply(_ filter: SmartFilter, to object: NSManagedObject) {
        object.setValue(filter.id, forKey: "id")
        object.setValue(filter.name, forKey: "name")
        object.setValue(filter.matchAll, forKey: "matchAll")
        object.setValue(try? JSONEncoder().encode(filter.rules), forKey: "rulesData")
        object.setValue(filter.createdAt, forKey: "createdAt")
        object.setValue(filter.updatedAt, forKey: "updatedAt")
    }
}

enum RaidMapper {
    static func map(_ object: NSManagedObject) -> Raid? {
        guard let id = object.value(forKey: "id") as? UUID,
              let name = object.value(forKey: "name") as? String
        else { return nil }
        var participants: [RaidParticipant] = []
        if let data = object.value(forKey: "participantsData") as? Data,
           let decoded = try? JSONDecoder().decode([RaidParticipant].self, from: data) {
            participants = decoded
        }
        return Raid(
            id: id,
            name: name,
            subtitle: object.value(forKey: "subtitle") as? String,
            place: object.value(forKey: "place") as? String,
            notes: object.value(forKey: "notes") as? String,
            startDate: object.value(forKey: "startDate") as? Date,
            endDate: object.value(forKey: "endDate") as? Date,
            coverImageData: object.value(forKey: "coverImageData") as? Data,
            participants: participants,
            createdAt: object.value(forKey: "createdAt") as? Date ?? Date(),
            updatedAt: object.value(forKey: "updatedAt") as? Date ?? Date()
        )
    }

    static func apply(_ raid: Raid, to object: NSManagedObject) {
        object.setValue(raid.id, forKey: "id")
        object.setValue(raid.name, forKey: "name")
        object.setValue(raid.subtitle, forKey: "subtitle")
        object.setValue(raid.place, forKey: "place")
        object.setValue(raid.notes, forKey: "notes")
        object.setValue(raid.startDate, forKey: "startDate")
        object.setValue(raid.endDate, forKey: "endDate")
        object.setValue(raid.coverImageData, forKey: "coverImageData")
        object.setValue(try? JSONEncoder().encode(raid.participants), forKey: "participantsData")
        object.setValue(raid.createdAt, forKey: "createdAt")
        object.setValue(raid.updatedAt, forKey: "updatedAt")
    }
}
