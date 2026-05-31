#!/usr/bin/env bash
# Diagnostic GPXManagement : compte iCloud, Team ID, store local, logs CloudKit.
# À lancer sur le Mac à diagnostiquer. Copier-coller la sortie complète.

set -u

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
dim()   { printf "\033[2m%s\033[0m\n" "$1"; }
hr()    { printf -- "──────────────────────────────────────────────\n"; }

bold "[Hôte]"
echo "Machine        : $(scutil --get ComputerName 2>/dev/null || hostname)"
echo "macOS          : $(sw_vers -productVersion)"
echo "Date           : $(date '+%Y-%m-%d %H:%M:%S %z')"
hr

bold "[1] Compte iCloud actif"
account_id=$(defaults read MobileMeAccounts 2>/dev/null | awk -F\" '/AccountID/ {print $2; exit}')
if [[ -n "${account_id:-}" ]]; then
  echo "AccountID      : ${account_id}"
else
  echo "AccountID      : (introuvable — iCloud non configuré ?)"
fi
hr

bold "[2] Certificat Apple Development (Team ID)"
subject=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
          | openssl x509 -subject -noout 2>/dev/null)
if [[ -n "${subject:-}" ]]; then
  echo "${subject}"
  team=$(echo "${subject}" | sed -n 's/.*OU=\([^,]*\),.*/\1/p')
  echo "Team ID extrait: ${team:-?}"
else
  echo "(aucun certificat 'Apple Development' trouvé dans le keychain)"
fi
hr

bold "[3] Store local Core Data (Sandbox CloudKit)"
store="$HOME/Library/Containers/com.demoustier.GPXManagement/Data/Library/Application Support/GPXManagement/GPXManagement.sqlite"
if [[ -f "$store" ]]; then
  count=$(sqlite3 "$store" "SELECT count(*) FROM ZACTIVITY;" 2>/dev/null)
  size=$(du -h "$store" | awk '{print $1}')
  echo "Chemin         : $store"
  echo "Taille         : $size"
  echo "Activités      : ${count:-?}"
else
  echo "Store introuvable — l'app n'a jamais été lancée sur ce Mac"
  echo "Chemin attendu : $store"
fi
hr

bold "[4] Fichiers iCloud Drive du container"
ubiq="$HOME/Library/Mobile Documents/iCloud~com~demoustier~GPXManagement/Documents"
if [[ -d "$ubiq" ]]; then
  nb_files=$(find "$ubiq" -type f \( -name '*.gpx' -o -name '*.fit' \) 2>/dev/null | wc -l | tr -d ' ')
  echo "Fichiers GPX/FIT visibles localement : $nb_files"
else
  echo "Container iCloud Drive absent localement : $ubiq"
fi
hr

bold "[5] Environnement CloudKit utilisé par l'app"
env_lines=$(log show --predicate 'process == "GPXManagement"' --last 1h --info 2>/dev/null \
            | grep -E "environment=Sandbox|environment=Production" | head -3)
if [[ -n "${env_lines:-}" ]]; then
  echo "$env_lines"
else
  echo "(aucune trace CloudKit dans la dernière heure — relance l'app puis rejoue ce script)"
fi
hr

bold "[6] Erreurs CloudKit récentes (1h)"
err_lines=$(log show --predicate 'process == "GPXManagement"' --last 1h --info 2>/dev/null \
            | grep -iE "cloudkit.*error|recoverableError|notAuthenticated|partialError|denied" \
            | head -10)
if [[ -n "${err_lines:-}" ]]; then
  echo "$err_lines"
else
  echo "(aucune erreur CloudKit notable)"
fi
hr

dim "Fin du diagnostic."
