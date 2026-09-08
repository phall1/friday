#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FRIDAY_APP_BINARY:-$ROOT/zig-out/package/Friday.app/Contents/MacOS/friday}"
CLI="${FRIDAY_NATIVE_CLI:-$ROOT/node_modules/.bin/native}"
UPDATE=0
if [[ "${1:-}" == "--update" ]]; then UPDATE=1; shift; fi
SCENE="${1:?usage: tests/ui-automation.sh [--update] <onboarding|settings|model|error|recording|transcribing|overlay-preview|accessibility|unsupported-intel|hotkey-conflict|resume|hf-confirmation>-<light|dark>}"
CAPTURE="$ROOT/.zig-cache/native-sdk-automation/screenshot-main-canvas.png"
RESULTS="$ROOT/.zig-cache/ui-results/$SCENE"
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
  onboarding-*) REQUIRED=('STEP 2 / 4' 'role=button name="Open Accessibility"' 'role=button name="Open Input Monitoring"' 'role=button name="Continue"' 'Hear the shortcut while another app is focused.' 'Status refreshes automatically.'); NO_ELLIPSIS=('Hear the shortcut while another app is focu…') ;;
  settings-*) REQUIRED=('role=button name="Start Recording"' 'role=button name="Check Microphone"' 'role=text name="Default microphone"' 'role=switch name="Double-tap to lock recording"' 'role=switch name="Launch at Login"'); NO_ELLIPSIS=('Default microph…') ;;
  model-*) REQUIRED=('role=treeitem name="Models"' 'role=text name="Local models"' 'Friday’s reviewed production allowlist' 'role=button name="Add Local Model…"' 'role=button name="Use Parakeet CTC repository"' 'role=textbox name="Hugging Face model identifier"' 'role=button name="Inspect Candidate Metadata"') ;;
  error-*) REQUIRED=('attention required' 'Model: Parakeet TDT 0.6B v3' 'role=button name="Retry Transcription"' 'role=button name="Change Model"') ;;
  recording-*) REQUIRED=('role=text name="recording"' 'role=button name="Stop Recording"' 'role=button name="Cancel"' 'role=slider name="Tap interval, 300 milliseconds. Range 200 to 500 milliseconds".*enabled=false' 'role=switch name="Double-tap to lock recording".*enabled=false') ;;
  transcribing-*) REQUIRED=('role=text name="transcribing"' 'role=button name="Cancel"' 'Transcribing locally') ;;
  overlay-preview-*) REQUIRED=('Recording capsule preview' 'role=button name="Stop"' 'role=button name="Hide"' 'role=button name="Cancel"') ;;
  accessibility-*) REQUIRED=('role=treeitem name="Access"' 'role=text name="Permissions"' 'role=text name="Microphone"' 'role=text name="Accessibility"' 'role=text name="Input Monitoring"' 'role=button name="Recover Paste Access"' 'Accessibility missing'); NO_ELLIPSIS=('Accessibilit…' 'Input Monitor…') ;;
  unsupported-intel-*) REQUIRED=('Apple Silicon required' 'Friday requires an Apple Silicon Mac.' 'Architecture' 'x86_64' 'macOS 14.0' 'Setup, model downloads, and recording are disabled'); NO_ELLIPSIS=('Apple Silicon requir…') ;;
  hotkey-conflict-*) REQUIRED=('You pressed: Command' 'That shortcut is reserved by macOS or a standard app command. Choose another shortcut.' 'role=button name="Use This Shortcut"' 'role=button name="Try Something Else"'); NO_ELLIPSIS=('That shortcut is reserved by macOS or a standard app command. Choose another short…') ;;
  resume-*) REQUIRED=('STEP 4 / 4' 'Run the model here.' 'Parakeet turns speech into final text on this Mac. The verified download is about 714 MB.' 'A verified partial is ready.' '321,000,000 / 713,975,456 bytes downloaded' 'role=button name="Resume Download"'); NO_ELLIPSIS=('Run the model he…' 'Parakeet turns speech into final text on this Mac. The verified download is about…') ;;
  hf-confirmation-*) REQUIRED=('role=treeitem name="Models"' 'role=text name="Local models"' 'unverified candidate' 'community/parakeet-tdt-gguf' 'CC-BY-4.0 · 702 MB' 'rev 0123456789abcdef0123456789abcdef01234567' 'Artifact parakeet-tdt-q8.gguf' 'Metadata only.' 'will not download, parse, runtime-probe, recognize with, or activate' 'role=button name="Choose Another Repository"'); NO_ELLIPSIS=('unverified candid…' 'Metadata only…') ;;
  *) echo "unknown scene: $SCENE" >&2; exit 2 ;;
