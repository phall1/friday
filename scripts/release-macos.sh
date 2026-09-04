#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PREFLIGHT="$ROOT/scripts/release-preflight.sh"

die() {
  printf 'Release blocked: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/release-macos.sh candidate --expected-commit <full-sha> --expected-tag <vX.Y.Z>
  scripts/release-macos.sh promote --manifest <candidate.json> --gui-evidence <evidence.json>

candidate builds and notarizes an immutable candidate, but never declares it
promotion-ready. promote is a read-only readiness check; it does not publish,
upload, tag, notarize, or otherwise modify the candidate.
EOF
  exit 2
}

require_candidate_credentials() {
  IDENTITY="${FRIDAY_DEVELOPER_ID:-}"
  PROFILE="${FRIDAY_NOTARY_PROFILE:-}"
  [[ -n "$IDENTITY" ]] || die "set FRIDAY_DEVELOPER_ID to a Developer ID Application identity hash or full name"
  if [[ -z "$PROFILE" ]]; then
    echo "Release blocked: set FRIDAY_NOTARY_PROFILE to a notarytool keychain profile." >&2
    echo "Create one with: xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" >&2
    exit 2
  fi

  local identities matched_identity
  identities="$(security find-identity -v -p codesigning)"
  matched_identity="$(printf '%s\n' "$identities" | awk -v needle="$IDENTITY" 'index($0, needle) && /"Developer ID Application:/ { print; exit }')"
  [[ -n "$matched_identity" ]] || die "FRIDAY_DEVELOPER_ID does not resolve to a valid Developer ID Application identity"
  TEAM_ID="$(printf '%s\n' "$matched_identity" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))".*/\1/p')"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "could not extract the 10-character Team ID from the Developer ID identity"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null ||
    die "FRIDAY_NOTARY_PROFILE could not authenticate with notarytool"
}

assert_arm64_only() {
  local artifact="$1"
  local arches description
  arches="$(lipo -archs "$artifact")"
  [[ "$arches" == "arm64" ]] || die "$artifact is not arm64-only (architectures=$arches)"
  description="$(file "$artifact")"
  [[ "$description" == *"arm64"* && "$description" != *"x86_64"* ]] ||
    die "$artifact has an invalid Mach-O architecture: $description"
}

build_candidate() {
  local expected_commit="$1"
  local expected_tag="$2"

  # Cheap provenance checks and external credentials fail before any build.
  "$PREFLIGHT" repository "$expected_commit" "$expected_tag"
  require_candidate_credentials
  "$PREFLIGHT" source "$expected_commit" "$expected_tag"

  local version app frameworks resources zip dmg manifest library signature
  version="$(node -p "require('./app.json').version")"
  app="$ROOT/zig-out/package/Friday.app"
  frameworks="$app/Contents/Frameworks"
  resources="$app/Contents/Resources"
  zip="$ROOT/zig-out/package/Friday-$version-arm64.app.zip"
  dmg="$ROOT/zig-out/package/Friday-$version-arm64.dmg"
  manifest="$ROOT/zig-out/package/Friday-$version-arm64.release-manifest.json"

  # The automation-enabled sibling proves packaged effects at the exact source
  # and dependency pins. It is then replaced by the production candidate.
  FRIDAY_AUTOMATION=1 FRIDAY_SIGN_IDENTITY="$IDENTITY" npm run package
  "$PREFLIGHT" package-e2e "$expected_commit" "$expected_tag" "$app"
  FRIDAY_AUTOMATION=0 FRIDAY_SIGN_IDENTITY="$IDENTITY" npm run package

  cat >"$resources/signing-plan.txt" <<'EOF'
signing=developer-id-application
hardened-runtime=enabled
library-validation=enabled
timestamp=required
notarization=performed-by-release-script
EOF
  sed -i '' 's/\.signing = "external-team"/\.signing = "developer-id-application"/' "$resources/package-manifest.zon"
  if grep -R -i -E 'signing=none|unsigned local package' "$resources"; then
    die "bundle resources contain an unsigned-package claim"
  fi

  local sign_args=(--force --options runtime --timestamp --sign "$IDENTITY")
  for library in "$frameworks"/*.dylib; do
    assert_arm64_only "$library"
    codesign "${sign_args[@]}" "$library"
    codesign --verify --strict --verbose=2 "$library"
  done
  codesign "${sign_args[@]}" --entitlements "$ROOT/resources/Friday.entitlements" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  assert_arm64_only "$app/Contents/MacOS/friday"
  [[ "$(otool -hv "$app/Contents/MacOS/friday")" == *"ARM64"* ]] || die "otool did not report an ARM64 main Mach-O"

  signature="$(codesign -d --verbose=4 "$app" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application:"* ]] || die "app is not signed by a Developer ID Application identity"
  [[ "$signature" == *"TeamIdentifier=$TEAM_ID"* ]] || die "signed app TeamIdentifier does not match $TEAM_ID"
  [[ "$signature" == *"Timestamp="* && "$signature" != *"Timestamp=none"* ]] || die "app signature has no trusted timestamp"

  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"

  rm -f "$dmg"
  hdiutil create -quiet -volname Friday -srcfolder "$app" -ov -format UDZO "$dmg"
  codesign --force --timestamp --sign "$IDENTITY" "$dmg"
  codesign --verify --strict --verbose=2 "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --verbose=4 "$dmg"

  "$PREFLIGHT" create-manifest "$expected_commit" "$expected_tag" "$app" "$dmg" "$TEAM_ID" "$manifest"
  printf '\nCandidate built and notarized; it is NOT promotion-ready.\nApp: %s\nDMG: %s\nManifest: %s\nNext: record normal-GUI evidence for these exact hashes, then run the promote readiness check.\n' "$app" "$dmg" "$manifest"
}

mode="${1:-}"
shift || true
case "$mode" in
  candidate)
    expected_commit=""
    expected_tag=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --expected-commit) [[ $# -ge 2 ]] || usage; expected_commit="$2"; shift 2 ;;
        --expected-tag) [[ $# -ge 2 ]] || usage; expected_tag="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n "$expected_commit" && -n "$expected_tag" ]] || usage
    build_candidate "$expected_commit" "$expected_tag"
    ;;
  promote)
    manifest=""
    gui_evidence=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --manifest) [[ $# -ge 2 ]] || usage; manifest="$2"; shift 2 ;;
        --gui-evidence) [[ $# -ge 2 ]] || usage; gui_evidence="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n "$manifest" && -n "$gui_evidence" ]] || usage
    "$PREFLIGHT" promote "$manifest" "$gui_evidence"
    ;;
  *) usage ;;
esac
