#!/usr/bin/env bash
# Builds a universal Allotment, signs it with a Developer ID, has Apple notarise it, and packages it as a
# DMG and a zip in .build/release-artifacts/, ready to attach to a GitHub release.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=your-notary-profile \
#   scripts/release.sh
#
# SIGN_IDENTITY   required, a Developer ID Application signing identity in your Keychain.
# NOTARY_PROFILE  required, a notarytool profile saved with `xcrun notarytool store-credentials`.
#
# The version comes from MARKETING_VERSION in project.yml. The previous artifacts move to
# .build/release-artifacts-previous/, and the build reuses .build/DerivedData.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml)
DERIVED=".build/DerivedData"
BUILT="$DERIVED/Build/Products/Release/Allotment.app"
WORK=".build/release-work"
APP="$WORK/Allotment.app"
OUT=".build/release-artifacts"
DMG="$OUT/Allotment-$VERSION.dmg"
ZIP="$OUT/Allotment-$VERSION.zip"
ENTITLEMENTS="Allotment/Allotment.entitlements"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a saved notarytool profile.}"
if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "Release builds need a Developer ID Application identity, not \"$SIGN_IDENTITY\"." >&2
  exit 1
fi
if [[ -z "$VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from project.yml." >&2
  exit 1
fi

echo "Checking notarisation credentials…"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null

notarise() {
  local artifact="$1" report="$2" status
  echo "Waiting for Apple to notarise $(basename "$artifact")…"
  if ! xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$report"; then
    cat "$report" >&2
    return 1
  fi
  status=$(plutil -extract status raw -o - "$report")
  if [[ "$status" != "Accepted" ]]; then
    cat "$report" >&2
    echo "Apple did not accept this submission, so the release stopped. Fetch the log with:" >&2
    echo "  xcrun notarytool log $(plutil -extract id raw -o - "$report") --keychain-profile $NOTARY_PROFILE" >&2
    return 1
  fi
}

echo "Building Allotment $VERSION for Apple silicon and Intel…"
xcodegen generate --quiet
xcodebuild -project Allotment.xcodeproj -scheme Allotment -configuration Release -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

# One fixed scratch folder and one previous set of artifacts, replaced on every release.
rm -rf "${WORK:?}" "${OUT:?}-previous"
if [[ -e "$OUT" ]]; then
  mv "$OUT" "$OUT-previous"
fi
mkdir -p "$OUT" "$WORK/stage"
ditto "$BUILT" "$APP"

# Sign again with the Developer ID, the hardened runtime and a secure timestamp, which notarisation requires.
# The entitlements come from the project, so nothing a debug build adds, such as get-task-allow, comes along.
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "The signed app still allows debugging (get-task-allow), which Apple rejects." >&2
  exit 1
fi
codesign -dv "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "The hardened runtime is not on." >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "^Timestamp=" || { echo "The signature has no secure timestamp." >&2; exit 1; }
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Allotment")"

# Staple the app before packaging, so both downloads carry Apple's approval even when offline.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/Allotment-submission.zip"
notarise "$WORK/Allotment-submission.zip" "$WORK/app-notary.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -quiet -volname "Allotment $VERSION" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarise "$DMG" "$WORK/dmg-notary.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "Release artifacts:"
ls -lh "$OUT"
