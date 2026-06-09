import Foundation
import Photos
import AppKit
import AVFoundation
import CoreLocation
import GPXCore

// MARK: - Photos prises pendant la trace

public enum PhotoLibraryService {
    public static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    /// Photos de la photothèque prises dans la fenêtre temporelle ET géolocalisées à proximité du tracé.
    public static func photos(start: Date, end: Date, near coordinates: [CLLocationCoordinate2D], maxDistance: CLLocationDistance) -> [PHAsset] {
        guard start <= end, !coordinates.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@ AND (mediaType == %d OR mediaType == %d)",
            start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let samples = sampled(coordinates, max: 2000).map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let result = PHAsset.fetchAssets(with: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if let location = asset.location {
                if samples.contains(where: { $0.distance(from: location) <= maxDistance }) {
                    out.append(asset)
                }
            } else {
                // Média sans géolocalisation (fréquent pour les vidéos) : retenu sur le seul critère temporel.
                out.append(asset)
            }
        }
        return out
    }

    /// Coordonnée d'un média : sa géolocalisation si présente, sinon le point du tracé le plus proche dans le temps.
    public static func resolvedCoordinate(for asset: PHAsset, in points: [TrackPoint]) -> CLLocationCoordinate2D? {
        if let location = asset.location { return location.coordinate }
        guard let date = asset.creationDate else { return nil }
        var best: (delta: TimeInterval, coord: CLLocationCoordinate2D)?
        for p in points {
            guard let t = p.timestamp else { continue }
            let delta = abs(t.timeIntervalSince(date))
            if best == nil || delta < best!.delta {
                best = (delta, CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
            }
        }
        return best?.coord
    }

    /// Bascule le statut « favori » de la photo dans la photothèque. Renvoie true si appliqué.
    public static func setFavorite(_ asset: PHAsset, _ favorite: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = favorite
            } completionHandler: { success, _ in continuation.resume(returning: success) }
        }
    }

    /// Exporte la vidéo d'un PHAsset en mp4 (qualité moyenne) → Data, pour l'inclure dans l'export web.
    public static func exportVideo(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .mediumQualityFormat
            PHImageManager.default().requestExportSession(forVideo: asset, options: options, exportPreset: AVAssetExportPresetMediumQuality) { session, _ in
                guard let session else { continuation.resume(returning: nil); return }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                session.outputURL = tmp
                session.outputFileType = .mp4
                session.shouldOptimizeForNetworkUse = true
                session.exportAsynchronously {
                    if session.status == .completed, let data = try? Data(contentsOf: tmp) {
                        try? FileManager.default.removeItem(at: tmp)
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    public static func fullImage(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1280, height: 1280), contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Image haute définition (recadrage). Plafonnée pour rester raisonnable en mémoire.
    public static func editingImage(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 4096, height: 4096), contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Crée une nouvelle photo dans la photothèque (en conservant date et lieu de l'original). Renvoie son identifiant.
    public static func createImageAsset(jpeg: Data, creationDate: Date?, location: CLLocation?) async -> String? {
        var newID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpeg, options: nil)
                request.creationDate = creationDate
                request.location = location
                newID = request.placeholderForCreatedAsset?.localIdentifier
            }
            return newID
        } catch {
            return nil
        }
    }

    /// Crée une nouvelle vidéo dans la photothèque depuis un fichier (date/lieu conservés). Renvoie son identifiant.
    public static func createVideoAsset(fileURL: URL, creationDate: Date?, location: CLLocation?) async -> String? {
        var newID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: nil)
                request.creationDate = creationDate
                request.location = location
                newID = request.placeholderForCreatedAsset?.localIdentifier
            }
            return newID
        } catch {
            return nil
        }
    }

    /// Exporte un extrait recadré (trim + crop) d'une vidéo vers un fichier temporaire.
    /// `crop` est normalisé (0..1, origine haut-gauche) dans l'espace d'affichage orienté de la vidéo.
    public static func exportEditedVideo(asset: AVAsset, start: Double, end: Double, crop: CGRect, to outputURL: URL) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let pref = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = natural.applying(pref)
        let displaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard displaySize.width > 0, displaySize.height > 0 else { return false }

        let cropRect = CGRect(x: crop.minX * displaySize.width, y: crop.minY * displaySize.height,
                              width: crop.width * displaySize.width, height: crop.height * displaySize.height).integral
        guard cropRect.width >= 16, cropRect.height >= 16 else { return false }

        let composition = AVMutableVideoComposition()
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.renderSize = cropRect.size
        let instruction = AVMutableVideoCompositionInstruction()
        let duration = (try? await asset.load(.duration)) ?? .zero
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(pref.concatenating(CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return false }
        session.videoComposition = composition
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        try? FileManager.default.removeItem(at: outputURL)
        do { try await session.export(to: outputURL, as: .mp4); return true } catch { return false }
    }

    /// Supprime des assets (confirmation système requise pour la photothèque de l'utilisateur).
    public static func deleteAssets(_ localIdentifiers: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            return true
        } catch {
            return false
        }
    }

    public static func avAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                nonisolated(unsafe) let transferred = avAsset
                continuation.resume(returning: transferred)
            }
        }
    }

    public static func thumbnail(for asset: PHAsset, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Exporte l'original dans un fichier temporaire (réutilisé s'il existe) pour l'aperçu Quick Look in-app.
    public static func exportForPreview(_ asset: PHAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = resources.first(where: { $0.type == wanted }) ?? resources.first else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GPXPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(resource.originalFilename)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil ? url : nil)
            }
        }
    }

    private static func sampled(_ coords: [CLLocationCoordinate2D], max: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > max else { return coords }
        let step = Double(coords.count) / Double(max)
        return (0..<max).map { coords[Int(Double($0) * step)] }
    }
}
