# GPXManagement — Cahier des charges

> Application macOS native pour importer, classer, visualiser et analyser des fichiers GPS (GPX/FIT) issus d'activités sportives et de plein air.

---

## 1. Vision

GPXManagement est un **outil personnel** pour centraliser toutes les traces GPS d'un utilisateur multi-activités (vélo, moto, marche, randonnée, ski) dans un référentiel unique synchronisé via iCloud, avec une visualisation cartographique de qualité (cartes IGN) et un suivi statistique dans le temps.

Objectifs clés :

1. **Centraliser** — un seul endroit pour toutes les traces, quelle que soit la source (Strava, fichiers manuels).
2. **Classer** — automatiquement par activité et par date, avec arborescence iCloud personnalisable.
3. **Visualiser** — carte IGN topographique + profil altimétrique interactif synchronisé.
4. **Analyser** — statistiques agrégées par période et par activité, comparaisons d'années.
5. **Éditer** — opérations classiques (couper, fusionner, nettoyer, lisser).
6. **Partager** — export GPX, image, PDF, intégration Share Sheet macOS.

---

## 2. Activités gérées

Catégories de premier niveau (chacune avec ses sous-catégories) :

| Activité | Sous-catégories |
|---|---|
| **Vélo** | Route, VTT, gravel |
| **Moto** | (libre) |
| **Marche** | Marche urbaine, marche sportive |
| **Randonnée pédestre** | (séparée de la marche) |
| **Ski** | Alpin, fond, freerando |
| **Rando à ski** | (séparée du ski alpin) |

> La distinction marche/randonnée et ski/rando à ski est explicite (catégories distinctes, pas de sous-catégories).

Modèle extensible : l'utilisateur peut ajouter d'autres activités plus tard.

---

## 3. Stack technique

