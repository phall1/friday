#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FRIDAY_APP_BINARY:-$ROOT/zig-out/package/friday.app/Contents/MacOS/friday}"
CLI="${FRIDAY_NATIVE_CLI:-$ROOT/node_modules/.bin/native}"
UPDATE=0
if [[ "${1:-}" == "--update" ]]; then UPDATE=1; shift; fi
SCENE="${1:?usage: tests/ui-automation.sh [--update] <onboarding|settings|model|error|recording|transcribing|overlay-preview|accessibility|unsupported-intel|hotkey-conflict|resume|hf-confirmation>-<light|dark>}"
GOLDEN="$ROOT/tests/screenshots/$SCENE.png"
CAPTURE="$ROOT/.zig-cache/native-sdk-automation/screenshot-main-canvas.png"
SUPPORT_ROOT="$HOME/Library/Application Support/com.phall.friday"
STATE_DIR="$SUPPORT_ROOT/State"
SNAPSHOT="$SUPPORT_ROOT/snapshot.nsd"
SNAPSHOT_BAK="$SUPPORT_ROOT/snapshot.nsd.bak"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/friday-ui-state.XXXXXX")"
HAD_STATE=0
HAD_SNAPSHOT=0
HAD_SNAPSHOT_BAK=0
MANAGED_STATE=0

case "$SCENE" in
  onboarding-*) REQUIRED=('STEP 2 / 4' 'role=button name="Grant Accessibility"' 'role=button name="Grant Input Monitoring"' 'role=button name="Continue"') ;;
  settings-*) REQUIRED=('role=button name="Start Recording"' 'role=button name="Check Microphone"' 'role=switch name="Double-tap to lock recording"' 'role=switch name="Launch at Login"') ;;
  model-*) REQUIRED=('role=text name="Model Manager"' 'role=button name="Add Local Model…"' 'role=textbox name="Hugging Face model identifier"' 'role=button name="Resolve Compatible Model"') ;;
  error-*) REQUIRED=('Friday needs attention' 'Model: Parakeet TDT 0.6B v3' 'role=button name="Retry Transcription"' 'role=button name="Change Model"') ;;
  recording-*) REQUIRED=('role=text name="recording"' 'role=button name="Stop Recording"' 'role=button name="Cancel"') ;;
  transcribing-*) REQUIRED=('role=text name="transcribing"' 'role=button name="Cancel"' 'Transcribing locally') ;;
  overlay-preview-*) REQUIRED=('Recording capsule preview' 'role=button name="Stop"' 'role=button name="Hide Capsule"' 'role=button name="Cancel"') ;;
  accessibility-*) REQUIRED=('role=text name="PERMISSION STATUS"' 'role=button name="Recover Paste Access"' 'Accessibility missing') ;;
  unsupported-intel-*) REQUIRED=('Friday can’t run on this Mac' 'Friday requires an Apple Silicon Mac.' 'Detected x86_64 · macOS 14.0' 'Setup, model downloads, and recording are disabled') ;;
  hotkey-conflict-*) REQUIRED=('Candidate: Command' 'That shortcut is reserved by macOS' 'role=button name="Save This Shortcut"' 'role=button name="Discard Candidate"') ;;
  resume-*) REQUIRED=('STEP 4 / 4' 'A verified partial is ready.' '321,000,000 / 713,975,456 bytes downloaded' 'role=button name="Resume Download"') ;;
  hf-confirmation-*) REQUIRED=('role=text name="Model Manager"' 'community/parakeet-tdt-gguf' 'REV 0123456789abcdef0123456789abcdef01234567' 'Artifact parakeet-tdt-q8.gguf' 'role=button name="Download Confirmed Model"') ;;
  *) echo "unknown scene: $SCENE" >&2; exit 2 ;;
esac

PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [[ "$MANAGED_STATE" == "1" ]]; then
    rm -rf "$STATE_DIR"
    rm -f "$SNAPSHOT" "$SNAPSHOT_BAK"
    if [[ "$HAD_STATE" == "1" ]]; then
      mkdir -p "$SUPPORT_ROOT"
      ditto "$BACKUP_ROOT/State" "$STATE_DIR"
    fi
    if [[ "$HAD_SNAPSHOT" == "1" ]]; then cp "$BACKUP_ROOT/snapshot.nsd" "$SNAPSHOT"; fi
    if [[ "$HAD_SNAPSHOT_BAK" == "1" ]]; then cp "$BACKUP_ROOT/snapshot.nsd.bak" "$SNAPSHOT_BAK"; fi
  fi
  rm -rf "$BACKUP_ROOT"
}
trap cleanup EXIT

if pgrep -x friday >/dev/null; then
  echo "Friday is already running; close it before UI automation so user state cannot race the harness." >&2
  exit 2
fi
mkdir -p "$ROOT/tests/screenshots"
if [[ -d "$STATE_DIR" ]]; then
  ditto "$STATE_DIR" "$BACKUP_ROOT/State"
  HAD_STATE=1
fi
if [[ -f "$SNAPSHOT" ]]; then
  cp "$SNAPSHOT" "$BACKUP_ROOT/snapshot.nsd"
  HAD_SNAPSHOT=1
fi
if [[ -f "$SNAPSHOT_BAK" ]]; then
  cp "$SNAPSHOT_BAK" "$BACKUP_ROOT/snapshot.nsd.bak"
  HAD_SNAPSHOT_BAK=1
fi
MANAGED_STATE=1
rm -rf "$STATE_DIR"
rm -f "$SNAPSHOT" "$SNAPSHOT_BAK"
FRIDAY_AUTOMATION_SCENE="$SCENE" "$APP" >"${TMPDIR:-/tmp}/friday-ui-$SCENE.log" 2>&1 &
PID=$!
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
