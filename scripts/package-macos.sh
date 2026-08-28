#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_ARGS=()
if [[ "${FRIDAY_AUTOMATION:-0}" == "1" ]]; then BUILD_ARGS+=("-Dautomation=true"); fi
zig build "${BUILD_ARGS[@]}"
npx native package --target macos --manifest app.json --output zig-out/package/friday.app --binary zig-out/bin/friday --web-layer exclude --web-engine system

APP="$ROOT/zig-out/package/friday.app"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
IDENTITY="${FRIDAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/\"Apple Development:/{print $2; exit}')}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "Friday requires a real Apple signing identity because hardened runtime library validation must accept the embedded NeMo dylibs." >&2
  echo "Set FRIDAY_SIGN_IDENTITY to an Apple Development, Apple Distribution, or Developer ID Application identity hash." >&2
  exit 2
fi

mkdir -p "$FRAMEWORKS" "$RESOURCES/models" "$RESOURCES/licenses"
for library in \
  libnemo_speech_asr_c.1.dylib \
  libnemo_speech_asr.dylib \
  libggml.0.dylib \
  libggml-base.0.dylib \
  libggml-blas.0.dylib \
  libggml-cpu.0.dylib \
  libggml-metal.0.dylib; do
  ditto "$ROOT/third_party/nemo-speech/lib/$library" "$FRAMEWORKS/$library"
done

ditto "$ROOT/resources/models/parakeet-tdt-0.6b-v3.json" "$RESOURCES/models/parakeet-tdt-0.6b-v3.json"
ditto "$ROOT/third_party/nemo-speech/share/licenses/nemo-speech" "$RESOURCES/licenses/nemo-speech"

SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
for library in "$FRAMEWORKS"/*.dylib; do
  codesign "${SIGN_ARGS[@]}" "$library"
done
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/resources/Friday.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

DMG="$ROOT/zig-out/package/Friday-0.1.0.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname Friday -srcfolder "$APP" -ov -format UDZO "$DMG"
printf 'Packaged %s\nSigned with %s\nDisk image %s\n' "$APP" "$IDENTITY" "$DMG"
