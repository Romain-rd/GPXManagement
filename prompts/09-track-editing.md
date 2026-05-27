# P9 — Édition de traces

## Objectif

Permettre 4 opérations d'édition non destructives sur les traces : **découper / fusionner / nettoyer points aberrants / lisser**. La trace originale est conservée ; chaque édition produit une **nouvelle activité dérivée** (`editedFromActivityId` rempli).

## Pré-requis

- P1 modèle Core Data.
- P3 import (réutilisation des calculateurs de stats).
- P6 carte (pour preview visuel).

## Livrables attendus (dans `GPXCore`)

### 1. Opérations

```swift
public enum TrackOperations {

    public static func split(points: [TrackPoint], at index: Int) -> (left: [TrackPoint], right: [TrackPoint])

    public static func merge(_ tracks: [[TrackPoint]]) -> [TrackPoint]
    // ordonné par timestamp, gestion des chevauchements (dédoublonnage)

    public static func cleanOutliers(points: [TrackPoint], maxSpeed: Double = 80) -> CleanResult
    // retire points dont la vitesse instantanée > maxSpeed (m/s) ou qui sont à >500m du précédent en <2s

    public struct CleanResult {
        public let cleaned: [TrackPoint]
        public let removedIndices: [Int]
    }

    public static func simplify(points: [TrackPoint], tolerance: Double) -> [TrackPoint]
    // Douglas-Peucker en 2D (lat, lon)
}
```

### 2. UI d'édition dans l'app

Menu **"Édition"** dans la barre de menu (visible quand une activité est sélectionnée) :

#### 2.1 Découper

- Action "Découper la trace..." → ouvre un sheet :
  - Affiche la carte de la trace.
  - Slider de position (0 → 100 % de la distance).
  - Au déplacement : marqueur sur la carte.
  - Bouton "Découper" → crée 2 nouvelles activités (suffixe ` (1/2)` et ` (2/2)`).

#### 2.2 Fusionner

- Sélectionner ≥ 2 activités dans la liste → action "Fusionner les traces" (menu contextuel + menu Édition).
- Ouvre sheet de confirmation avec preview (carte + stats agrégées prévues).
- Bouton "Fusionner" → crée 1 nouvelle activité unique.

#### 2.3 Nettoyer points aberrants

- Action "Nettoyer points aberrants..." sur une trace sélectionnée → sheet :
  - Carte avec points aberrants détectés en **rouge**.
  - Compteur : "X points seront retirés".
  - Slider seuil de vitesse max.
  - Bouton "Appliquer" → nouvelle activité.

#### 2.4 Lisser (simplifier)

- Action "Simplifier la trace..." → sheet :
  - Slider tolérance (0 → 50 m).
  - Preview carte : trace originale en gris transparent, trace simplifiée superposée.
  - Compteur : "Points : 12 480 → 1 250 (réduction 90 %)".
  - Bouton "Appliquer" → nouvelle activité.

### 3. Gestion des dérivés

- Champ `editedFromActivityId` rempli sur les nouvelles activités.
- Dans la vue détail, badge "Dérivé de [nom de la trace originale]" + lien cliquable.
- Suppression d'une trace : si elle a des dérivés, demander confirmation explicite.

### 4. Tests

- `split` : test sur trace de N points, vérifier que `left.count + right.count == N + 1` (le point pivot est dans les deux moitiés pour continuité).
- `merge` : 3 traces avec timestamps imbriqués → ordre chronologique correct, pas de doublon de timestamp.
- `cleanOutliers` : insérer 5 points aberrants synthétiques → tous détectés et retirés, autres préservés.
- `simplify` : tolérance 0 → output == input ; tolérance grande → points extrêmes conservés.

## Hors scope

- Édition point par point (ajout/suppression manuels).
- Recalage GPS sur OSM road (snap-to-road).

## Validation

- Importer une trace, la découper en 2 → 2 nouvelles activités dans la liste, originale toujours là.
- Sélectionner 2 traces, fusionner → 1 nouvelle, ordre chrono correct.
- Simplifier une trace de 50 000 points → réduction visible sur la carte avec slider.