esac

PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    # Keep fixture evidence per scene, including failed assertions, for CI review.
    if [[ -f "$CAPTURE" ]]; then cp "$CAPTURE" "$RESULTS/actual.png" || true; fi
    if [[ -f "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt" ]]; then
      cp "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt" "$RESULTS/snapshot.txt" || true
    fi
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
mkdir -p "$RESULTS"
rm -f "$CAPTURE" "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt" \
  "$RESULTS/actual.png" "$RESULTS/expected.png" "$RESULTS/snapshot.txt" "$RESULTS/capture.txt"
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
FRIDAY_AUTOMATION_SCENE="$SCENE" "$APP" >"$RESULTS/app.log" 2>&1 &
PID=$!
cd "$ROOT"
"$CLI" automate wait >/dev/null
# Native pixel snapping follows the attached display even though the software
# screenshot is always 640x480. Never compare a 1x runner with a Retina golden.
DISPLAY_SCALE="$(sed -n 's/^ *view @w1\/main-canvas .* gpu_scale=\([^ ]*\) .*/\1/p' "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt")"
case "$DISPLAY_SCALE" in
  1|2) GOLDEN="$ROOT/tests/screenshots/${DISPLAY_SCALE}x/$SCENE.png" ;;
  *) echo "unsupported or missing main-canvas display scale: $DISPLAY_SCALE" >&2; exit 2 ;;
esac
printf 'display_scale=%s\ngolden=%s\n' "$DISPLAY_SCALE" "${GOLDEN#"$ROOT/"}" >"$RESULTS/capture.txt"
if [[ -f "$GOLDEN" ]]; then cp "$GOLDEN" "$RESULTS/expected.png"; fi
"$CLI" automate assert 'window @w1 "Friday" bounds=.* 640x480' "${REQUIRED[@]}"
"$CLI" automate assert --absent 'error event='
if [[ "${#NO_ELLIPSIS[@]}" -gt 0 ]]; then "$CLI" automate assert --absent "${NO_ELLIPSIS[@]}"; fi
if [[ "$SCENE" == settings-result-* ]]; then
  "$CLI" automate assert 'Copied to clipboard\. Paste your words with Command \+ V\.' 'role=button name="Dismiss"'
fi
# Presence in the accessibility tree does not prove a control is visible.
# The old goldens passed while half of Controls sat below the viewport.
if [[ "$SCENE" == settings-* || "$SCENE" == onboarding-* ]]; then
  node - "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt" "$SCENE" <<'NODE'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const snapshot = fs.readFileSync(process.argv[2], 'utf8');
const controls = process.argv[3].startsWith('onboarding-')
  ? ['Open Accessibility', 'Open Input Monitoring', 'Use limited mode', 'Continue', 'Back']
  : ['Controls', 'Models', 'Access', 'Diagnostics', 'Start Recording', 'Check Microphone', 'Change Shortcut…',
   'Double-tap to lock recording', 'Tap interval, 300 milliseconds. Range 200 to 500 milliseconds',
  'Paste automatically', 'Show capsule', 'Launch at Login'];
if (process.argv[3].startsWith('settings-result-')) controls.push('Dismiss');
for (const name of controls) {
  const row = snapshot.split('\n').find(line => line.includes(`name="${name}"`) && /role=(button|switch|treeitem|slider) /.test(line));
  assert.ok(row, `Missing control: ${name}`);
  const bounds = row.match(/bounds=\(([-\d.]+),([-\d.]+) ([-\d.]+)x([-\d.]+)\)/);
  assert.ok(bounds, `Missing bounds: ${name}`);
  const [x, y, width, height] = bounds.slice(1).map(Number);
  assert.ok(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 640.5 && y + height <= 480,
    `${name} is clipped: ${bounds[0]}`);
}
for (const match of snapshot.matchAll(/scroll=\[offset=([\d.]+),viewport=([\d.]+),content=([\d.]+)\]/g)) {
  assert.equal(Number(match[1]), 0, 'The surface must start at the top');
  assert.ok(Number(match[3]) <= Number(match[2]), `Unexpected scrolling: ${match[0]}`);
}
console.log(`${process.argv[3]} geometry passed: all expected controls visible; no scrolling.`);
NODE
fi
"$CLI" automate screenshot main-canvas
"$CLI" automate widget-key main-canvas tab
"$CLI" automate assert 'focused=true'

