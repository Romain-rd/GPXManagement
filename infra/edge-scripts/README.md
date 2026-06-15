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

1. **Edge Scripting → New script**, coller `version-endpoint.js`.
2. Le **rattacher au Pull Zone** du site, déclencheur sur le chemin **`/version.json`**.
3. **Secrets** (Edge Scripting → Environment) :
   - `STORAGE_ZONE` = nom de la Storage Zone (celle où `deploy-web.sh` publie le site)
   - `STORAGE_ACCESS_KEY` = AccessKey / mot de passe de cette Storage Zone
   - `STORAGE_HOST` = `storage.bunnycdn.com` (ou le host régional)
4. Déployer. Désormais chaque appel `version.json` est enregistré, et la réponse reste le
   `version.json` que tu continues d'éditer puis de publier via `deploy-web.sh`.

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
