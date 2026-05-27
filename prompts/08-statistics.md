# P6 (planning) / 08 (numérotation) — Statistiques agrégées

## Objectif

Vue "Statistiques" agrégeant les activités par période et par type, avec **comparaison année N vs N−1**.

## Pré-requis

- P1 modèle Core Data (stats précalculées sur Activity).
- P5 UI shell (entrée "Statistiques" dans sidebar).

## Livrables attendus

### 1. Service de calcul (dans `GPXCore`)

```swift
public struct StatsQuery {
    public let period: Period           // .year(Int) / .month(Int, Int) / .custom(Date, Date)
    public let activityTypes: Set<ActivityType>?
}

public struct StatsResult {
    public let totalDistance: Double          // m
    public let totalElevationGain: Double     // m
    public let totalDuration: Double          // s
    public let activityCount: Int
    public let byActivityType: [ActivityType: StatsResult]   // ventilation
    public let byMonth: [Int: StatsResult]?                  // si period = .year
}

public enum StatsAggregator {
    public static func compute(activities: [Activity], query: StatsQuery) -> StatsResult
}

public enum YearComparisonBuilder {
    public static func cumulative(activities: [Activity], year: Int, metric: Metric) -> [CumulativePoint]
    public enum Metric { case distance, elevationGain, duration, count }
}

public struct CumulativePoint {
    public let dayOfYear: Int
    public let cumulativeValue: Double
}
```

### 2. Vue principale (dans l'app)

Disposition (un grand panneau accessible depuis la sidebar item "Statistiques") :

```
┌──────────────────────────────────────────────────────────┐
│ Période : [2026 ▾]    Activités : [Toutes ▾]              │
├──────────────────────────────────────────────────────────┤
│ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│ │ Distance │ │ Dénivelé │ │ Temps    │ │ Sorties  │       │
│ │ 1247 km  │ │ 18 420 m │ │ 87 h     │ │   42     │       │
│ └──────────┘ └──────────┘ └──────────┘ └──────────┘       │
│                                                            │
│  Ventilation par activité (bar chart)                      │
│  Vélo   ████████████████ 720 km                            │
│  Rando  ████████ 320 km                                    │
│  ...                                                       │
│                                                            │
│  Année 2026 vs 2025 (cumul distance)                       │
│  [Line chart cumulatif jour de l'année]                    │
│                                                            │
│  Tableau croisé activité × mois (2026)                     │
│  [Grille mois en colonnes, activités en lignes]            │
└──────────────────────────────────────────────────────────┘
```

### 3. Composants Swift Charts

- 4 "KPI cards" en haut (distance, d+, temps, sorties).
- Bar chart horizontal : ventilation par activité (métrique sélectionnable : distance / d+ / temps / count).
- Line chart cumulatif : 2 courbes (année en cours, année précédente), tooltip au survol.
- Grille tableau : activité × mois, valeurs formatées.

### 4. Sélecteurs

- **Période** : Picker année (toutes années pour lesquelles il y a des activités). Optionnellement bouton "Mois en cours", "12 derniers mois", "Personnalisé".
- **Activités** : Picker multi-sélection (toutes activités, ou filtre).
- **Métrique** (pour le bar chart et le line chart) : Picker (distance / dénivelé / temps / sorties).

### 5. Tests

- `StatsAggregator` sur jeu de fixtures : agrégats par activité et par mois.
- `YearComparisonBuilder` : courbe cumulative correcte (croissante), valeurs aux jours 1, 90, 365.

## Hors scope

- Records / meilleures performances (non retenu en v1).
- Heatmap géographique (hors v1).
- Stats individuelles avancées (FC, puissance).

## Validation

- Sidebar → Statistiques → vue affiche les KPI corrects pour l'année courante.
- Sélection d'une autre année → données mises à jour.
- Comparaison N vs N−1 visible et cohérente.
