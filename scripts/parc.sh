#!/bin/bash
# Résumé du parc installé : lit telemetry/installs.json via l'API Storage Bunny (creds locaux,
# jamais exposés). N'imprime aucun secret. Usage : bash scripts/parc.sh
set -euo pipefail
cd "$(dirname "$0")/.."

val() { grep -E "^$1" Secrets.xcconfig 2>/dev/null | head -1 | sed -E 's/^[^=]*=[[:space:]]*//'; }
API_KEY="$(val BUNNY_API_KEY)"
ZONE_ID="$(val BUNNY_STORAGE_ZONE_ID)"
[ -n "$API_KEY" ] && [ -n "$ZONE_ID" ] || { echo "✗ BUNNY_API_KEY ou BUNNY_STORAGE_ZONE_ID manquant dans Secrets.xcconfig." >&2; exit 1; }

ZJSON="$(curl -fsS -H "AccessKey: $API_KEY" "https://api.bunny.net/storagezone/$ZONE_ID")"
read -r ZNAME ZPASS ZHOST < <(python3 -c 'import json,sys; z=json.loads(sys.argv[1]); print(z["Name"], z["Password"], z.get("StorageHostname") or "storage.bunnycdn.com")' "$ZJSON")

DATA="$(curl -fsS -H "AccessKey: $ZPASS" "https://$ZHOST/$ZNAME/telemetry/installs.json" 2>/dev/null || echo '{}')"

echo "$DATA" | python3 - <<'PY'
import json, sys
from collections import Counter
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not d:
    print("Aucune installation enregistrée pour l'instant.")
    raise SystemExit
print(f"Parc installé : {len(d)} machine(s)\n")
c = Counter(v.get("build", 0) for v in d.values())
print("Répartition par build :")
for b in sorted(c, reverse=True):
    n = c[b]
    print(f"  build {b:>3} : {n:>3}  {'█' * n}")
print("\nMachines (les plus récentes en premier) :")
for mid, v in sorted(d.items(), key=lambda kv: kv[1].get("lastSeen", ""), reverse=True):
    os_s = (v.get("os", "?") or "?")[:30]
    print(f"  {mid[:8]}…  build {str(v.get('build','?')):>3}  · {os_s:30}  · vu {str(v.get('lastSeen','?'))[:10]}  ({v.get('count',0)}×)")
PY