if [[ "$SCENE" == hotkey-conflict-* ]]; then
  # AppKit suppresses widget focused=true when this harness has no active OS
  # window, even with retained canvas focus. Never mistake view focus for it.
  if grep -Eq '^window .*focused=true' "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt"; then
    "$CLI" automate assert 'widget .*role=button name="(Command \+ Shift|Control \+ Option|Try Something Else)".*focused=true'
  fi
  "$CLI" automate widget-key main-canvas escape
  "$CLI" automate assert --absent 'role=dialog' 'You pressed:'
  "$CLI" automate assert 'role=button name="Change Shortcut…"' 'role=text name="Command \+ Shift"'
fi
"$CLI" automate widget-key main-canvas shift+tab
"$CLI" automate assert 'focused=true'

if [[ "$SCENE" == settings-dark ]]; then
  # The navigation tree uses native activation and arrow-key selection.
  for section in Models Access Diagnostics Controls; do
    id="$(sed -n "s/.*widget @w1\/main-canvas#\([0-9]*\) role=treeitem name=\"$section\".*/\1/p" "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt")"
    "$CLI" automate widget-action main-canvas "$id" press
    "$CLI" automate assert "role=treeitem name=\"$section\".*state=\[[^]]*selected"
    case "$section" in
      Models) "$CLI" automate assert 'role=text name="Local models"' ;;
      Access) "$CLI" automate assert 'role=text name="Permissions"' ;;
      Diagnostics) "$CLI" automate assert 'role=text name="Safe diagnostics"' ;;
      Controls) "$CLI" automate assert 'role=switch name="Launch at Login"' ;;
    esac
  done
  "$CLI" automate widget-key main-canvas arrowdown
  "$CLI" automate assert 'role=treeitem name="Models".*state=\[[^]]*selected' 'role=text name="Local models"'
  "$CLI" automate tray-action 20
  slider_id="$(sed -n 's/.*widget @w1\/main-canvas#\([0-9]*\) role=slider name="Tap interval, [^"]*".*/\1/p' "$ROOT/.zig-cache/native-sdk-automation/snapshot.txt")"
  "$CLI" automate widget-drag main-canvas "$slider_id" 0.3333 0.8
  "$CLI" automate assert 'role=text name="440 ms"' 'role=text name="Ready when you are\."' 'role=slider name="Tap interval, 440 milliseconds. Range 200 to 500 milliseconds"'
  "$CLI" automate widget-action main-canvas "$slider_id" focus
  "$CLI" automate widget-key main-canvas home
  "$CLI" automate assert 'role=text name="200 ms"'
  "$CLI" automate widget-key main-canvas arrowright
  "$CLI" automate assert 'role=text name="220 ms"'
  "$CLI" automate widget-key main-canvas end
  "$CLI" automate assert 'role=text name="500 ms"'
fi

if [[ "$UPDATE" == "1" ]]; then
  mkdir -p "$(dirname "$GOLDEN")"
  cp "$CAPTURE" "$GOLDEN"
  printf 'Updated %s\n' "$GOLDEN"
elif [[ ! -f "$GOLDEN" ]]; then
  echo "missing golden: $GOLDEN (run with --update)" >&2
  exit 1
elif ! cmp -s "$CAPTURE" "$GOLDEN"; then
  echo "golden mismatch for $SCENE at ${DISPLAY_SCALE}x (run with --update only after visual review)" >&2
  shasum -a 256 "$CAPTURE" "$GOLDEN" >&2
  exit 1
else
  printf 'Golden matched %s\n' "$GOLDEN"
fi
