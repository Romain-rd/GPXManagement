# P8 (planning) / 04 (numérotation) — Synchronisation Strava

## Objectif

Importer **l'historique complet** des activités Strava de l'utilisateur dans GPXManagement, puis effectuer des syncs incrémentales à la demande (et optionnellement en arrière-plan).

## Pré-requis

- P1 modèle Core Data (`StravaAccount`, `Activity.stravaId`, `Activity.origin = "strava"`).
- P3 service d'import : on réutilise `ImportService` pour les fichiers GPX issus de Strava.
- Application Strava créée sur `https://www.strava.com/settings/api` : `client_id`, `client_secret`, URI de redirection (`gpxmanagement://oauth/strava/callback`).
  - **Provisionnée le 2026-05-28** : `client_id = 252149` (non secret, peut figurer dans le code). `client_secret` → `Secrets.xcconfig` uniquement, jamais commité.

## Livrables attendus (dans `GPXStrava`)

### 1. Client OAuth 2.0 (PKCE)

```swift
public actor StravaOAuthClient {
    public init(clientId: String, redirectURI: URL)
    public func authorizationURL(scopes: [String]) -> URL
    public func exchangeCode(_ code: String, verifier: String) async throws -> StravaTokens
    public func refresh(_ tokens: StravaTokens) async throws -> StravaTokens
}

public struct StravaTokens: Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let athleteId: String
}
```

- PKCE obligatoire (Strava ne fournit pas le `client_secret` côté app native — utiliser code_verifier/code_challenge).
- Stockage des tokens : **Keychain**, jamais Core Data, jamais UserDefaults.

### 2. URL scheme handler

- Déclarer `gpxmanagement://` dans `Info.plist` (`CFBundleURLTypes`).
- Côté app : `onOpenURL` SwiftUI ou `NSApp.delegate.application(_:open:)`.
- Handler récupère `code` + `state` → appelle `exchangeCode` → stocke tokens.

### 3. Client API Strava

```swift
public actor StravaAPIClient {
    public init(tokenProvider: @escaping () async throws -> StravaTokens)
    public func listActivities(after: Date?, page: Int, perPage: Int) async throws -> [StravaActivitySummary]
    public func downloadGPX(activityId: String) async throws -> Data
}

public struct StravaActivitySummary {
    public let id: String
    public let name: String
    public let startDate: Date
    public let sportType: String
    public let distance: Double
}
```

- Gestion des rate limits Strava — back-off automatique, pause si `429`, reprise. Détail des quotas (compte gratuit, défaut imposé à toute nouvelle app, confirmé 2026-05-28) :
  - **Lecture** (GET) : 100 req / 15 min · 1 000 / jour.
  - **Globales** (toutes requêtes) : 200 req / 15 min · 2 000 / jour.
  - Lire les en-têtes renvoyés à chaque réponse : `X-RateLimit-Limit` et `X-RateLimit-Usage` (deux valeurs : 15 min, jour) → piloter le back-off dessus plutôt qu'en dur.
  - Minimiser les appels : `perPage = 200`, sync incrémentale via `after`, et **ne jamais re-télécharger** une activité déjà présente (check `stravaId`).
- Refresh automatique du token si expiré (le `tokenProvider` doit gérer le refresh).
- Download GPX : Strava expose `/activities/{id}/export_gpx` (avec cookies) — alternative : utiliser `/activities/{id}/streams` (API officielle, JSON, scope `activity:read_all`) puis reconstruire un GPX en interne. **Choix retenu** : utiliser les streams (officiel et stable).

### 4. Service de synchronisation

```swift
public actor StravaSyncService {
    public init(api: StravaAPIClient, importService: ImportService, persistence: PersistenceController)
    public func fullHistorySync(progress: @escaping (SyncProgress) -> Void) async throws
    public func incrementalSync(progress: @escaping (SyncProgress) -> Void) async throws -> Int  // nb d'activités importées
}

public struct SyncProgress {
    public let phase: String          // "listing", "downloading", "importing"
    public let current: Int
    public let total: Int
}
```

- `fullHistorySync` :
  - Liste toutes les activités page par page (perPage 200, jusqu'à liste vide).
  - Pour chaque activité non déjà importée (check via `stravaId`) :
    - Télécharge les streams.
    - Reconstruit un GPX temporaire.
    - Passe par `ImportService.prepareImport` puis `confirmImport` avec `origin = "strava"` et `stravaId` renseigné.
  - Met à jour `StravaAccount.lastFullSyncDate`.
- `incrementalSync` :
  - Liste activités `after: lastSyncDate`.
  - Même pipeline.
- Reprise sur erreur : si la sync est interrompue, la reprise repart de la dernière activité importée (pas du début).

### 5. UI Strava (dans l'app macOS)

- Item "Strava" dans la sidebar.
- Si non connecté : bouton "Se connecter à Strava" → ouvre `authorizationURL` dans Safari.
- Si connecté : affiche athleteId, lastSyncDate, bouton "Synchroniser maintenant" + progress bar lors du sync.
- Option (toggle) : "Synchronisation automatique au démarrage" — sync incrémentale lancée en background lors de l'ouverture.

### 6. Tests XCTest

- Mock client OAuth + API (pas d'appel réseau réel en tests).
- Sync full sur un set d'activités mockées (10, 100) : vérifier ordre, dédoublonnage, reprise.
- Reconstruction GPX depuis streams Strava (échantillon JSON dans `Tests/Resources/strava_streams_sample.json`).

## Sécurité

- `client_secret` jamais commité — chargé depuis `Secrets.xcconfig`.
- Tokens en Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, **pas** synchronisé iCloud).
- Le scope demandé est `activity:read_all` uniquement — pas d'écriture sur Strava.

## Hors scope

- Webhooks Strava temps réel.
- Publication d'activités vers Strava.
- **Augmentation des limites / du nombre d'athlètes** : l'app reste en *Single Player Mode* (1 athlète = Romain). C'est volontaire — usage perso mono-utilisateur. Les quotas par défaut suffisent largement (1 000 lectures/jour couvre même un backfill complet en quelques jours). Ne pas remplir le Developer Program form : réservé aux apps publiques en croissance, délai réel 7+ semaines en 2026, et une app perso ne serait pas approuvée.

## Validation

- L'utilisateur connecte son compte Strava, lance une sync full → toutes ses activités apparaissent en local.
- Une seconde sync incrémentale n'importe rien (pas de doublon).
