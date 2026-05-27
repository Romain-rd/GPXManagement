# P2 — Stockage iCloud des fichiers GPX/FIT

## Objectif

Gérer le stockage physique des fichiers GPX/FIT dans le container iCloud de l'app, avec un système d'organisation par **pattern configurable** (style Lightroom).

## Pré-requis

- P0 : container iCloud déclaré, capabilities activées.
- P1 : modèle Core Data avec `Activity.sourceFileName`.

## Concept central : "Pattern d'organisation"

L'utilisateur définit un template décrivant la structure d'arborescence. Variables disponibles :

- `{year}` — année 4 chiffres (de `startDate`)
- `{month}` — mois 2 chiffres
- `{day}` — jour 2 chiffres
- `{activity}` — nom court d'activité (`velo`, `moto`, `marche`, `rando`, `ski`, `ski-rando`)
- `{subactivity}` — sous-activité (`route`, `vtt`, `gravel`, `alpin`, `nordique`, `freerando`...)
- `{title}` — titre slugifié (`col-d-eze`)
- `{ext}` — extension (`gpx` / `fit`)

Pattern par défaut : `{year}/{month}/{year}-{month}-{day}_{activity}_{title}.{ext}`

Patterns prédéfinis proposés à l'utilisateur dans les préférences :

1. `{year}/{month}/...` (défaut — chronologique)
2. `{activity}/{year}/{month}/...` (par activité d'abord)
3. `{year}/{activity}/...` (année puis activité)
4. Personnalisé (libre)

## Livrables attendus (dans `GPXCore`)

### 1. `iCloudContainer` service

```swift
public actor ICloudContainer {
    public init(identifier: String)
    public func rootURL() throws -> URL          // URL du container Documents iCloud de l'app
    public func ensureAvailable() async throws   // attend que iCloud soit prêt
    public func relativeURL(for relativePath: String) throws -> URL
}
```

Gestion :
- Récupération via `FileManager.url(forUbiquityContainerIdentifier:)`.
- Attente de disponibilité (peut être `nil` au lancement).
- Erreur typée `ICloudError` (notSignedIn, notAvailable, ...).

### 2. `OrganizationPattern` engine

```swift
public struct OrganizationPattern {
    public let template: String
    public init(template: String) throws  // valide les variables
    public func relativePath(for activity: Activity) -> String
}
```

- Substitue les variables.
- Slugifie `{title}` : minuscules, accents enlevés, espaces → `-`.
- Gère les collisions : si fichier existe déjà avec un autre `id`, suffixer `_2`, `_3`, ...

### 3. `FileStorageService`

```swift
public actor FileStorageService {
    public init(container: ICloudContainer, pattern: OrganizationPattern)
    public func store(sourceFile: URL, for activity: Activity) async throws -> String  // retourne relativePath final
    public func url(for activity: Activity) throws -> URL
    public func delete(activity: Activity) async throws
    public func reorganize(activities: [Activity], to newPattern: OrganizationPattern, dryRun: Bool) async throws -> [ReorganizationMove]
}

public struct ReorganizationMove {
    public let activityId: UUID
    public let from: String
    public let to: String
}
```

- `store` : copie le fichier source vers le chemin calculé par le pattern, retourne le `relativePath` à stocker dans `Activity.sourceFileName`.
- `reorganize` : recalcule les chemins selon un nouveau pattern, déplace les fichiers (dry-run renvoie juste la liste).

### 4. Tests XCTest

- Génération de chemins pour les patterns prédéfinis.
- Slugification de titres avec accents et caractères spéciaux.
- Round-trip store → url → delete sur un container temporaire (`FileManager.default.temporaryDirectory`, sans vrai iCloud).
- Reorganize dry-run : aucune modification disque.
- Reorganize réel : déplacement effectif, ancien chemin libre.

## Hors scope

- UI de configuration du pattern (P3).
- Détection automatique du type d'activité (P2bis dans le prompt suivant).

## Validation

- Tests `GPXCoreTests` au vert.
- À la main : importer un fichier (manuellement copié dans le container) et vérifier qu'il est rangé selon le pattern.
