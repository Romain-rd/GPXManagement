# P4 (planning) / 06 (numérotation) — Carte IGN multi-fonds

## Objectif

Afficher les traces GPS sur des **cartes IGN** (Géoplateforme WMTS), avec basculement à la volée entre plusieurs fonds : Scan 25, Plan v2, Cartes des pentes (ski), plus fallbacks MapKit (standard / satellite) pour les zones hors France.

## Pré-requis

- Clé API Géoplateforme IGN (gratuite, `geoservices.ign.fr` → "Géoplateforme"). Stockée dans `Secrets.xcconfig` comme `IGN_API_KEY`.
- P5 UI shell.

## Livrables attendus (dans `GPXMapKit`)

### 1. Définition des couches

```swift
public enum MapLayer: String, CaseIterable, Identifiable {
    case ignScan25       = "ign_scan25"
    case ignPlanV2       = "ign_planv2"
    case ignSlopes       = "ign_slopes"
    case mapkitStandard  = "mapkit_standard"
    case mapkitSatellite = "mapkit_satellite"

    public var displayName: String { ... }
    public var isIGN: Bool { ... }
}
```

### 2. Tile overlay WMTS

```swift
public final class IGNTileOverlay: MKTileOverlay {
    public init(layer: MapLayer, apiKey: String)
    // override url(forTilePath:) construit l'URL WMTS Géoplateforme
}
```

URLs WMTS Géoplateforme :

- Endpoint : `https://data.geopf.fr/wmts`
- Paramètres : `SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&LAYER=...&FORMAT=image/png`
- Layers :
  - Scan 25 : `GEOGRAPHICALGRIDSYSTEMS.MAPS` (ou `SCAN25TOUR_PYR-JPEG_WLD_WM` selon les évolutions Géoplateforme — à vérifier au moment du développement).
  - Plan v2 : `GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2`.
  - Cartes des pentes : `GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN`.
- **Important** : les noms exacts de layers et les conditions d'accès changent — vérifier sur `https://data.geopf.fr/annexes/ressources/wmts/` au moment de l'implémentation.

### 3. Cache disque tuiles

- `URLCache` partagé ou cache custom sur disque (taille max configurable, défaut 500 Mo).
- Stratégie : `cacheElseLoad` — éviter de retélécharger les tuiles déjà vues.
- Invalidation : aucune (les tuiles IGN sont stables sur de longues périodes).

### 4. Composant `TrackMapView` (SwiftUI wrapper)

```swift
public struct TrackMapView: NSViewRepresentable {
    public let activities: [Activity]      // 1 ou plusieurs
    @Binding public var layer: MapLayer
    @Binding public var highlightedPoint: TrackPoint?   // pour sync profil/carte (P7)
    public var onSelectActivity: (UUID) -> Void
}
```

Comportements :

- Affiche les traces (une `MKPolyline` par activité, couleur par type d'activité).
- Fit-to-bounds automatique sur la bounding box agrégée.
- Bascule de layer = supprimer l'overlay actuel, ajouter le nouveau.
- Si `layer.isIGN` et zoom > niveau supporté → fallback automatique vers MapKit standard avec banner discret "Zone non couverte par l'IGN".
- Si plusieurs activités : clic sur une polyline → callback `onSelectActivity`.
- Si `highlightedPoint` non nil → annotation animée au point correspondant.

### 5. Sélecteur de couche (UI)

- Floating control en haut-droite de la carte (`Picker` ou bouton-segmented).
- Persistance : la couche choisie est sauvegardée dans `UserPreference.defaultMapLayer` à chaque changement.

### 6. Couleurs par activité

Centralisées dans `GPXCore.ActivityType` :

| Activité | Couleur |
|---|---|
| Vélo route | `#1E88E5` (bleu) |
| Vélo VTT/gravel | `#43A047` (vert) |
| Moto | `#E53935` (rouge) |
| Marche | `#FB8C00` (orange) |
| Randonnée | `#6D4C41` (brun) |
| Ski alpin | `#00ACC1` (cyan) |
| Ski nordique | `#5E35B1` (violet) |
| Ski rando | `#3949AB` (indigo) |

### 7. Tests

- Tests unitaires sur la construction d'URLs WMTS.
- Tests sur le calcul de bounding box agrégée.
- Tests visuels manuels (Claude le signale à l'utilisateur).

## Hors scope

- Survol synchronisé carte/profil — c'est P7.
- Édition de trace via la carte (P9).

## Validation

- Sélection d'une activité → carte IGN Scan 25 centrée sur la trace, polyline visible.
- Bascule entre Scan 25 / Plan v2 / Pentes / MapKit fonctionne.
- Zoom hors France sur layer IGN → fallback MapKit avec message.
- Vue d'ensemble (P5) avec plusieurs traces affichées simultanément.
