#!/bin/bash
# Build, signe (Developer ID), notarise et empaquette GPXManagement en DMG distribuable.
# Prérequis : certificat "Developer ID Application" dans le trousseau + profil notarytool
#   xcrun notarytool store-credentials "notarytool" --apple-id "<id>" --team-id 43KVS4Z3H9 --password "<app-specific-pwd>"
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="GPXManagement"
CONFIG="Release"
TEAM_ID="43KVS4Z3H9"
NOTARY_PROFILE="notarytool"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$SCHEME.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Info.plist)
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" App/Info.plist)
DMG="$BUILD_DIR/$SCHEME-$VERSION.dmg"

echo "▸ Vérification des prérequis"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
	echo "✗ Certificat 'Developer ID Application' introuvable dans le trousseau." >&2
	echo "  Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application" >&2
	exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	echo "✗ Profil notarytool '$NOTARY_PROFILE' absent." >&2
	echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id $TEAM_ID --password <app-specific-pwd>" >&2
	exit 1
fi

echo "▸ Nettoyage"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "▸ Archive ($SCHEME $VERSION build $BUILD_NUM)"
# Archive en signature automatique (Apple Development) ; l'export developer-id re-signe.
# Override de l'identité car le projet épingle "Developer ID Application", incompatible avec l'automatique.
xcodebuild archive \
	-scheme "$SCHEME" \
	-configuration "$CONFIG" \
	-archivePath "$ARCHIVE" \
	-destination "generic/platform=macOS" \
	CODE_SIGN_STYLE=Automatic \
	CODE_SIGN_IDENTITY="Apple Development" \
	-allowProvisioningUpdates

echo "▸ Export Developer ID"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportPath "$EXPORT_DIR" \
	-exportOptionsPlist scripts/ExportOptions.plist \
	-allowProvisioningUpdates

echo "▸ Création du DMG"
TMP_DMG_DIR=$(mktemp -d)
cp -R "$APP" "$TMP_DMG_DIR/"
ln -s /Applications "$TMP_DMG_DIR/Applications"
hdiutil create -volname "$SCHEME" -srcfolder "$TMP_DMG_DIR" -ov -format UDZO "$DMG"
rm -rf "$TMP_DMG_DIR"

echo "▸ Notarisation (envoi à Apple, attente du verdict…)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling du ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "▸ Génération de l'appcast Sparkle (signé EdDSA)"
GENERATE_APPCAST="$(find "$HOME/Library/Developer/Xcode/DerivedData"/GPXManagement-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_appcast 2>/dev/null | head -1)"
if [ -n "$GENERATE_APPCAST" ]; then
	APPCAST_SRC="$BUILD_DIR/appcast-src"
	rm -rf "$APPCAST_SRC"; mkdir -p "$APPCAST_SRC"
	cp "$DMG" "$APPCAST_SRC/"
	"$GENERATE_APPCAST" --download-url-prefix "https://www.gpxmanagement.net/download/" -o web/appcast.xml "$APPCAST_SRC"
	echo "✓ appcast : web/appcast.xml (publié par deploy-web.sh)"
else
	echo "⚠︎ generate_appcast introuvable — ouvrir le projet dans Xcode pour résoudre le package Sparkle, puis relancer. Appcast NON régénéré." >&2
fi

echo "✓ Release prête : $DMG"
echo "▸ Verdict Gatekeeper sur l'app"
spctl --assess --type execute -vv "$APP" || true
