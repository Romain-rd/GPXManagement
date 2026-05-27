# P0 — Bootstrap du projet

## Objectif

Mettre en place le squelette Xcode de GPXManagement : projet, structure de Swift Packages, signature Developer ID, container iCloud, capabilities, prêt à recevoir le code des phases suivantes.

## Pré-requis (à fournir par l'utilisateur)

- Compte Apple Developer actif, Team ID.
- Bundle ID retenu (proposition : `com.demoustier.GPXManagement`).
- Identifiant container iCloud (proposition : `iCloud.com.demoustier.GPXManagement`).

## Livrables attendus

1. Projet Xcode `GPXManagement.xcodeproj` à la racine du dépôt.
2. Cible app macOS SwiftUI, **macOS 15.0** minimum deployment target.
3. Trois Swift Packages locaux dans `Packages/` :
   - `GPXCore` — modèle, parsing, services métier (pas de dépendance UI).
   - `GPXMapKit` — abstractions cartographiques.
   - `GPXStrava` — client Strava.
4. Capabilities activées dans la cible app :
   - **iCloud** : iCloud Documents (container `iCloud.com.demoustier.GPXManagement`) + CloudKit (même container).
   - **App Sandbox** : User-Selected File (Read/Write), Network Client (pour Strava + IGN).
5. `Info.plist` de l'app avec :
   - `NSUbiquitousContainers` pour exposer le container iCloud dans Finder (clé `NSUbiquitousContainerName` = "GPXManagement").
   - `CFBundleDocumentTypes` pour `.gpx` et `.fit` (l'app peut ouvrir ces fichiers).
6. Configuration de signature Developer ID (pas App Store).
7. `.gitignore` standard Xcode + exclusion `Secrets.xcconfig`, `xcuserdata`, `DerivedData`.
8. Un fichier `Secrets.xcconfig.example` documentant les clés attendues (`IGN_API_KEY`, `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`).
9. App qui compile et lance une fenêtre vide "GPXManagement" — rien d'autre.

## Hors scope de cette phase

- Modèle Core Data (P1).
- Toute UI réelle au-delà d'une `Text("GPXManagement")` provisoire.
- Notarisation et DMG (P11).

## Tests attendus

- Schema de test vide mais fonctionnel pour chaque Swift Package.
- L'app build et run sans erreur.

## Validation

L'utilisateur :

- ouvre le projet dans Xcode,
- vérifie que la cible signe en Developer ID,
- lance l'app (fenêtre vide),
- vérifie qu'un dossier `GPXManagement` apparaît dans iCloud Drive après premier lancement.
