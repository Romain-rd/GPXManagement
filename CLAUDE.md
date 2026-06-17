# CLAUDE.md — GPXManagement

Règles, conventions et contexte projet pour Claude Code.

---

## Contexte projet

Application **macOS native** pour gérer des fichiers GPS d'activités personnelles (vélo, moto, marche, randonnée, ski). Spec complète : voir [SPEC.md](./SPEC.md). Prompts de développement par phase : voir [prompts/](./prompts/).

Utilisateur unique (Romain), usage personnel, distribution hors Mac App Store.

---

## Stack & contraintes techniques

- **Swift 5.10+** / **SwiftUI** uniquement (pas d'AppKit sauf si SwiftUI ne couvre pas).
- **macOS 15+ (Sequoia)** minimum — utiliser les APIs récentes sans hésiter.
- **Core Data + CloudKit** pour les métadonnées.
- **Container iCloud de l'app** (`iCloud.com.demoustier.GPXManagement` ou identifiant équivalent à définir) pour les fichiers GPX/FIT, visible dans Finder.
- **MapKit** + overlays `MKTileOverlay` custom pour les tuiles **WMTS Géoplateforme IGN**.
- **Swift Charts** pour les graphiques (profil altimétrique, stats).
- **XCTest** pour les tests unitaires.
- **Developer ID + notarisation Apple** pour la distribution (DMG signé).

### Architecture

- **MVVM** strict.
- Code organisé en **Swift Packages locaux** dans le projet pour isoler la logique métier de l'UI macOS, en vue d'un futur portage iOS/iPadOS :
  - `GPXCore` : modèle, parsing GPX/FIT, services de classement, calcul stats.
  - `GPXMapKit` : abstractions cartographiques (overlays IGN, etc.) — séparé car MapKit a des spécificités plateforme.
  - `GPXStrava` : client OAuth + API Strava.
  - L'app macOS = couche UI SwiftUI qui consomme ces packages.
- Aucune dépendance tierce non strictement nécessaire. Préférer la stdlib et les frameworks Apple.

---

## Conventions de code

- **UI en français**, **identifiants de code en anglais**. Les **commentaires et messages de commit sont en français** (pratique constante du dépôt).
- Pas de commentaires sauf si la raison (le *pourquoi*) n'est pas évidente à la lecture. Pas de commentaires expliquant *quoi* fait le code.
- Pas de docstrings multi-paragraphes. Une ligne max.
- Pas de classes utilitaires fourre-tout (`Utils`, `Helpers`). Préférer les extensions ciblées.
- Préférer `struct` à `class` sauf raison forte (référence, héritage Cocoa).
- `@Observable` (macOS 14+) plutôt que `ObservableObject` pour les view models.
- `async/await` partout — pas de completion handlers, pas de Combine sauf si requis par une API Apple.
- Erreurs typées via `enum: Error`, jamais de `throws` non-typé sans `enum` dédié.

---

## Règles de comportement Claude

### Avant de coder

1. **Lire la spec et le prompt de la phase** concernée (`prompts/0X-*.md`) avant toute implémentation.
2. Si quelque chose dans le prompt est ambigu ou en conflit avec la spec, **demander avant de coder**.
3. Ne pas inventer de fonctionnalités hors scope de la phase courante.

### Pendant le code

- **Ne pas créer de nouveaux fichiers** sans nécessité — étendre l'existant quand c'est cohérent.
- **Ne pas créer de documentation Markdown** (README, docs, etc.) sans demande explicite. Le SPEC.md et CLAUDE.md sont les seuls docs persistants.
- Tester systématiquement les services métier (parsing, classement, stats) — XCTest dans la cible appropriée.
- Si une fonctionnalité UI doit être validée, l'**indiquer explicitement** dans la réponse (Claude ne peut pas tester l'UI macOS lui-même — c'est à l'utilisateur).

### Décisions hors scope

