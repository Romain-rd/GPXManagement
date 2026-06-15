#!/bin/bash
# Génère web/appcast.xml (signé EdDSA) à partir du DMG déjà construit/notarisé (build/GPXManagement-<ver>.dmg).
# À lancer SOI-MÊME (le binaire Sparkle accède à la clé privée du trousseau) : bash scripts/make-appcast.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
DMG="build/GPXManagement-$VERSION.dmg"
[ -f "$DMG" ] || { echo "✗ DMG absent : $DMG — lancer scripts/release.sh d'abord." >&2; exit 1; }

GA="$(find "$HOME/Library/Developer/Xcode/DerivedData"/GPXManagement-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_appcast 2>/dev/null | head -1)"
[ -n "$GA" ] || { echo "✗ generate_appcast introuvable — ouvrir le projet dans Xcode pour résoudre le package Sparkle." >&2; exit 1; }

SRC="build/appcast-src"
rm -rf "$SRC"; mkdir -p "$SRC"
cp "$DMG" "$SRC/"
"$GA" --download-url-prefix "https://www.gpxmanagement.net/download/" -o web/appcast.xml "$SRC"
echo "✓ web/appcast.xml généré (signé EdDSA)."
