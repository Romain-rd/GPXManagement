# P5 (planning) / 07 (numérotation) — Profil altimétrique interactif

## Objectif

Afficher le profil altimétrique d'une trace, avec **courbe de pente** colorée et **survol synchronisé** carte ↔ profil.

## Pré-requis

- P1 modèle Core Data (TrackPoint via `trackData`).
- P6 carte (pour la synchronisation).

## Livrables attendus

### 1. Calculs (dans `GPXCore`)

```swift
public struct ElevationProfilePoint {
    public let distanceFromStart: Double  // m
    public let altitude: Double           // m
    public let slope: Double              // %, sur fenêtre 50 m
}

public enum ElevationProfileBuilder {
    public static func build(points: [TrackPoint]) -> [ElevationProfilePoint]
}
```

- Distance cumulée : Haversine point à point.
- Lissage altitude : moyenne mobile fenêtre 5 points avant calcul de pente, pour réduire bruit GPS.
- Pente : `(alt[i+w] - alt[i-w]) / (dist[i+w] - dist[i-w])` avec w correspondant à ~25 m de chaque côté.

### 2. Composant `ElevationProfileView` (SwiftUI + Swift Charts)

```swift
public struct ElevationProfileView: View {
    public let activity: Activity
    @Binding public var highlightedPoint: TrackPoint?
}
```

- Axe X : distance (km).
- Axe Y : altitude (m).
- **Aire sous courbe** colorée selon la pente locale :
  - Vert : pente < 4 %.
  - Jaune : 4–8 %.
  - Orange : 8–12 %.
  - Rouge : > 12 %.
  - Symétrique en descente (négatif).
- Encart en haut : distance totale, alt min/max, d+, d−.
- **Interaction** :
  - Survol souris → ligne verticale + bulle (distance, altitude, pente).
  - Synchronise `highlightedPoint` (binding) → la carte (P6) affiche le marqueur correspondant.
  - Inversement : si la carte met à jour `highlightedPoint`, le profil affiche la ligne verticale au bon endroit.

### 3. Décimation pour perfs

- Si la trace a > 5000 points : décimer pour l'affichage (Douglas-Peucker tolérance 1 m).
- Les calculs (d+, etc.) restent sur les points complets.

### 4. Tests

- `ElevationProfileBuilder` sur trace synthétique (escalier monotone, sinusoïde).
- Vérification que la pente reste bornée raisonnablement même sur points GPS bruités.

## Hors scope

- Altitude vs temps (non retenu en v1).
- Comparaison de profils (hors scope v1).

## Validation

- Ouvrir le détail d'une activité → onglet Profil affiche la courbe avec dégradé de pente.
- Survoler le profil → marqueur synchronisé sur la carte.
- Survoler la carte (le long de la polyline) → ligne verticale synchronisée sur le profil.
