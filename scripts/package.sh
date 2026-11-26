#!/bin/bash
# Builds the downloadable release: Release build → Developer ID signature with the hardened
# runtime → notarized and stapled app → DMG (signed, notarized, stapled) → Gatekeeper check.
#
#   scripts/package.sh            result: .build/package/Rolltop.dmg
#
# Needs a "Developer ID Application" certificate in the keychain (ROLLTOP_RELEASE_IDENTITY
# picks one when there are several) and notary credentials saved once with
#   xcrun notarytool store-credentials <profile>
# passed as ROLLTOP_NOTARY_PROFILE (default: Rolltop-notary). Installs nothing and launches
# nothing. Before a release raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=${ROLLTOP_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application certificate found" >&2; exit 1; }
PROFILE=${ROLLTOP_NOTARY_PROFILE:-Rolltop-notary}
WORK=.build/package
DD=.build/dd-release
APP_NAME=Rolltop

# A fresh folder each run; the previous one is moved aside, not deleted.
if [[ -e "$WORK" ]]; then mv "$WORK" "$WORK.old.$(date +%s)"; fi
mkdir -p "$WORK"

echo "▸ build (Release)"
xcodegen generate --quiet
xcodebuild -project Rolltop.xcodeproj -scheme Rolltop -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "$DD" build -quiet
# Keep LaunchServices from routing rolltop:// to the build-folder copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PWD/$DD/Build/Products/Release/$APP_NAME.app" >/dev/null 2>&1 || true

APP="$WORK/$APP_NAME.app"
ditto "$DD/Build/Products/Release/$APP_NAME.app" "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")

echo "▸ sign $VERSION with $IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements Rolltop/Resources/Rolltop.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ notarize the app"
ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
xcrun notarytool submit "$WORK/$APP_NAME.zip" --keychain-profile "$PROFILE" --wait --timeout 20m
xcrun stapler staple "$APP"

echo "▸ DMG"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$APP_NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
DMG="$WORK/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$WORK/dmg" -fs APFS -format ULFO "$DMG" -quiet
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▸ notarize the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --timeout 20m
xcrun stapler staple "$DMG"

echo "▸ Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
shasum -a 256 "$DMG"
echo "done: $DMG ($VERSION)"