| Couche | Choix |
|---|---|
| Langage | **Swift 5.10+** |
| UI | **SwiftUI** (macOS 15+ — Sequoia minimum) |
| Persistance métadonnées | **Core Data + CloudKit** (sync auto entre Macs de l'utilisateur) |
| Stockage fichiers GPX/FIT | **Container iCloud de l'app** (visible dans Finder/iCloud Drive sous "GPXManagement", sandboxé) |
| Cartographie | **MapKit** + overlays **WMTS Géoplateforme IGN** (multi-fonds commutables) |
| Graphiques (profil, stats) | **Swift Charts** (framework natif) |
| Parsing GPX | Parser maison (XMLParser) ou lib légère type `CoreGPX` |
| Parsing FIT | Lib Swift type `FitFileParser` (ou pont C avec SDK Garmin) |
| HTTP (Strava) | `URLSession` natif + `OAuth 2.0` (PKCE) |
| Architecture | **MVVM**, séparation Models / Services / Views, code structuré en Swift Packages locaux pour faciliter un futur portage iOS/iPadOS |
| Distribution | **Developer ID + notarisation Apple**, hors Mac App Store (DMG signé) |

> **Architecture forward-compatible iOS/iPadOS** : la logique métier (parsing, modèle, services) doit être placée dans des Swift Packages indépendants de l'UI, pour pouvoir être réutilisée dans une future app iOS sans modification.

---

## 4. Modèle de données (Core Data)

### Entités principales

**`Activity`** (= une sortie)
- `id` : UUID
- `title` : String
- `activityType` : String (enum : `cycling.road`, `cycling.mtb`, `motorcycle`, `walking`, `hiking`, `skiing.alpine`, `skiing.nordic`, `skiing.touring`...)
- `startDate` : Date
- `endDate` : Date
- `sourceFileName` : String (nom du fichier dans le container iCloud)
- `sourceFileFormat` : String (`gpx`, `fit`)
- `origin` : String (`manual_import`, `strava`)
- `stravaId` : String? (si origin = strava)
- `notes` : String?
- `tags` : [String] (transformable)
- **Stats précalculées** : `distance` (Double, m), `duration` (Double, s), `elevationGain` (Double, m), `elevationLoss` (Double, m), `avgSpeed`, `maxSpeed`, `avgHeartRate`, `maxHeartRate`, `boundingBox` (NSData/Transformable : minLat/maxLat/minLon/maxLon).
- `editedFromActivityId` : UUID? (si trace issue d'édition d'une autre)

**`TrackPoint`** (relation N → 1 vers Activity)
- Stockés en blob compressé (Transformable Data) dans Activity plutôt qu'entités séparées, pour les perfs. Format interne : tableau dense `[lat, lon, alt, time, hr?, cadence?, power?]`.
- Décodés à la demande pour affichage carte / profil.

**`UserPreference`** (singleton)
- Pattern d'organisation iCloud configurable (cf. §6)
- Couches IGN sélectionnées par défaut
- Préférences d'affichage (unités, fuseau, etc.)

**`StravaAccount`**
- Tokens OAuth chiffrés (Keychain), `athleteId`, `lastSyncDate`

### CloudKit
- Tous les containers `Activity` et `StravaAccount` (sans tokens) syncs via CloudKit privé.
- Les fichiers GPX/FIT eux-mêmes sont dans le **container iCloud Drive de l'app** — Core Data ne stocke que le nom de fichier.

---

## 5. Sources d'import

### 5.1 Glisser-déposer manuel
- Drop d'un ou plusieurs fichiers `.gpx` / `.fit` dans la fenêtre principale.
- Pipeline d'import : parsing → détection auto du type d'activité (depuis métadonnées GPX `<type>` ou FIT `sport`) → **dialogue de confirmation** (l'utilisateur peut corriger) → copie dans le container iCloud + insertion Core Data.
- Détection des doublons : hash du fichier ou couple (startDate, distance) ≈ identique.

### 5.2 Synchronisation Strava
- OAuth 2.0 (PKCE) avec scopes `activity:read_all`.
- **Sync de l'historique complet** au premier lancement, puis sync incrémentale manuelle (bouton "Synchroniser") ou auto (option utilisateur).
- Téléchargement GPX/TCX via l'API Strava → conversion en interne → stockage container iCloud comme une activité standard.

### 5.3 Hors scope (v1)
- FIT direct Garmin Connect, KML/KMZ — peuvent être ajoutés en v2.

---

## 6. Classement et stockage iCloud

### Arborescence physique (container iCloud de l'app)

Par défaut :

```
GPXManagement/
  2026/
    05/
      2026-05-27_velo-route_col-d-eze.gpx
      2026-05-27_velo-route_col-d-eze.json   (sidecar métadonnées humainement lisibles, optionnel)
    04/
      ...
  2025/
    ...
```

### Pattern configurable

L'utilisateur peut, dans les préférences, choisir un **pattern d'organisation** (template style Lightroom) :

- `{year}/{month}` (défaut)
- `{year}/{month}/{activity}`
- `{activity}/{year}/{month}`
- `{activity}/{year}-{month}-{day}_{title}.{ext}`
- Pattern personnalisé via variables (`{year}`, `{month}`, `{day}`, `{activity}`, `{subactivity}`, `{title}`, `{ext}`)

Lors d'un changement de pattern → **réorganisation des fichiers existants** proposée (avec dry-run / preview).

---

## 7. Visualisation cartographique

### Fonds de carte (commutables)

L'utilisateur bascule à la volée entre :

1. **IGN Scan 25** — carte topographique 1:25000 (Géoplateforme WMTS)
2. **IGN Plan v2** — carte généraliste moderne
3. **IGN Cartes des pentes** — couche pentes >30°, prioritaire pour ski/rando à ski
4. **MapKit standard** — fallback hors France
5. **MapKit satellite** — fallback hors France

> Implémentation : `MKTileOverlay` custom pointant vers `https://data.geopf.fr/wmts?...` pour les couches IGN. Clé API publique de la Géoplateforme (gratuite, à provisionner au démarrage).

### Modes d'affichage

- **Détail d'une sortie** (vue 3 colonnes — cf. §10) : la trace seule, fit-to-bounds.
- **Vue d'ensemble** : toutes les activités (ou un sous-ensemble filtré) tracées simultanément, couleurs par activité, contrôles de filtres latéraux (période, activité, distance min...).

---

## 8. Profil altimétrique

- Graphique **altitude vs distance**.
- Courbe de **pente (%)** superposée (couleur dégradée le long du tracé : vert/jaune/rouge selon raideur).
- **Survol synchronisé carte ↔ profil** : passer la souris sur le graphique → marqueur sur la carte, et inversement.
- Affichage d+, d−, distance, altitude min/max en encart.

---

## 9. Statistiques agrégées

### Vues

- **Par période** (mois / année / personnalisé) : distance, dénivelé+, temps, nombre de sorties.
- **Par activité** : ventilation des indicateurs par type d'activité.
- **Comparaison N vs N−1** : graphique cumulatif année en cours vs année précédente (style "course aux kilomètres").
- **Tableau croisé activité × mois** sur l'année courante.

### Indicateurs prioritaires

- Distance totale / cumulée
- Dénivelé positif total
- Temps de mouvement total
- Nombre de sorties

---

## 10. Interface principale (UI)

### Vue 3 colonnes (vue par défaut, style Mail/Notes)

| Sidebar (200 px) | Liste centrale (~320 px) | Détail (reste) |
|---|---|---|
| **Activités** (toutes, vélo, moto, marche, rando, ski, rando à ski) avec compteurs | Liste chronologique des sorties (titre, date, distance, d+) | **Carte** (fond IGN) + **Profil** + **Stats** de la sortie sélectionnée |
| **Années** (2024, 2025, 2026...) | Recherche + tri | Onglets internes : Carte / Profil / Stats / Notes |
| **Tags** personnalisés | Filtres (multi-activité, période) | |
| **Strava** (statut sync) | | |

### Vue d'ensemble carte

- Bouton ou onglet "Carte globale" depuis la sidebar.
- Affiche **toutes les sorties** (ou la sélection filtrée depuis la liste) sur un seul fond de carte IGN.
- Filtres latéraux : période, activité, distance, durée.
- Clic sur une trace → ouvre le détail.

### Vue statistiques

- Accessible depuis la sidebar (item "Statistiques").
- Tableaux + Swift Charts (cumulé, ventilation, comparaisons).

---

## 11. Édition de traces

Opérations supportées (toutes non destructives — la trace originale reste, une nouvelle trace dérivée est créée avec `editedFromActivityId`) :

- **Découper / scinder** : sélectionner un point → trace en 2 segments distincts.
- **Fusionner** : sélectionner 2 ou plusieurs traces → fusion chronologique en une trace unique.
- **Nettoyer points aberrants** : détection auto (vitesse impossible, sauts de position) + bouton "appliquer" avec preview.
- **Lisser / simplifier** : algorithme **Douglas-Peucker** avec slider tolérance + preview du nombre de points avant/après.

---

## 12. Export et partage

| Format | Usage |
|---|---|
| **GPX** | Ré-export après édition, compatibilité tierce |
| **PNG/JPG** | Capture haute-déf de la carte + trace |
| **PDF** | Rapport d'une sortie : carte + profil + stats + notes, imprimable |
| **Share Sheet macOS** | Intégration native (Mail, Messages, AirDrop, Notes...) |

---

## 13. Phases de développement

| Phase | Contenu | Prompt associé |
|---|---|---|
| **P0 — Bootstrap** | Création projet Xcode, structure Swift Packages, signature Developer ID, container iCloud configuré | `prompts/00-bootstrap.md` |
| **P1 — Modèle & stockage** | Core Data + CloudKit, gestion container iCloud, modèle Activity/TrackPoint | `prompts/01-data-model.md` + `prompts/02-icloud-storage.md` |
| **P2 — Import GPX/FIT** | Parsing, détection type, dialogue confirmation, drag-drop, détection doublons | `prompts/03-import-gpx-fit.md` |
| **P3 — UI shell + liste** | Vue 3 colonnes, sidebar, liste, recherche, filtres | `prompts/05-ui-shell.md` |
| **P4 — Carte IGN** | MapKit + overlays WMTS Géoplateforme, multi-fonds, affichage trace | `prompts/06-map-ign.md` |
| **P5 — Profil altimétrique** | Swift Charts, survol synchronisé carte/profil | `prompts/07-elevation-profile.md` |
| **P6 — Stats agrégées** | Vues période/activité, comparaisons, tableaux | `prompts/08-statistics.md` |
| **P7 — Vue d'ensemble carte** | Toutes traces sur une carte avec filtres | `prompts/05-ui-shell.md` (extension) |
| **P8 — Sync Strava** | OAuth, sync historique complet, sync incrémentale | `prompts/04-strava-sync.md` |
| **P9 — Édition traces** | Découper, fusionner, nettoyer, lisser | `prompts/09-track-editing.md` |
| **P10 — Export & partage** | GPX, PNG, PDF, Share Sheet | `prompts/10-export-share.md` |
| **P11 — Polish & distribution** | Notarisation, DMG, première version utilisable | (à venir) |

> Ordre recommandé pour un MVP utilisable rapidement : **P0 → P1 → P2 → P3 → P4 → P5** = première version permettant d'importer, classer, visualiser sur carte IGN et lire le profil. Le reste s'enchaîne selon priorité.

---

## 14. Hors scope (explicitement non couvert v1)

- Application iOS/iPadOS (l'architecture le permettra, le portage est en v2+).
- Sync Garmin Connect direct.
- Formats KML/KMZ, TCX.
- Heatmap géographique cumulative.
- Records / segments personnels.
- Comparaison superposée de plusieurs traces côte à côte.
- Stats individuelles avancées (FC, puissance, cadence) — les données sont stockées si présentes (FIT), mais pas exploitées en v1.

---

## 15. Contraintes & exigences non fonctionnelles

- **Performances** : ouverture d'une trace de 50 000 points < 500 ms ; vue d'ensemble avec 1000 traces < 2 s.
- **Hors-ligne** : l'app doit rester fonctionnelle hors connexion (sauf sync Strava et tuiles IGN non-cachées).
- **Cache tuiles IGN** : cache disque local (`URLCache` ou cache custom) pour réduire la dépendance réseau et respecter les quotas Géoplateforme.
- **Confidentialité** : aucune donnée envoyée à un tiers en dehors de Strava (et iCloud, mais sur compte utilisateur). Tokens OAuth en Keychain.
- **Robustesse import** : un fichier corrompu ou malformé ne doit jamais faire crasher l'app ; rapport d'erreur détaillé.
- **Tests** : couverture des services (parsing, classement, stats) ≥ 70 % via XCTest.

---

## 16. Livrables

1. Projet Xcode complet dans `/Users/romain/Developpement(Actif)/GPXManagement/`.
2. Application `GPXManagement.app` signée Developer ID, notarisée.
3. DMG d'installation.
4. Documentation interne minimale (ce SPEC.md + CLAUDE.md + prompts de développement).
