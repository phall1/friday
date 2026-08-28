#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/zig-out/package/friday.app/Contents/MacOS/friday"
CLI="$ROOT/node_modules/.bin/native"
SCENE="${1:?usage: tests/ui-automation.sh <onboarding|settings|model|error|recording|transcribing>-<light|dark>}"
OUT="$ROOT/tests/screenshots/$SCENE.png"

case "$SCENE" in
  onboarding-*) REQUIRED=("Step 2 of 4" "Grant Accessibility" "Grant Input Monitoring") ;;
  settings-*) REQUIRED=("Dictation" "Check Microphone" "Launch at Login") ;;
  model-*) REQUIRED=("Model Manager" "Parakeet TDT 0.6B v3" "Add Local GGUF") ;;
  error-*) REQUIRED=("Friday needs attention" "Retry Transcription" "Change Model") ;;
  recording-*) REQUIRED=("recording" "Stop Recording" "Cancel") ;;
  transcribing-*) REQUIRED=("transcribing" "Cancel" "Transcribing locally") ;;
  *) echo "unknown scene: $SCENE" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/tests/screenshots"
FRIDAY_AUTOMATION_SCENE="$SCENE" "$APP" >"${TMPDIR:-/tmp}/friday-ui-$SCENE.log" 2>&1 &
PID=$!
cleanup() {
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap cleanup EXIT
cd "$ROOT"
"$CLI" automate wait
"$CLI" automate assert "${REQUIRED[@]}"
"$CLI" automate assert --absent 'error event='
"$CLI" automate screenshot main-canvas
cp "$ROOT/.zig-cache/native-sdk-automation/screenshot-main-canvas.png" "$OUT"
printf 'Captured %s\n' "$OUT"
