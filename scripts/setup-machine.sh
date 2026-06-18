#!/bin/bash
# Routine de mise en route sur une NOUVELLE machine (ou après qu'Xcode a corrompu les fichiers projet).
# À lancer AVANT d'ouvrir le projet dans Xcode : sans Sparkle résolu, Xcode réécrit pbxproj/Info.plist/entitlements
# (retire Sparkle, repasse CFBundleVersion à une vieille valeur → « ne compile pas » + « Mise à jour requise »).
set -uo pipefail
cd "$(dirname "$0")/.."

echo "▸ 1. Résolution des packages Swift (Sparkle, GPXRender, …) — indispensable AVANT Xcode"
if xcodebuild -scheme GPXManagement -resolvePackageDependencies >/tmp/gpx-resolve.log 2>&1; then
  echo "  ✓ packages résolus"
else
  echo "  ✗ échec de la résolution — voir /tmp/gpx-resolve.log" >&2
fi

echo "▸ 2. Intégrité des fichiers projet (souvent corrompus par Xcode sans packages résolus)"
FILES="GPXManagement.xcodeproj/project.pbxproj App/Info.plist App/GPXManagement.entitlements"
DIRTY="$(git status --porcelain -- $FILES)"
if [ -n "$DIRTY" ]; then
  echo "  ⚠︎ fichiers projet MODIFIÉS localement :"
  echo "$DIRTY" | sed 's/^/      /'
  echo "      → s'il s'agit d'une corruption Xcode (Sparkle disparu, build rétrogradé), restaure :"
  echo "        git checkout HEAD -- $FILES"
else
  echo "  ✓ propres — build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist 2>/dev/null)"
fi

echo "▸ 3. Secrets.xcconfig (non versionné)"
if [ -f Secrets.xcconfig ]; then echo "  ✓ présent"; else echo "  ✗ MANQUANT — AirDrop depuis l'ancien Mac (clés IGN, Strava, Bunny)"; fi

echo "▸ 4. Build de vérification"
if xcodebuild -scheme GPXManagement -configuration Debug build >/tmp/gpx-build.log 2>&1; then
  echo "  ✓ BUILD OK"
else
  echo "  ✗ BUILD ÉCHEC — voir /tmp/gpx-build.log ($(grep -c 'error:' /tmp/gpx-build.log) erreurs)" >&2
fi

cat <<'EOF'

▸ À FAIRE MANUELLEMENT ENSUITE :
  • Données (GPX/FIT + CloudKit) : se synchronisent via iCloud — laisser le temps de redescendre.
  • Strava : reconnecter dans les Préférences (le jeton est local).
  • Releases (signature/notarisation) :
      - Certificat « Developer ID Application » dans le trousseau (Xcode → Settings → Accounts → Manage Certificates).
      - Profil notarytool :
          xcrun notarytool store-credentials "notarytool" --apple-id <apple-id> --team-id 43KVS4Z3H9 --password <app-specific-pwd>

▸ RÈGLE D'OR : lancer ce script (résolution des packages) AVANT d'ouvrir Xcode sur toute nouvelle machine.
EOF