Si une décision technique non couverte par SPEC.md ou un prompt se présente :

1. Privilégier la solution la plus simple et la plus alignée Apple-native.
2. Documenter le choix dans la réponse à l'utilisateur, ne pas l'enterrer dans le code.
3. Si la décision est structurante, **demander avant**.

---

## Organisation du dépôt

```
GPXManagement/
├── SPEC.md                    # Cahier des charges complet
├── CLAUDE.md                  # Ce fichier
├── prompts/                   # Prompts de développement par phase
│   ├── 00-bootstrap.md
│   ├── 01-data-model.md
│   ├── 02-icloud-storage.md
│   ├── 03-import-gpx-fit.md
│   ├── 04-strava-sync.md
│   ├── 05-ui-shell.md
│   ├── 06-map-ign.md
│   ├── 07-elevation-profile.md
│   ├── 08-statistics.md
│   ├── 09-track-editing.md
│   └── 10-export-share.md
├── GPXManagement.xcodeproj    # App/ = groupe SYNCHRONISÉ (créer un .swift dans App/ suffit, ne pas éditer le pbxproj)
├── App/                       # Cible macOS SwiftUI, organisée par domaine :
│   ├── Core/                  # entrée app, config, navigation, fenêtre, menus (GPXManagementApp, ContentView, AppNavigationModel, WindowModel…)
│   ├── Services/              # services non-UI (AppServices+ext, Strava, export, iCloud, dossier surveillé…)
│   ├── Library/               # sidebar + liste d'activités + filtres (SidebarView, ActivityListView(+VM), ActivityFilters, SmartFilterEditor)
│   ├── ActivityDetail/        # détail d'activité + sections + opérations de trace (ActivityDetailView(+VM), MapCard, Photos, profil, TrackOperationSheets)
│   ├── Media/                 # éditeurs photo/vidéo (MediaEditor, VideoLayoutEditor)
│   ├── Parcours/              # parcours + étapes + éditeur d'itinéraire (ParcoursDetailView, StageDetailView, RouteEditorView)
│   ├── Raids/                 # raids (RaidDetailView+RaidsListView, RaidDetailViewModel, participants)
│   ├── Map/                   # vue d'ensemble + composants carte partagés (StageColoredMap, SlideOverInspector, GeoDistance…)
│   ├── Import/ Statistics/ Preferences/ Shared/   # une vue par dossier
│   ├── Assets.xcassets · GPXManagement.xcdatamodeld · Info.plist · GPXManagement.entitlements   # restent à la racine de App/
├── Packages/                  # logique métier en SwiftPM local (référencés explicitement, eux)
│   ├── GPXCore/  GPXMapKit/  GPXStrava/  (+ GPXRender, GPXVideo)
└── Tests/
```

> **Ajouter un fichier à l'app** : le créer dans le bon sous-dossier de `App/` — il est auto-inclus (groupe synchronisé Xcode 16). Préférer **une vue/un type par fichier** plutôt que d'agrandir un fichier existant.

---

## Identifiants & secrets

- Bundle ID : `com.demoustier.GPXManagement` (à confirmer en P0).
- Team ID Apple Developer : à provisionner en P0.
- Clé API Géoplateforme IGN : à provisionner avant la phase P4 (gratuite, sur `geoservices.ign.fr`).
- Strava API : `client_id` et `client_secret` à provisionner avant la phase P8 (création app sur `https://www.strava.com/settings/api`). Stockage `client_secret` côté app uniquement, jamais commité.

**Aucun secret n'est versionné dans le repo.** Utiliser un fichier `Secrets.xcconfig` non commité + `.gitignore`.

---

## Communication avec l'utilisateur

- Réponses en **français**.
- Concision : pas de résumés en fin de réponse, l'utilisateur lit le diff.
- Indiquer clairement les étapes à faire manuellement (signature Xcode, config provisioning, etc.) — Claude ne peut pas tout faire seul.
