#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(node -p "require('./app.json').version")"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Friday packaging requires a native Apple Silicon shell; x86_64 hosts and Rosetta are refused." >&2
  exit 2
fi
TRANSLATED="$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')"
if [[ "$TRANSLATED" != "0" ]]; then
  echo "Friday packaging cannot run through Rosetta (sysctl.proc_translated=$TRANSLATED)." >&2
  exit 2
fi

assert_arm64_only() {
  local artifact="$1"
  local arches
  arches="$(lipo -archs "$artifact")"
  if [[ "$arches" != "arm64" ]]; then
    echo "Friday arm64 assertion failed for $artifact: architectures=$arches" >&2
    exit 2
  fi
  local description
  description="$(file "$artifact")"
  if [[ "$description" != *"arm64"* || "$description" == *"x86_64"* ]]; then
    echo "Friday Mach-O assertion failed for $artifact: $description" >&2
    exit 2
  fi
}

rm -rf "$ROOT/zig-out"
BUILD_ARGS=("-Dtarget=aarch64-macos")
if [[ "${FRIDAY_AUTOMATION:-0}" == "1" ]]; then BUILD_ARGS+=("-Dautomation=true"); fi
zig build "${BUILD_ARGS[@]}"
assert_arm64_only "$ROOT/zig-out/bin/friday"
npx native package --target macos --manifest app.json --output zig-out/package/Friday.app --binary zig-out/bin/friday --web-layer exclude --web-engine system

APP="$ROOT/zig-out/package/Friday.app"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
install_name_tool -delete_rpath "$ROOT/third_party/nemo-speech/lib" "$APP/Contents/MacOS/friday"
IDENTITY="${FRIDAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "Friday requires a real Apple signing identity because hardened runtime library validation must accept the embedded NeMo dylibs." >&2
  echo "Set FRIDAY_SIGN_IDENTITY to an Apple Development, Apple Distribution, or Developer ID Application identity hash." >&2
  exit 2
fi
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" "$APP/Contents/Info.plist"

mkdir -p "$FRAMEWORKS" "$RESOURCES/models" "$RESOURCES/licenses"
for library in \
  libnemo_speech_asr_c.1.dylib \
  libnemo_speech_asr.dylib \
  libggml.0.dylib \
  libggml-base.0.dylib \
  libggml-blas.0.dylib \
  libggml-cpu.0.dylib \
  libggml-metal.0.dylib; do
  assert_arm64_only "$ROOT/third_party/nemo-speech/lib/$library"
  ditto "$ROOT/third_party/nemo-speech/lib/$library" "$FRAMEWORKS/$library"
  assert_arm64_only "$FRAMEWORKS/$library"
done

ditto "$ROOT/resources/models/parakeet-tdt-0.6b-v3.json" "$RESOURCES/models/parakeet-tdt-0.6b-v3.json"
ditto "$ROOT/third_party/nemo-speech/share/licenses/nemo-speech" "$RESOURCES/licenses/nemo-speech"

# The Native SDK packager emits unsigned-scaffold notes before Friday applies
# its own hardened-runtime signature. Replace them before signing so the
# shipped bundle never contradicts its actual trust state.
cat >"$RESOURCES/README.txt" <<'EOF'
Friday macOS application bundle.
The bundle and embedded libraries are externally team-signed with hardened runtime.
Use codesign --verify --deep --strict to inspect this artifact.
Notarization is performed only by scripts/release-macos.sh.
EOF
cat >"$RESOURCES/signing-plan.txt" <<'EOF'
signing=external-team
hardened-runtime=enabled
library-validation=enabled
notarization=release-script-only
EOF
cat >"$RESOURCES/package-manifest.zon" <<EOF
.{
  .artifact = "Friday.app",
  .target = "aarch64-macos",
  .version = "$VERSION",
  .app_id = "com.phall.friday",
  .executable = "friday",
  .optimize = "ReleaseFast",
  .web_layer = "none",
  .signing = "external-team",
  .hardened_runtime = true,
  .library_validation = true,
}
EOF

SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
for library in "$FRAMEWORKS"/*.dylib; do
  codesign "${SIGN_ARGS[@]}" "$library"
done
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/resources/Friday.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
assert_arm64_only "$APP/Contents/MacOS/friday"
for library in "$FRAMEWORKS"/*.dylib; do assert_arm64_only "$library"; done
PLIST="$APP/Contents/Info.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")" != "Friday" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" != "$VERSION" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" != "$VERSION" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST")" != "true" ]]; then
  echo "Friday bundle metadata assertion failed." >&2
  exit 2
fi
RPATHS="$(otool -l "$APP/Contents/MacOS/friday" | awk '/LC_RPATH/{getline; getline; print $2}')"
if [[ "$RPATHS" != "@executable_path/../Frameworks" ]]; then
  echo "Friday release rpath assertion failed: $RPATHS" >&2
  exit 2
fi
MACH_HEADER="$(otool -hv "$APP/Contents/MacOS/friday")"
if [[ "$MACH_HEADER" != *"ARM64"* ]]; then
  echo "Friday otool assertion failed: main executable is not ARM64." >&2
  exit 2
fi

DMG="$ROOT/zig-out/package/Friday-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname Friday -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
printf 'Packaged %s\nSigned with %s\nArchitecture arm64 (Rosetta translated=%s)\nDisk image %s\n' "$APP" "$IDENTITY" "$TRANSLATED" "$DMG"
