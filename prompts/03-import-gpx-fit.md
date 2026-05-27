# P3 — Import GPX et FIT

## Objectif

Permettre l'import de fichiers `.gpx` et `.fit` via glisser-déposer. Parsing → détection auto du type d'activité → dialogue de confirmation utilisateur → stockage dans iCloud + insertion Core Data + calcul des stats.

## Pré-requis

- P1 : modèle Core Data, `TrackPointCodec`, enum `ActivityType`.
- P2 : `FileStorageService`, `OrganizationPattern`.

## Livrables attendus

### 1. Parser GPX (`GPXCore.GPXParser`)

```swift
public struct GPXParser {
    public func parse(data: Data) throws -> ParsedTrack
    public func parse(url: URL) throws -> ParsedTrack
}

public struct ParsedTrack {
    public let name: String?
    public let activityHint: String?     // depuis <type> GPX
    public let startDate: Date?
    public let endDate: Date?
    public let points: [TrackPoint]
}
```

- Implémentation via `XMLParser` natif (pas de dépendance externe).
- Supporte GPX 1.0 et 1.1.
- Extensions Garmin TrackPointExtension (HR, cadence, power, atemp) — lus si présents.
- Robuste aux fichiers malformés : erreurs typées (`GPXParseError`).

### 2. Parser FIT (`GPXCore.FITParser`)

Même interface que GPX :

```swift
public struct FITParser {
    public func parse(data: Data) throws -> ParsedTrack
    public func parse(url: URL) throws -> ParsedTrack
}
```

- Décision technique : utiliser une lib Swift open-source (`FitFileParser` ou équivalent) **vendored** (intégrée comme Swift Package local). À documenter dans la réponse à l'utilisateur avant intégration.
- Lit le champ `sport` et `sub_sport` du FIT pour le hint d'activité.
- Lit les enregistrements `record` pour les points.

### 3. Détecteur d'activité (`GPXCore.ActivityTypeDetector`)

```swift
public enum ActivityTypeDetector {
    public static func detect(hint: String?, fileFormat: String) -> ActivityType?
}
```

- Mapping des valeurs courantes :
  - GPX `<type>` : `cycling`, `Ride` → `cyclingRoad` ; `MountainBiking` → `cyclingMTB` ; `Hike`, `Hiking` → `hiking` ; `Walking` → `walking` ; `Skiing`, `AlpineSki` → `skiingAlpine` ; `BackcountrySki`, `ski_touring` → `skiingTouring` ; `Motorcycling` → `motorcycle`.
  - FIT `sport` : `cycling`, `running`, `walking`, `hiking`, `alpine_skiing`, `cross_country_skiing`, `motorcycling`, ...
- Retourne `nil` si non reconnu → l'UI tombe sur "à choisir".

### 4. Calculateur de stats (`GPXCore.ActivityStatsCalculator`)

```swift
public enum ActivityStatsCalculator {
    public static func compute(points: [TrackPoint]) -> ActivityStats
}

public struct ActivityStats {
    public let distance: Double            // m
    public let duration: Double            // s
    public let movingDuration: Double      // s (seuil vitesse > 0.5 m/s)
    public let elevationGain: Double       // m, lissé (filtre sur seuil 3m)
    public let elevationLoss: Double       // m
    public let avgSpeed: Double            // m/s
    public let maxSpeed: Double            // m/s (lissé sur fenêtre 5s)
    public let avgHeartRate: Double?
    public let maxHeartRate: Double?
    public let boundingBox: BoundingBox
}
```

- Distance : Haversine entre points consécutifs.
- Dénivelé : appliquer un filtre passe-bas avant cumul (sinon bruit GPS → d+ surévalué de 30-50 %). Seuil minimal de variation : 3 m.
- Vitesse max : moyenne glissante 5 s pour éliminer les pics aberrants.

### 5. Service d'import (`GPXCore.ImportService`)

```swift
public actor ImportService {
    public init(storage: FileStorageService, persistence: PersistenceController)
    public func prepareImport(from url: URL) async throws -> ImportProposal
    public func confirmImport(_ proposal: ImportProposal, activityType: ActivityType, title: String) async throws -> UUID
}

public struct ImportProposal {
    public let sourceURL: URL
    public let parsed: ParsedTrack
    public let stats: ActivityStats
    public let suggestedActivityType: ActivityType?
    public let suggestedTitle: String     // depuis <name> GPX ou nom de fichier
    public let duplicateOfActivityId: UUID?  // si déjà importé
}
```

- `prepareImport` :
  - Parse (GPX ou FIT selon extension).
  - Détecte le type.
  - Calcule les stats.
  - Cherche les doublons : hash SHA-256 du fichier source + check (startDate, distance) à ±2s / ±1%.
- `confirmImport` :
  - Crée l'`Activity` Core Data.
  - Stocke le fichier via `FileStorageService`.
  - Encode et stocke `trackData`.

### 6. UI minimale d'import (dans l'app macOS)

- **Drop zone** : toute la fenêtre principale (ou la liste centrale) accepte les drops `.fileURL`.
- À chaque fichier droppé : appel `prepareImport` → ouverture d'un **sheet de confirmation** :
  - Titre éditable (préfilled depuis `suggestedTitle`).
  - Type d'activité : Picker préfillé sur `suggestedActivityType` (ou "à choisir" si nil).
  - Récap : date, distance, d+, durée.
  - Avertissement doublon si présent + bouton "Importer quand même" ou "Annuler".
  - Bouton "Importer" → `confirmImport`.
- Import multiple : sheet montre tous les fichiers en liste, possibilité d'appliquer un type d'activité en masse.

### 7. Tests XCTest

- Parsing GPX d'échantillons (fichiers de test dans `Tests/Resources/`).
- Parsing FIT d'échantillons.
- Détection de type pour les hints les plus courants (Strava, Garmin, Komoot).
- Calcul de stats sur trace synthétique de référence (valeurs connues).
- Détection de doublon : même fichier importé 2x → `duplicateOfActivityId` rempli.

## Hors scope

- Surveillance auto d'un dossier (non retenu).
- Strava (P8).

## Validation

- Drop d'un GPX manuel → sheet de confirmation → trace visible dans Core Data (via debug log en attendant la liste UI P5).
- Drop d'un FIT idem.
- Drop d'un fichier malformé → message d'erreur clair, pas de crash.
