# Plan d'action — état des médias synchronisé entre Macs

> Objectif : **toutes** les informations qu'on attache à une photo/vidéo (affichage sur la carte, position manuelle sur la trace, marquage « créé par l'app ») doivent être **identiques sur toutes les machines**.

---

## 1. Principe

Deux briques à corriger ensemble :

1. **Identité stable d'un média entre Macs** — ne plus utiliser `PHAsset.localIdentifier` (différent sur chaque Mac), mais **`originalFilename` + `creationDate`** (voyagent avec la photo via Photothèque iCloud).
2. **Stockage synchronisé et à la bonne échelle** — sortir de `UserDefaults` (local) **et** de l'iCloud KVS (trop petit), pour mettre cet état dans **Core Data + CloudKit**, attaché à l'activité.

---

## 2. État actuel (tout est local à un Mac)

| Information | Où c'est stocké | Clé | Synchronisé ? |
|---|---|---|---|
| Photo affichée/masquée sur la carte | `UserDefaults` (`photosHiddenOnMap`, `photosShownExplicit`) | `localIdentifier` | ❌ |
| Média créé par l'app (recadrage…) | `UserDefaults` (`appCreatedAssets`, JSON) | `localIdentifier` | ❌ |
| Position du média sur la trace | *(n'existe pas encore — recalculé à la volée)* | — | — |

```mermaid
flowchart LR
    subgraph MacA["💻 Mac A — UserDefaults local"]
        A1["photosHiddenOnMap = [A-id…]"]
        A2["photosShownExplicit = [A-id…]"]
        A3["appCreatedAssets = [A-id…]"]
    end
    subgraph MacB["💻 Mac B — UserDefaults local"]
        B1["(vide / valeurs propres à B)"]
    end
    MacA -. "aucun lien" .- MacB
```

---

## 3. Cible

| Information | Où | Clé | Synchronisé ? |
|---|---|---|---|
| Affichée/masquée sur la carte | Core Data (blob `mediaState` sur `Activity`) → CloudKit | `originalFilename` + `creationDate` | ✅ |
| Créé par l'app | idem | idem | ✅ |
| Position manuelle sur la trace | idem | idem | ✅ |

```mermaid
flowchart TD
    subgraph Cloud["☁️ CloudKit privé"]
        ACT["Activity\n+ mediaState (blob JSON)"]
    end
    subgraph MacA["💻 Mac A"]
        PA["Photos.app"] --> RA["clé = nom+date"]
    end
    subgraph MacB["💻 Mac B"]
        PB["Photos.app"] --> RB["clé = nom+date"]
    end
    ACT <--> MacA
    ACT <--> MacB
    RA -. "même clé\nIMG_5962.MOV|2026-05-27T14:32" .- RB
```

---

## 4. Pourquoi Core Data/CloudKit et pas l'iCloud KVS

L'iCloud Key-Value Store (où vivent déjà les préférences via `CloudPreferences`) est **plafonné à 1024 clés et 1 Mo au total**. Avec **~1375 traces** ayant chacune plusieurs médias, on dépasse forcément. CloudKit (déjà utilisé pour les activités) n'a pas cette limite et synchronise au même endroit que le reste des données.

```mermaid
flowchart LR
    KVS["iCloud KVS\nmax 1024 clés / 1 Mo"] -->|"1375 traces ❌"| NO["Inadapté"]
    CD["Core Data + CloudKit\n(déjà en place)"] -->|"blob par activité ✅"| OK["Adapté"]
```

---

## 5. Identité stable d'un média

```mermaid
flowchart TD
    ASSET["PHAsset"] --> RES["PHAssetResource\n.originalFilename = IMG_5962.MOV"]
    ASSET --> DATE["creationDate = 2026-05-27 14:32:08"]
    RES --> KEY["clé = IMG_5962.MOV | 1748349128"]
    DATE --> KEY
    KEY --> NOTE["unique dans le périmètre d'UNE activité\n(photos filtrées par temps + lieu)"]
```

- Nom + date arrondie à la seconde → unique au sein d'une sortie, même avec deux appareils.
- Seul angle mort accepté : deux appareils différents, **même nom ET même seconde** (raid multi-caméras synchronisées) — négligeable.

---

## 6. Modèle de données

Ajout d'un attribut **optionnel** `mediaState` (Binary/Transformable) sur l'entité `Activity` → migration légère, compatible CloudKit (nouvel attribut optionnel).

Contenu = JSON, une entrée par média ayant un état explicite :

```json
[
  {
    "file": "IMG_5962.MOV",
    "date": 1748349128,
    "onMap": true,          // true=affiché, false=masqué, absent=défaut (préférence globale)
    "posMeters": 12400.0,   // position manuelle le long de la trace ; absent=auto (heure→GPS)
    "appCreated": false
  }
]
```

On ne stocke que les **décisions explicites** (comme aujourd'hui) : une photo sans entrée suit les règles auto.

---

## 7. Résolution unifiée (lue partout : carte, profil, web, PDF, film)

```mermaid
flowchart TD
    START["média d'une activité"] --> POS{"posMeters\nmanuel ?"}
    POS -->|oui| MANUAL["position manuelle"]
    POS -->|non| TIME{"heure de prise\nappariable ?"}
    TIME -->|oui| BYTIME["position par l'heure\n(lève l'aller-retour)"]
    TIME -->|non| BYGPS["position par GPS\n(point le plus proche)"]

    START --> SHOW{"onMap\ndéfini ?"}
    SHOW -->|oui| EXPLICIT["affiché / masqué"]
    SHOW -->|non| DEFAULT["préférence photosSelectedByDefault"]
```

Aujourd'hui cette logique est éparpillée (`isPhotoShown` dans la vue, `resolvedCoordinate` dans GPXRender, `distanceForMedia` dans GPXVideo). **On la centralise** dans un service unique de GPXCore/GPXRender pour qu'un réglage se voie de façon identique partout.

---

## 8. Migration des données locales existantes

Au premier lancement de la nouvelle version, sur chaque Mac : convertir les anciennes clés `UserDefaults` (par `localIdentifier`) vers le nouveau format (par `nom+date`) dans `mediaState`, puis ne plus écrire dans `UserDefaults`.

```mermaid
sequenceDiagram
    participant U as UserDefaults (ancien)
    participant P as Photos.app
    participant C as Core Data (mediaState)
    U->>P: pour chaque localIdentifier stocké
    P-->>U: originalFilename + creationDate
    U->>C: écrit l'entrée (nom+date) sur l'activité
    Note over C: une fois migré, CloudKit propage aux autres Macs
```

Best-effort : un asset introuvable (supprimé) est simplement ignoré.

---

## 9. Plan d'action par étapes

> Chaque étape = un incrément buildable/testable, commité séparément.

- [ ] **Étape 1 — Identité + stockage.**
  - `PhotoLibraryService.stableKey(for:)` = `originalFilename` + `creationDate`.
  - Attribut `mediaState` sur `Activity` (migration légère) + accès lecture/écriture dans le repo (`fetchMediaState`/`updateMediaState`), synchro CloudKit.
- [ ] **Étape 2 — Résolution centralisée.**
  - Service unique `MediaPlacement` (priorité manuel→heure→GPS ; sélection explicite→défaut).
  - Brancher carte de détail + export web/PDF + film dessus (remplace `isPhotoShown`, `resolvedCoordinate`, `distanceForMedia`).
- [ ] **Étape 3 — Sélection carte reconstruite.**
  - Le toggle « sur la carte » écrit dans `mediaState` (plus dans `UserDefaults`).
  - `appCreated` déplacé dans `mediaState`.
  - Migration des anciennes clés locales (§8).
- [ ] **Étape 4 — Éditeur de position (carte + profil).**
  - Feuille validée précédemment : marqueur aimanté + scrubber profil, fantômes GPS/heure, Auto heure / Auto GPS / Réinitialiser.
  - Écrit `posMeters` dans `mediaState`.
- [ ] **Étape 5 — Cohérence.**
  - Détection écart heure↔GPS > 150 m → badge ⚠︎ sur la vignette + message dans l'éditeur.

---

## 10. Points ouverts / risques

- **Photothèque iCloud requise** pour que les médias (et donc nom+date) soient les mêmes partout. Si elle est désactivée sur un Mac, l'état se synchronise mais ne trouve pas les photos correspondantes (dégradation propre, pas de crash).
- **Migration Core Data + CloudKit** : valider qu'un nouvel attribut optionnel passe en migration légère sans casser le store iCloud existant (à tester sur une copie).
- **Volume du blob** : négligeable (quelques entrées JSON par activité), bien en-deçà des limites CloudKit.
- **Raids multi-participants** : si deux caméras produisent le même nom à la même seconde, collision possible — acceptée.
```mermaid
flowchart LR
    R["risque résiduel"] --> X["2 caméras · même nom · même seconde"]
    X --> OK["accepté (cas marginal)"]
```
