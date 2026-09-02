#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FRIDAY_APP_BINARY:-$ROOT/zig-out/package/Friday.app/Contents/MacOS/friday}"
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

NO_ELLIPSIS=()
case "$SCENE" in
  onboarding-*) REQUIRED=('STEP 2 / 4' 'role=button name="Open Accessibility"' 'role=button name="Open Input Monitoring"' 'role=button name="Continue"' 'Hear the shortcut while another app is focused.' 'This page refreshes automatically.'); NO_ELLIPSIS=('Hear the shortcut while another app is focu…') ;;
  settings-*) REQUIRED=('role=button name="Start Recording"' 'role=button name="Check Microphone"' 'role=text name="Default microphone"' 'role=switch name="Double-tap to lock recording"' 'role=switch name="Launch at Login"'); NO_ELLIPSIS=('Default microph…') ;;
  model-*) REQUIRED=('role=text name="Model Manager"' 'role=button name="Add Local Model…"' 'role=textbox name="Hugging Face model identifier"' 'role=button name="Resolve Candidate Metadata"') ;;
  error-*) REQUIRED=('Friday needs attention' 'Model: Parakeet TDT 0.6B v3' 'role=button name="Retry Transcription"' 'role=button name="Change Model"') ;;
  recording-*) REQUIRED=('role=text name="recording"' 'role=button name="Stop Recording"' 'role=button name="Cancel"') ;;
  transcribing-*) REQUIRED=('role=text name="transcribing"' 'role=button name="Cancel"' 'Transcribing locally') ;;
  overlay-preview-*) REQUIRED=('Recording capsule preview' 'role=button name="Stop"' 'role=button name="Hide"' 'role=button name="Cancel"') ;;
  accessibility-*) REQUIRED=('role=text name="PERMISSION STATUS"' 'role=text name="Microphone"' 'role=text name="Accessibility"' 'role=text name="Input Monitoring"' 'role=button name="Recover Paste Access"' 'Accessibility missing'); NO_ELLIPSIS=('Accessibilit…' 'Input Monitor…') ;;
  unsupported-intel-*) REQUIRED=('Friday needs Apple Silicon' 'Friday requires an Apple Silicon Mac.' 'Detected x86_64 · macOS 14.0' 'Setup, model downloads, and recording are disabled'); NO_ELLIPSIS=('Friday needs Apple…') ;;
  hotkey-conflict-*) REQUIRED=('You pressed: Command' 'That shortcut is reserved by macOS or a standard app command. Choose another shortcut.' 'role=button name="Use This Shortcut"' 'role=button name="Try Something Else"'); NO_ELLIPSIS=('That shortcut is reserved by macOS or a standard app command. Choose another short…') ;;
  resume-*) REQUIRED=('STEP 4 / 4' 'Install the voice engine' 'Parakeet runs final transcription on this Mac. The verified download is about 714 MB.' 'A verified partial is ready.' '321,000,000 / 713,975,456 bytes downloaded' 'role=button name="Resume Download"'); NO_ELLIPSIS=('Install the voice engi…' 'Parakeet runs final transcription on this Mac. The verified download is about…') ;;
  hf-confirmation-*) REQUIRED=('role=text name="Model Manager"' 'UNVERIFIED CANDIDATE' 'community/parakeet-tdt-gguf' 'Hugging Face · CC-BY-4.0 · 702 MB' 'REV 0123456789abcdef0123456789abcdef01234567' 'Artifact parakeet-tdt-q8.gguf' 'Download to verify locally.' 'role=switch name="Authorize this exact download for local verification"' 'role=button name="Download to Verify Locally"'); NO_ELLIPSIS=('UNVERIFIED CANDID…' 'Download to verify local…') ;;
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
if [[ "${#NO_ELLIPSIS[@]}" -gt 0 ]]; then "$CLI" automate assert --absent "${NO_ELLIPSIS[@]}"; fi
"$CLI" automate screenshot main-canvas
"$CLI" automate widget-key main-canvas tab
"$CLI" automate assert 'focused=true'
"$CLI" automate widget-key main-canvas shift+tab
"$CLI" automate assert 'focused=true'

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
