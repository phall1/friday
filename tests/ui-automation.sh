#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/zig-out/package/friday.app/Contents/MacOS/friday"
CLI="$ROOT/node_modules/.bin/native"
UPDATE=0
if [[ "${1:-}" == "--update" ]]; then UPDATE=1; shift; fi
SCENE="${1:?usage: tests/ui-automation.sh [--update] <onboarding|settings|model|error|recording|transcribing|overlay-preview|accessibility|unsupported-intel|hotkey-conflict|resume|hf-confirmation>-<light|dark>}"
GOLDEN="$ROOT/tests/screenshots/$SCENE.png"
CAPTURE="$ROOT/.zig-cache/native-sdk-automation/screenshot-main-canvas.png"
WINDOW_STATE="$HOME/Library/Application Support/com.phall.friday/State/windows.zon"
WINDOW_BACKUP="$(mktemp "${TMPDIR:-/tmp}/friday-window-state.XXXXXX")"
HAD_WINDOW_STATE=0

case "$SCENE" in
  onboarding-*) REQUIRED=('Step 2 of 4' 'role=button name="Grant Accessibility"' 'role=button name="Grant Input Monitoring"' 'role=button name="Continue"') ;;
  settings-*) REQUIRED=('role=button name="Start Recording"' 'role=button name="Check Microphone"' 'role=switch name="Double-tap to lock recording"' 'role=switch name="Launch at Login"') ;;
  model-*) REQUIRED=('role=text name="Model Manager"' 'role=button name="Add Local Model…"' 'role=textbox name="Hugging Face model identifier"' 'role=button name="Resolve Compatible Model"') ;;
  error-*) REQUIRED=('Friday needs attention' 'Model: Parakeet TDT 0.6B v3' 'role=button name="Retry Transcription"' 'role=button name="Change Model"') ;;
  recording-*) REQUIRED=('role=text name="recording"' 'role=button name="Stop Recording"' 'role=button name="Cancel"') ;;
  transcribing-*) REQUIRED=('role=text name="transcribing"' 'role=button name="Cancel"' 'Transcribing locally') ;;
  overlay-preview-*) REQUIRED=('Recording capsule preview' 'role=button name="Stop"' 'role=button name="Hide Capsule"' 'role=button name="Cancel"') ;;
  accessibility-*) REQUIRED=('role=text name="Permission Status"' 'role=button name="Recover Paste Access"' 'Accessibility missing') ;;
  unsupported-intel-*) REQUIRED=('Friday can’t run on this Mac' 'Friday requires an Apple Silicon Mac.' 'Detected x86_64 · macOS 14.0' 'Setup, model downloads, and recording are disabled') ;;
  hotkey-conflict-*) REQUIRED=('Candidate: Command' 'That shortcut is reserved by macOS' 'role=button name="Save This Shortcut"' 'role=button name="Discard Candidate"') ;;
  resume-*) REQUIRED=('Step 4 of 4' 'A verified partial download is ready to resume.' '321,000,000 of 713,975,456 bytes downloaded' 'role=button name="Resume Download"') ;;
  hf-confirmation-*) REQUIRED=('role=text name="Model Manager"' 'community/parakeet-tdt-gguf' 'Revision 0123456789abcdef0123456789abcdef01234567' 'Artifact parakeet-tdt-q8.gguf' 'role=button name="Download Confirmed Model"') ;;
  *) echo "unknown scene: $SCENE" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/tests/screenshots"
if [[ -f "$WINDOW_STATE" ]]; then
  mv "$WINDOW_STATE" "$WINDOW_BACKUP"
  HAD_WINDOW_STATE=1
fi
FRIDAY_AUTOMATION_SCENE="$SCENE" "$APP" >"${TMPDIR:-/tmp}/friday-ui-$SCENE.log" 2>&1 &
PID=$!
cleanup() {
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -f "$WINDOW_STATE"
  if [[ "$HAD_WINDOW_STATE" == "1" ]]; then
    mkdir -p "$(dirname "$WINDOW_STATE")"
    mv "$WINDOW_BACKUP" "$WINDOW_STATE"
  else
    rm -f "$WINDOW_BACKUP"
  fi
}
trap cleanup EXIT
cd "$ROOT"
"$CLI" automate wait
"$CLI" automate assert 'window @w1 "Friday" bounds=.* 760x620' "${REQUIRED[@]}"
"$CLI" automate assert --absent 'error event='
"$CLI" automate widget-key main-canvas tab
"$CLI" automate assert 'focused=true'
"$CLI" automate widget-key main-canvas shift+tab
"$CLI" automate assert 'focused=true'
"$CLI" automate screenshot main-canvas

if [[ "$UPDATE" == "1" ]]; then
  cp "$CAPTURE" "$GOLDEN"
  printf 'Updated %s\n' "$GOLDEN"
elif [[ ! -f "$GOLDEN" ]]; then
  echo "missing golden: $GOLDEN (run with --update)" >&2
  exit 1
elif ! cmp -s "$CAPTURE" "$GOLDEN"; then
  echo "golden mismatch for $SCENE (run with --update only after visual review)" >&2
  sha256sum "$CAPTURE" "$GOLDEN" >&2
  exit 1
else
  printf 'Golden matched %s\n' "$GOLDEN"
fi
