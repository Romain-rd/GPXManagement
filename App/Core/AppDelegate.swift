import AppKit
import CloudKit
import GPXCore

/// Délégué applicatif : prend en charge l'acceptation des invitations de partage CloudKit (CKShare).
/// Quand l'utilisateur ouvre un lien de parcours partagé, macOS appelle cette méthode ; on accepte
/// l'invitation dans le store partagé, et le parcours (étapes incluses) apparaît dans la bibliothèque.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        let persistence = AppServices.shared.persistence
        guard let store = persistence.sharedStore else {
            NSLog("GPXManagement: store partagé indisponible, invitation non acceptée")
            return
        }
        persistence.container.acceptShareInvitations(from: [metadata], into: store) { _, error in
            if let error {
                NSLog("GPXManagement: acceptShareInvitations a échoué: \(error)")
                return
            }
            Task { @MainActor in AppServices.shared.libraryRevision += 1 }
        }
    }
}
