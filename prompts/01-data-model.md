# P1 — Modèle de données Core Data + CloudKit

## Objectif

Mettre en place le modèle de données persistant de l'app. Toutes les métadonnées sont stockées dans Core Data avec sync CloudKit privé. Les fichiers GPX/FIT eux-mêmes restent dans le container iCloud (cf. P2).

## Pré-requis

- P0 terminé : container iCloud configuré, capabilities activées.

## Livrables attendus

### 1. Modèle Core Data (`GPXManagement.xcdatamodeld`)

Dans la cible app — Core Data + CloudKit nécessite `NSPersistentCloudKitContainer`.

#### Entité `Activity`

| Attribut | Type | Notes |
|---|---|---|
| `id` | UUID | Indexé, non-optional |
| `title` | String | Non-optional |
| `activityType` | String | Voir enum `ActivityType` ci-dessous |
| `startDate` | Date | Indexé |
| `endDate` | Date | |
| `sourceFileName` | String | Nom du fichier dans le container iCloud |
| `sourceFileFormat` | String | `gpx` ou `fit` |
| `origin` | String | `manual_import`, `strava` |
| `stravaId` | String? | Optional, indexé |
| `notes` | String? | |
| `tags` | [String] | Transformable (NSSecureUnarchiveFromData) |
| `distance` | Double | mètres |
| `duration` | Double | secondes (temps total) |
| `movingDuration` | Double | secondes (temps en mouvement) |
| `elevationGain` | Double | mètres |
| `elevationLoss` | Double | mètres |
| `avgSpeed` | Double | m/s |
| `maxSpeed` | Double | m/s |
| `avgHeartRate` | Double? | bpm |
| `maxHeartRate` | Double? | bpm |
| `minLatitude` | Double | bbox |
| `maxLatitude` | Double | bbox |
| `minLongitude` | Double | bbox |
| `maxLongitude` | Double | bbox |
| `trackData` | Data | **Blob compressé** des points (cf. ci-dessous) |
| `editedFromActivityId` | UUID? | Si trace dérivée |
| `createdAt` | Date | |
| `updatedAt` | Date | |

> **`trackData`** : tableau de points sérialisé en binaire compact (puis `zlib` compressé). Format proposé : header (count, flags indiquant la présence de HR/cadence/power) + tableau dense. Codec dans `GPXCore.TrackPointCodec`.

#### Entité `UserPreference` (singleton)

| Attribut | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `organizationPattern` | String | Pattern d'organisation iCloud (défaut : `{year}/{month}`) |
| `defaultMapLayer` | String | `ign_scan25`, `ign_planv2`, `ign_slopes`, `mapkit_standard`, `mapkit_satellite` |
| `unitsSystem` | String | `metric` (seul supporté v1) |

#### Entité `StravaAccount`

| Attribut | Type | Notes |
|---|---|---|
| `athleteId` | String | |
| `lastSyncDate` | Date? | |
| `lastFullSyncDate` | Date? | |

> Les tokens OAuth ne sont **pas** dans Core Data — ils vont dans le Keychain (cf. P8).

### 2. Enums Swift (dans `GPXCore`)

```swift
public enum ActivityType: String, Codable, CaseIterable {
    case cyclingRoad = "cycling.road"
    case cyclingMTB = "cycling.mtb"
    case cyclingGravel = "cycling.gravel"
    case motorcycle = "motorcycle"
    case walking = "walking"
    case hiking = "hiking"
    case skiingAlpine = "skiing.alpine"
    case skiingNordic = "skiing.nordic"
    case skiingTouring = "skiing.touring"
    case skiingFreeride = "skiing.freeride"
}
```

> Localisation des noms d'affichage dans `Localizable.strings` (français).

### 3. Persistence stack

Classe `PersistenceController` (style Apple template) avec :

- `NSPersistentCloudKitContainer` configuré sur le container CloudKit du P0.
- Mode preview en mémoire pour SwiftUI previews.
- Migration auto activée (`shouldMigrateStoreAutomatically = true`).

### 4. Codec `TrackPoint`

Dans `GPXCore` :

```swift
public struct TrackPoint {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let timestamp: Date?
    public let heartRate: Double?
    public let cadence: Double?
    public let power: Double?
}

public enum TrackPointCodec {
    public static func encode(_ points: [TrackPoint]) throws -> Data  // binaire + zlib
    public static func decode(_ data: Data) throws -> [TrackPoint]
}
```

### 5. Tests XCTest

- Round-trip encode/decode `TrackPoint` (1, 100, 50 000 points).
- Insertion / fetch d'une `Activity` en store en mémoire.
- Vérification que les attributs CloudKit-compatibles ne contiennent pas d'attributs non supportés (CloudKit rejette `Date` non-optional sans default, `String` non-optional sans default — fixer en conséquence).

## Hors scope

- Parsing GPX/FIT réel (P2).
- UI consommant le modèle (P3).
- Logique de classement (P2).

## Validation

- L'app compile.
- Tests `GPXCoreTests` au vert.
- Lancement de l'app sans erreur CloudKit (logs Xcode propres).
