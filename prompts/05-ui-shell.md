# P3 (planning) / 05 (numérotation) — UI shell, liste et vue d'ensemble

## Objectif

Mettre en place la structure principale de l'interface : **vue 3 colonnes** (sidebar / liste / détail) + **vue d'ensemble carte** accessible depuis la sidebar.

## Pré-requis

- P1 modèle Core Data.
- P2 service de fichiers.
- P3 import fonctionnel (pour avoir des données réelles à afficher).

## Livrables attendus

### 1. Structure `NavigationSplitView` 3 colonnes

```
┌─────────────┬──────────────────┬──────────────────────────┐
│ Sidebar     │ Liste            │ Détail                    │
│             │                  │                            │
│ Activités   │ [Search]         │ [Onglets: Carte/Profil/    │
│  Toutes     │ ──────────────   │  Stats/Notes]              │
│  Vélo       │ ▣ Col d'Èze      │                            │
│  Moto       │   27 mai · 45 km │ (contenu selon onglet)     │
│  Marche     │ ▣ ...            │                            │
│  Rando      │                  │                            │
│  Ski        │                  │                            │
│  Rando ski  │                  │                            │
│             │                  │                            │
│ Années      │                  │                            │
│  2026 (12)  │                  │                            │
│  2025 (87)  │                  │                            │
│             │                  │                            │
│ Tags        │                  │                            │
│  ...        │                  │                            │
│             │                  │                            │
│ ─────────── │                  │                            │
│ ◐ Carte     │                  │                            │
│ ◑ Stats     │                  │                            │
│ ⊙ Strava    │                  │                            │
└─────────────┴──────────────────┴──────────────────────────┘
```

#### Sidebar

- Section **Activités** : toutes + une entrée par activité avec compteur d'activités.
- Section **Années** : entrées par année (dérivées des activités existantes) avec compteurs.
- Section **Tags** : tags personnalisés utilisés au moins une fois.
- Entrées spéciales en bas :
  - **Carte d'ensemble** — bascule vers la vue carte unique (cf. §3).
  - **Statistiques** — bascule vers la vue stats (cf. P8).
  - **Strava** — état de sync (cf. P8 sync).

Sélection multiple combinable (cliquer sur "Vélo" + "2026" = filtre intersection).

#### Liste centrale

- `List` SwiftUI avec :
  - Recherche textuelle (titre, notes, tags).
  - Tri : date (défaut, desc), distance, durée, d+.
  - Chaque ligne : titre, date relative ("il y a 3 jours"), distance, d+, icône activité.
  - Sélection simple = ouverture du détail. Sélection multiple = active la vue carte d'ensemble sur la sélection.
- Drop zone pour import (P3) — drop sur la liste.

#### Détail

- `TabView` ou segmented control en haut : **Carte / Profil / Statistiques / Notes**.
- Carte : cf. P6 (P4 planning).
- Profil : cf. P7 (P5 planning).
- Statistiques : panneau lecture seule (distance, d+, d−, durée, durée mouvement, vitesse moy/max, FC moy/max si dispo, allure).
- Notes : `TextEditor` éditable, persisté dans `Activity.notes`.

### 2. Vue d'ensemble carte

- Mode **plein écran** central (la liste reste en colonne mais le détail est remplacé par une grande carte).
- Affiche les activités selon les filtres sidebar + sélection liste :
  - Sans sélection → toutes les activités du filtre courant.
  - Avec sélection multiple dans la liste → seules les activités sélectionnées.
- Chaque trace est dessinée avec :
  - Couleur dépendant du type d'activité (palette définie une fois).
  - Opacité réduite si beaucoup de traces (>50) pour lisibilité.
- Clic sur une trace → bascule vers vue détail de l'activité.
- Filtres flottants (overlay) : période, activité, distance min/max.

### 3. Préférences

`Settings` SwiftUI (menu Préférences) avec onglets :

- **Général** : couche carte par défaut.
- **Organisation iCloud** : sélecteur de pattern (cf. P2) + bouton "Réorganiser maintenant".
- **Strava** : connexion / sync (P8).
- **À propos** : version, lien GitHub si applicable.

### 4. Modèles SwiftUI / view models

```swift
@Observable
final class ActivityListViewModel {
    var filters: ActivityFilters = .init()
    var sortOrder: SortOrder = .dateDesc
    var searchText: String = ""
    var activities: [Activity] = []   // fetched
    func reload() async
}

@Observable
final class AppNavigationModel {
    var sidebarSelection: SidebarItem? = .allActivities
    var listSelection: Set<UUID> = []
    var mode: NavigationMode = .threeColumn  // ou .mapOverview, .statistics
}
```

### 5. Tests

- Tests unitaires sur les ViewModels (filtres, tri).
- Pas de tests UI en P5 (XCUITest peut venir plus tard).

## Hors scope

- Implémentation carte IGN (P6).
- Profil altimétrique (P7).
- Statistiques agrégées détaillées (P8).
- Édition de traces (P9).

## Validation

- L'app affiche la sidebar avec activités/années/tags réels.
- Cliquer sur une activité importée affiche son détail (carte vide pour l'instant, stats remplies).
- La recherche et les filtres fonctionnent.
- Drop d'un GPX dans la liste ouvre le sheet d'import P3.
