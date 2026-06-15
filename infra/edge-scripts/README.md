# Edge Script — endpoint de version & historique des installations

`version-endpoint.js` est un script **Bunny Edge Scripting** qui sert `version.json` **et** relève,
à chaque vérification de mise à jour de l'app, un ping anonyme dans Bunny Storage.

## Ce que l'app envoie

À chaque lancement (et toutes les 24 h une fois Sparkle en place), l'app appelle :

```
GET https://www.gpxmanagement.net/version.json?build=<N>&id=<uuid-anonyme>&os=<macOS>&v=<version>
```

- `build` : `CFBundleVersion` installé
- `id` : identifiant d'installation **anonyme** (UUID aléatoire, stocké localement)
- `os` / `v` : version macOS / version courte de l'app

## Déploiement (console Bunny)

C'est un **middleware** : il s'exécute sur **toutes** les requêtes du Pull Zone, donc le filtrage
par chemin est fait **dans le code** (`onOriginRequest` ne renvoie une réponse que pour `/version.json`,
sinon la requête passe normalement vers l'origine). ⚠️ Ne jamais utiliser un `serve()` qui répond à
toutes les requêtes — sinon tout le site renvoie le JSON de version.

1. **Edge Scripting → script (type Middleware)** → **Code editor** : coller `version-endpoint.js`.
2. **Environment** (secrets) :
   - `STORAGE_ZONE` = `gpxmanagement`
   - `STORAGE_ACCESS_KEY` = mot de passe de la Storage Zone (Storage → gpxmanagement → FTP & API Access → Password)
   - `STORAGE_HOST` = `storage.bunnycdn.com`
   - `STATS_KEY` = une clé secrète de ton choix (pour accéder au tableau de bord privé)
3. **Connected pull zones** : connecter **GPXManagement**.
4. **Deploy**. Pas de « trigger par chemin » à régler (géré dans le code).

## Tableau de bord privé

Une fois `STATS_KEY` défini et le script déployé, ouvre :

```
https://www.gpxmanagement.net/parc?key=<STATS_KEY>
```

→ page HTML : répartition des builds + liste des machines (id anonyme, build, macOS, dernière activité).
Sans la bonne clé → **403**. (Équivalent en local : `bash scripts/parc.sh`.)

## Lire l'historique

Le fichier `telemetry/installs.json` de la Storage Zone contient :

```json
{
  "<uuid>": { "build": 9, "os": "Version 15.5…", "v": "1.0",
              "firstSeen": "2026-…", "lastSeen": "2026-…", "count": 12 }
}
```

→ Répartition des builds, retardataires sous `minimumBuild`, dernière activité par machine.
On pourra brancher un mini-tableau de bord dessus plus tard.

## Avant déploiement

Tant que le script n'est pas routé sur `/version.json`, c'est le **fichier statique** `web/version.json`
qui répond (le gate fonctionne déjà), et les paramètres `build/id/os` restent visibles dans les
**logs CDN Bunny** (capture « option A »).
