# P11 — Publication web d'un parcours en étapes (Bunny)

## Objectif

Publier un **parcours en étapes** (entité `Stage` + `RouteWaypoint`) en **page web autonome sur Bunny**, comme un raid, mais avec une **navigation façon app iPhone moderne** : barre d'onglets permanente en bas (rail vertical à gauche sur desktop), carte dominante, passage entre étapes immédiat.

URL publique cible : `https://www.gpxmanagement.net/routes/{uuid}/`

## Pré-requis

- P9 / parcours en étapes : entité `Stage`, `RouteWaypoint` typés (`.shaping`/`.poi`/`.stageStop`), `ParcoursDetailView`.
- P10 export : `HTMLReportRenderer`, `BunnyStorageService`, `WebExportOptions`, `WebExportProgress` (réutilisés).

## Principe de navigation (cœur de la demande)

- **Tab bar fixe** en bas (mobile) / **rail vertical à gauche** (desktop), style iOS, icônes — toujours visible, onglet actif mis en évidence.
- **4 onglets** : `🗺 Carte · 📋 Étapes · 📈 Profil · ⓘ Infos`.
- **Retour** : flèche `‹` en haut dans une sous-vue ; la tab bar reste le repère principal (jamais de cul-de-sac).
- **Entre étapes** (3 gestes redondants) : puces `[J1][J2][J3]` en haut · **glisser ⇄** · **tap d'un arrêt** sur la carte d'ensemble.

## Maquettes

### Mobile — onglet Carte (accueil)
```
┌───────────────────────────┐
│ Montée aux Houches     ⤴  │
│      ╲   1●               │
│     2●╲━━╱╲━●3            │   CARTE quasi plein écran
│       ╲      ╲            │   tracé coloré par étape
│        ●━━━━━🏁           │   arrêts numérotés + 🏁
│ ┌───────────────────────┐ │
│ │466 km · +8761 m · 4 ét│ │   bandeau résumé flottant
│ └───────────────────────┘ │
├───────────────────────────┤
│   🗺      📋     📈    ⓘ   │ ← tab bar fixe
│  Carte  Étapes Profil Infos│
└───────────────────────────┘
```

### Mobile — onglet Étapes (liste)
```
│ ① J1 · ven 10 · 86 km   ›│
│    Nice → Annot      📷 3  │
│ ─────────────────────────│
│ ② J2 · sam 11 · 160 km  ›│
│    Annot → Cervières      │
│ ─────────────────────────│
│ ④ J4 · lun 13 · 142 km  ›│
│    Val-d'Isère → Houches🏁│
```

### Mobile — détail d'une étape
```
┌───────────────────────────┐
│ ‹ Étapes                  │
│ [J1] [J2•] [J3] [J4]      │ ← puces (scroll ⇄), J2 actif
├───────────────────────────┤
│   Annot ●━━━━━● Cervières │   carte zoomée sur l'étape
│        col d'Izoard       │   (reste du parcours en gris)
├───────────────────────────┤
│ Étape 2 · samedi 11 juil. │
│ 160 km · +4 293 m         │
│ ▁▃▇▅▃▂▇▆  profil étape    │
│ 📝 Notes…                 │
│ 📷 [img] [img] [img]      │   photos de l'étape
│ 🏠 Étape : Bazar Hotel    │   refuge / hors-trace
│      ‹ glisser pour       │
│        changer d'étape ›  │
├───────────────────────────┤
│   🗺      📋     📈    ⓘ   │ ← tab bar reste
└───────────────────────────┘
```

### Desktop — rail à gauche, carte géante
```
┌──────────────────────────────────────────────────────────┐
│ Montée aux Houches         🏍 466 km · +8 761 m · 4 ét. ⤴ │
├────────┬─────────────────────────────────────────────────┤
│ 🗺 Carte│                                                 │
│ 📋 Étap.│            ⟵  TRÈS GRANDE CARTE  ⟶              │
│ 📈 Profl│       tracé coloré par étape (survol =          │
│ ⓘ Infos│            surbrillance de l'étape)             │
│         ├─────────────────────────────────────────────────┤
│         │ ▁▂▄▆▅▃▂▄▇▆▄  profil global (cliquable)           │
└────────┴─────────────────────────────────────────────────┘
```

