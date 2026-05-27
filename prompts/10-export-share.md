# P10 — Export et partage

## Objectif

Permettre l'export d'une activité (ou d'une sélection) en **GPX**, **image PNG/JPG**, **PDF**, et l'intégration au **Share Sheet macOS**.

## Pré-requis

- P3 import (parser GPX réversible).
- P6 carte (pour générer images).
- P7 profil (pour le PDF).

## Livrables attendus

### 1. Export GPX (dans `GPXCore`)

```swift
public enum GPXWriter {
    public static func write(activity: Activity, points: [TrackPoint]) throws -> Data
}
```

- GPX 1.1 valide.
- `<trk><name>`, `<type>` (depuis `ActivityType`), `<trkseg>` avec `<trkpt lat lon><ele/><time/>`.
- Extensions Garmin pour HR/cadence/power si présents.
- Round-trip vérifié : parse(write(parse(file))) == parse(file) (aux flottants près).

### 2. Export image carte

```swift
public struct MapImageExporter {
    public func renderImage(activities: [Activity], layer: MapLayer, size: CGSize) async throws -> NSImage
}
```

- Utilise `MKMapSnapshotter` pour générer une image de la carte avec les polylines tracées par-dessus (compositing CoreGraphics).
- Pour les couches IGN : MapKit ne snapshot pas directement les `MKTileOverlay` custom → fallback : générer une image en compositing manuel (récupérer les tuiles WMTS, les assembler, dessiner les polylines).
- Résolution : choix utilisateur (1080p, 4K, sur mesure).

### 3. Export PDF

```swift
public struct PDFReportRenderer {
    public func render(activity: Activity, points: [TrackPoint], stats: ActivityStats) async throws -> Data
}
```

Mise en page A4 :

1. **En-tête** : titre, date, activité (icône + libellé).
2. **Carte** : 50 % de la hauteur, layer IGN par défaut.
3. **Profil altimétrique** : 20 % hauteur.
4. **Stats** : grille (distance, durée, durée mouvement, d+, d−, vitesse moy/max, FC si dispo).
5. **Notes** : si présentes.
6. **Pied de page** : "GPXManagement — exporté le {date}".

Implémentation : `CGContext` PDF + rendu SwiftUI offscreen via `ImageRenderer`.

### 4. Intégration Share Sheet

- Menu "Fichier > Partager..." actif quand une activité est sélectionnée.
- Ouvre `NSSharingServicePicker` avec les items : URL du GPX + image de la carte.

### 5. UI

- Menu **Fichier** → "Exporter en GPX...", "Exporter en image...", "Exporter en PDF...", "Partager...".
- Sheet d'export avec options selon le format.

### 6. Tests

- GPX writer + GPX parser round-trip sur fichiers de référence.
- Snapshot test image (taille, présence du tracé).
- PDF généré : ouvre dans Preview macOS (test manuel à valider par l'utilisateur).

## Hors scope

- Export TCX, KML.
- Export en batch d'un grand nombre d'activités en un fichier.

## Validation

- Sélection d'une activité → Exporter en GPX → fichier sauvé, ré-importable.
- Exporter en PNG → image cohérente avec la carte affichée.
- Exporter en PDF → rapport ouvert dans Preview.
- Partager → fenêtre macOS native avec les services courants.
