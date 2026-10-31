#!/bin/bash
# Builds, signs with Developer ID, notarizes and staples AWSBar.app.
#
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=awsbar-notary scripts/release.sh
#
# One-time setup for NOTARY_PROFILE:
#   xcrun notarytool store-credentials awsbar-notary \
#     --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
set -euo pipefail

: "${TEAM_ID:?set TEAM_ID to your Apple Developer team ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

cd "$(dirname "$0")/.."
OUT=build/release
ARCHIVE="$OUT/AWSBar.xcarchive"
rm -rf "${OUT:?}"
mkdir -p "$OUT"

xcodebuild archive \
  -project AWSBar.xcodeproj -scheme AWSBar -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID"

sed "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/" scripts/ExportOptions.plist > "$OUT/ExportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT"

APP="$OUT/AWSBar.app"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT/AWSBar-notarize.zip"
xcrun notarytool submit "$OUT/AWSBar-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

ditto -c -k --keepParent "$APP" "$OUT/AWSBar.zip"
echo "Notarized: $OUT/AWSBar.zip"
