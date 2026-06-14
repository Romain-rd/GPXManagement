#!/bin/bash
# Déploie le site de présentation (web/) sur Bunny Storage — la même zone que celle servie sur
# www.gpxmanagement.net. N'envoie que les pages marketing ; ne supprime jamais les dossiers
# traces/<uuid> et films/<uuid> (contenu utilisateur publié par l'app).
#
# Prérequis : Secrets.xcconfig avec BUNNY_API_KEY et BUNNY_STORAGE_ZONE_ID.
set -euo pipefail

cd "$(dirname "$0")/.."
SECRETS="Secrets.xcconfig"
PUBLIC_BASE="https://www.gpxmanagement.net"

[ -f "$SECRETS" ] || { echo "✗ $SECRETS introuvable." >&2; exit 1; }
val() { grep -E "^$1[[:space:]]*=" "$SECRETS" | head -1 | sed -E "s/^$1[[:space:]]*=[[:space:]]*//" | tr -d '\r'; }
API_KEY="$(val BUNNY_API_KEY)"
ZONE_ID="$(val BUNNY_STORAGE_ZONE_ID)"
[ -n "$API_KEY" ] && [ -n "$ZONE_ID" ] || { echo "✗ BUNNY_API_KEY ou BUNNY_STORAGE_ZONE_ID manquant." >&2; exit 1; }

echo "▸ Résolution de la zone de stockage…"
ZONE_JSON="$(curl -fsS -H "AccessKey: $API_KEY" "https://api.bunny.net/storagezone/$ZONE_ID")"
read -r ZONE_NAME ZONE_PASS ZONE_HOST < <(python3 - "$ZONE_JSON" <<'PY'
import json, sys
z = json.loads(sys.argv[1])
print(z["Name"], z["Password"], z.get("StorageHostname") or "storage.bunnycdn.com")
PY
)
echo "  zone: $ZONE_NAME · host: $ZONE_HOST"

ctype() { case "${1##*.}" in
  html) echo "text/html; charset=utf-8";; png) echo "image/png";; jpg|jpeg) echo "image/jpeg";;
  css) echo "text/css";; js) echo "application/javascript";; svg) echo "image/svg+xml";;
  dmg) echo "application/x-apple-diskimage";; *) echo "application/octet-stream";; esac; }

# Si un DMG fraîchement construit par scripts/release.sh existe, le placer dans download/ pour publication.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Info.plist 2>/dev/null || echo "")
DMG_SRC="build/GPXManagement-$VERSION.dmg"
if [ -n "$VERSION" ] && [ -f "$DMG_SRC" ]; then
  cp "$DMG_SRC" "web/download/GPXManagement-$VERSION.dmg"
  echo "▸ DMG inclus : GPXManagement-$VERSION.dmg ($(du -h "$DMG_SRC" | cut -f1))"
fi

# Pages marketing à publier (jamais traces/ ni films/).
FILES=$(cd web && find . -type f ! -name ".DS_Store" -not -path "./traces/*" | sed 's|^\./||')

PURGE=()
echo "▸ Envoi des fichiers…"
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  code=$(curl -fsS -o /dev/null -w "%{http_code}" -X PUT \
    -H "AccessKey: $ZONE_PASS" -H "Content-Type: $(ctype "$rel")" \
    --data-binary @"web/$rel" "https://$ZONE_HOST/$ZONE_NAME/$rel")
  echo "  ✓ $rel ($code)"
  PURGE+=("$PUBLIC_BASE/$rel")
  [ "$rel" = "index.html" ] && PURGE+=("$PUBLIC_BASE/")
  case "$rel" in */index.html) PURGE+=("$PUBLIC_BASE/${rel%index.html}");; esac
done <<< "$FILES"

echo "▸ Purge du cache CDN…"
for url in "${PURGE[@]}"; do
  enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$url")
  curl -fsS -o /dev/null -X POST -H "AccessKey: $API_KEY" "https://api.bunny.net/purge?url=$enc&async=false" || true
done

echo "✓ Site en ligne : $PUBLIC_BASE/"