## Contenu par onglet

| Onglet | Contenu |
|---|---|
| 🗺 **Carte** | Carte interactive plein cadre, **tracé coloré par étape**, arrêts numérotés + 🏁 ; bandeau résumé flottant (km, D+, nb étapes, dates). Tap d'un arrêt → étape correspondante. |
| 📋 **Étapes** | Liste (n°, jour/date, km, D+, départ→arrivée, vignette/📷). Tap → **détail étape** : carte zoomée, profil d'étape, notes (`Stage.notes`), **photos de l'étape**, refuge/hors-trace (`endOffTrack…`). Navigation : puces + glisser + tap carte. |
| 📈 **Profil** | Profil altimétrique global interactif (zones colorées par étape, survol synchronisé avec la carte). |
| ⓘ **Infos** | Titre, type/sport, totaux, dates, description, **galerie photos complète**, ⤓ Télécharger le GPX, ⤴ Partager. |

## Carte

- **Plus grande** que l'export trace actuel : quasi plein cadre mobile (onglet Carte), géante desktop.
- **Interactive** (Leaflet + tuiles, comme `WebExportOptions.MapStyle.interactive`), tracé **multicolore par étape** (pattern multi-polylines de `renderRaid`/`apercu`).
- Carte d'étape = même carte cadrée/zoomée sur l'étape, reste du parcours en gris clair.

## Architecture technique

**App mono-page** : un seul `index.html` piloté en JS (onglets, tab bar fixe, transitions, glisser entre étapes), `images/` (cartes PNG/profils/photos) ou tuiles interactives. **Pas** le pattern multi-pages `<iframe>` des raids.

### Réutilisation (export web existant cartographié)

- **Générateur** : étendre `HTMLReportRenderer` (`Packages/GPXRender`) avec `renderRoute(activity, stages, waypoints, photos) -> [String: Data]`, calqué sur `renderRaid()` mais sortie mono-page.
- **Données `Stage`** : `name, notes, plannedDate, coverImageData, endOffTrackLat/Lon, endConnectorData, startConnectorData, order, stopWaypointId`. Bornes d'étape via `stageBoundaries` (stops `.stageStop`). Tracé coloré par étape = découper `trackData` aux stops.
- **Photos par étape** : `gatherStagePhotos()` (recherche par date/coords autour de chaque arrêt) — `Stage` n'a pas de champ photos dédié.
- **Upload** : `BunnyStorageService.publish(files:folder:)`, **chemin `routes/{uuid}/`**.
- **Lien persisté** : `setWebPublished/clearWebPublished` + `publishConfigJSON` (comme trace/raid) → Publier / Republier / Supprimer.
- **Déclencheur UI** : bouton « Publier sur le web » dans `ParcoursDetailView`, sheet `WebExportOptions` + HUD `WebExportProgress`.

## Découpage (chaque phase = build + lancement + commit)

1. **Générateur mono-page** : coquille `index.html` + tab bar fixe + onglet **Carte** (carte colorée par étape, bandeau résumé). Données `Stage`/waypoints.
2. **Onglet Étapes** : liste + détail d'étape (carte zoomée, profil, notes) + navigation (puces / glisser / tap carte).
3. **Onglets Profil + Infos** + **photos par étape** (`gatherStagePhotos`) + galerie Infos.
4. **Publication** : bouton dans `ParcoursDetailView` + sheet options + upload Bunny + Republier/Supprimer + persistance du lien.

## Responsive

- **Mobile d'abord** : tab bar bas, une vue par onglet, gestes tactiles (glisser entre étapes, pincer la carte).
- **Tablette/desktop** : rail à gauche, carte agrandie, profil sous la carte.

## Hors-scope (v1)

Commentaires/visiteurs, météo, mode hors-ligne (PWA), édition depuis le web, multi-langue.
