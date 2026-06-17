import Foundation
import GPXCore

/// État non-UI du détail de raid : liens publiés (web/film).
@MainActor
@Observable
final class RaidDetailViewModel {
    private let repository: CoreDataActivityRepository

    var publishedURL: String?
    var filmPublishedURL: String?
    var publishConfigJSON: String?

    init(repository: CoreDataActivityRepository) {
        self.repository = repository
    }

    func loadPublishState(raidId: UUID) async {
        publishedURL = try? await repository.fetchRaidWebPublishedURL(id: raidId)
        publishConfigJSON = try? await repository.fetchRaidWebPublishConfig(id: raidId)
        filmPublishedURL = try? await repository.fetchRaidFilmPublishedURL(id: raidId)
    }

    /// UUID du dossier déjà publié (extrait du lien stocké) pour republier au même endroit.
    func existingPublishUUID() -> String? {
        guard let s = publishedURL, let comps = URLComponents(string: s) else { return nil }
        return comps.path.split(separator: "/").map(String.init).last
    }
}
