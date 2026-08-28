#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Release blocked: Friday releases require a native Apple Silicon shell, never x86_64 or Rosetta." >&2
  exit 2
fi
TRANSLATED="$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')"
if [[ "$TRANSLATED" != "0" ]]; then
  echo "Release blocked: the release process is translated by Rosetta." >&2
  exit 2
fi
assert_arm64_only() {
  local artifact="$1"
  local arches
  arches="$(lipo -archs "$artifact")"
  if [[ "$arches" != "arm64" ]]; then
    echo "Release blocked: $artifact is not arm64-only (architectures=$arches)." >&2
    exit 2
  fi
  local description
  description="$(file "$artifact")"
  if [[ "$description" != *"arm64"* || "$description" == *"x86_64"* ]]; then
    echo "Release blocked: $artifact has an invalid Mach-O architecture: $description" >&2
    exit 2
  fi
}

IDENTITY="${FRIDAY_DEVELOPER_ID:-}"
PROFILE="${FRIDAY_NOTARY_PROFILE:-}"
if [[ -z "$IDENTITY" ]]; then
  echo "Release blocked: set FRIDAY_DEVELOPER_ID to a Developer ID Application identity hash or full name." >&2
  exit 2
fi
if [[ -z "$PROFILE" ]]; then
  echo "Release blocked: set FRIDAY_NOTARY_PROFILE to a notarytool keychain profile." >&2
  echo "Create one with: xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" >&2
  exit 2
fi

IDENTITIES="$(security find-identity -v -p codesigning)"
MATCHED_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -v needle="$IDENTITY" 'index($0, needle) && /"Developer ID Application:/ { print; exit }')"
if [[ -z "$MATCHED_IDENTITY" ]]; then
  echo "Release blocked: FRIDAY_DEVELOPER_ID does not resolve to a valid Developer ID Application identity." >&2
  exit 2
fi
TEAM_ID="$(printf '%s\n' "$MATCHED_IDENTITY" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))".*/\1/p')"
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Release blocked: could not extract the 10-character Team ID from the Developer ID identity." >&2
  exit 2
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null; then
  echo "Release blocked: FRIDAY_NOTARY_PROFILE could not authenticate with notarytool." >&2
  exit 2
fi

FRIDAY_SIGN_IDENTITY="$IDENTITY" npm run package

APP="$ROOT/zig-out/package/friday.app"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
ZIP="$ROOT/zig-out/package/Friday-0.1.0-arm64.app.zip"
DMG="$ROOT/zig-out/package/Friday-0.1.0-arm64.dmg"
assert_arm64_only "$APP/Contents/MacOS/friday"
for library in "$FRAMEWORKS"/*.dylib; do assert_arm64_only "$library"; done

cat >"$RESOURCES/signing-plan.txt" <<'EOF'
signing=developer-id-application
hardened-runtime=enabled
library-validation=enabled
timestamp=required
notarization=performed-by-release-script
EOF
sed -i '' 's/\.signing = "external-team"/\.signing = "developer-id-application"/' "$RESOURCES/package-manifest.zon"

SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
for library in "$FRAMEWORKS"/*.dylib; do
  codesign "${SIGN_ARGS[@]}" "$library"
  codesign --verify --strict --verbose=2 "$library"
done
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/resources/Friday.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
assert_arm64_only "$APP/Contents/MacOS/friday"
for library in "$FRAMEWORKS"/*.dylib; do assert_arm64_only "$library"; done
if [[ "$(otool -hv "$APP/Contents/MacOS/friday")" != *"ARM64"* ]]; then
  echo "Release blocked: otool did not report an ARM64 main Mach-O." >&2
  exit 2
fi

SIGNATURE="$(codesign -d --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application:"* ]]; then
  echo "Release blocked: app is not signed by a Developer ID Application identity." >&2
  exit 2
fi
if [[ "$SIGNATURE" != *"TeamIdentifier=$TEAM_ID"* ]]; then
  echo "Release blocked: signed app TeamIdentifier does not match $TEAM_ID." >&2
  exit 2
fi
if [[ "$SIGNATURE" == *"Timestamp=none"* || "$SIGNATURE" != *"Timestamp="* ]]; then
  echo "Release blocked: app signature has no trusted timestamp." >&2
  exit 2
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

rm -f "$DMG"
hdiutil create -quiet -volname Friday -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --verbose=4 "$DMG"

printf 'Release ready\nApp: %s\nDMG: %s\nArchitecture: arm64 (Rosetta translated=%s)\nDeveloper ID Team: %s\nNotary profile: %s\n' "$APP" "$DMG" "$TRANSLATED" "$TEAM_ID" "$PROFILE"
