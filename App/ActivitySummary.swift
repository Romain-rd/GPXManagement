import Foundation
import GPXCore

struct ActivitySummary: Identifiable, Sendable, Hashable {
    let id: UUID
    let title: String
    let activityType: ActivityType
    let startDate: Date
    let endDate: Date
    let distance: Double
    let duration: Double
    let movingDuration: Double
    let elevationGain: Double
    let elevationLoss: Double
    let avgSpeed: Double
    let maxSpeed: Double
    let avgHeartRate: Double?
    let maxHeartRate: Double?
    let sourceFileName: String
    let sourceFileFormat: SourceFileFormat
    let tags: [String]
    let notes: String?
}
