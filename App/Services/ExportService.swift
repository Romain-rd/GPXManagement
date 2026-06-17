import Foundation
import AppKit
import GPXCore

enum ExportError: Error, LocalizedError {
    case noTrackData
    case userCancelled
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noTrackData:    return "Aucune donnée de trace pour cette activité."
        case .userCancelled:  return nil
        case .writeFailed:    return "Échec de l'écriture du fichier."
        }
    }
}

@MainActor
enum ExportService {
    static func exportGPX(activity: ActivitySummary, repository: CoreDataActivityRepository) async throws -> URL {
        guard let trackData = try await repository.fetchTrackData(id: activity.id), !trackData.isEmpty else {
            throw ExportError.noTrackData
        }
        let points = try TrackPointCodec.decode(trackData)
        let gpxData = try GPXWriter.write(name: activity.title, activityType: activity.activityType, points: points)

        let panel = NSSavePanel()
        panel.title = "Exporter en GPX"
        panel.nameFieldStringValue = "\(activity.title.replacingOccurrences(of: "/", with: "-")).gpx"
        panel.allowedContentTypes = [.init(filenameExtension: "gpx") ?? .xml]
        guard panel.runModal() == .OK, let target = panel.url else {
            throw ExportError.userCancelled
        }
        do {
            try gpxData.write(to: target, options: .atomic)
            return target
        } catch {
            throw ExportError.writeFailed
        }
    }

    static func prepareShareGPX(activity: ActivitySummary, repository: CoreDataActivityRepository) async throws -> URL {
        guard let trackData = try await repository.fetchTrackData(id: activity.id), !trackData.isEmpty else {
            throw ExportError.noTrackData
        }
        let points = try TrackPointCodec.decode(trackData)
        let gpxData = try GPXWriter.write(name: activity.title, activityType: activity.activityType, points: points)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(activity.title.replacingOccurrences(of: "/", with: "-")).gpx")
        do {
            try gpxData.write(to: tmp, options: .atomic)
            return tmp
        } catch {
            throw ExportError.writeFailed
        }
    }
}
