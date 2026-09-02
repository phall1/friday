#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FRIDAY_E2E_APP_BINARY:-$ROOT/zig-out/package/Friday.app/Contents/MacOS/friday}"
CLI="${FRIDAY_NATIVE_CLI:-$ROOT/node_modules/.bin/native}"
SUPPORT_ROOT="$HOME/Library/Application Support/com.phall.friday"
STATE_DIR="$SUPPORT_ROOT/State"
SNAPSHOT="$SUPPORT_ROOT/snapshot.nsd"
SNAPSHOT_BAK="$SUPPORT_ROOT/snapshot.nsd.bak"
DOWNLOADS="$SUPPORT_ROOT/ModelDownloads"
INDEX="$SUPPORT_ROOT/Models/index.json"
if [[ "$(uname -m)" != "arm64" || "$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')" == "1" ]]; then
  echo "Packaged E2E Zig helpers require native arm64 macOS; Intel and Rosetta are unsupported." >&2
  exit 2
fi
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/friday-e2e.XXXXXX")"
BACKUP="$WORK/backup"
RUN_TMP="$WORK/tmp"
LOG="$WORK/friday.log"
PID=""
MANAGED_STATE=0
mkdir -p "$BACKUP" "$RUN_TMP"

if [[ ! -x "$APP" ]]; then
  echo "Packaged E2E requires an automation-enabled Friday binary at $APP" >&2
  exit 2
fi
if [[ ! -f "$INDEX" ]]; then
  echo "Packaged E2E requires an installed active model; no model index was found." >&2
  exit 2
fi
if pgrep -x friday >/dev/null; then
  echo "Friday is already running; close it before packaged E2E so state cannot race the harness." >&2
  exit 2
fi

zig build-exe -target aarch64-macos "$ROOT/tests/PasteboardSnapshot.zig" \
  -F "$MACOS_SDK/System/Library/Frameworks" \
  -F "$MACOS_SDK/System/Library/Frameworks/ApplicationServices.framework/Frameworks" \
  -L "$MACOS_SDK/usr/lib" \
  -framework ApplicationServices -framework CoreFoundation -lc -O ReleaseSafe \
  -femit-bin="$WORK/pasteboard-snapshot"
zig build-exe -target aarch64-macos "$ROOT/tests/CGPost.zig" \
  -F "$MACOS_SDK/System/Library/Frameworks" \
  -L "$MACOS_SDK/usr/lib" \
  -framework CoreGraphics -framework CoreFoundation -lc -O ReleaseSafe \
  -femit-bin="$WORK/cg-post"
HELPER_IDENTITY="${FRIDAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/\"Apple Development:/{print $2; exit}')}"
if [[ -z "$HELPER_IDENTITY" ]]; then echo "Packaged E2E requires the package team signing identity for the external CGEvent helper." >&2; exit 2; fi
codesign --force --identifier com.phall.friday --sign "$HELPER_IDENTITY" "$WORK/cg-post" >/dev/null
"$WORK/pasteboard-snapshot" save "$BACKUP/pasteboard.plist"

cleanup_process() {
  if [[ -n "$PID" ]]; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      if ! kill -0 "$PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then kill -KILL "$PID" 2>/dev/null || true; fi
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}
cleanup() {
  cleanup_process
  if [[ "$MANAGED_STATE" == "1" ]]; then
    rm -rf "$STATE_DIR" "$DOWNLOADS"
    rm -f "$SNAPSHOT" "$SNAPSHOT_BAK"
    mkdir -p "$SUPPORT_ROOT"
    if [[ -d "$BACKUP/State" ]]; then ditto "$BACKUP/State" "$STATE_DIR"; fi
    if [[ -d "$BACKUP/ModelDownloads" ]]; then ditto "$BACKUP/ModelDownloads" "$DOWNLOADS"; fi
    if [[ -f "$BACKUP/snapshot.nsd" ]]; then cp "$BACKUP/snapshot.nsd" "$SNAPSHOT"; fi
    if [[ -f "$BACKUP/snapshot.nsd.bak" ]]; then cp "$BACKUP/snapshot.nsd.bak" "$SNAPSHOT_BAK"; fi
    if [[ -f "$BACKUP/index.json" ]]; then cp "$BACKUP/index.json" "$INDEX"; fi
  fi
  "$WORK/pasteboard-snapshot" restore "$BACKUP/pasteboard.plist" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -d "$STATE_DIR" ]]; then ditto "$STATE_DIR" "$BACKUP/State"; fi
if [[ -d "$DOWNLOADS" ]]; then ditto "$DOWNLOADS" "$BACKUP/ModelDownloads"; fi
if [[ -f "$SNAPSHOT" ]]; then cp "$SNAPSHOT" "$BACKUP/snapshot.nsd"; fi
if [[ -f "$SNAPSHOT_BAK" ]]; then cp "$SNAPSHOT_BAK" "$BACKUP/snapshot.nsd.bak"; fi
cp "$INDEX" "$BACKUP/index.json"
MODEL_PATH="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); k=d.get("activeModelKey"); print(next((m.get("path", "") for m in d.get("models", []) if m.get("modelKey")==k), ""))' "$INDEX")"
if [[ -z "$MODEL_PATH" || ! -f "$MODEL_PATH" ]]; then
  echo "Packaged E2E requires the active model artifact referenced by the index." >&2
  exit 2
fi
MODEL_SHA_BEFORE="$(shasum -a 256 "$MODEL_PATH" | cut -d ' ' -f 1)"
MANAGED_STATE=1
rm -rf "$STATE_DIR" "$DOWNLOADS"
rm -f "$SNAPSHOT" "$SNAPSHOT_BAK"
mkdir -p "$DOWNLOADS"

snapshot_file="$ROOT/.zig-cache/native-sdk-automation/snapshot.txt"
widget_id() {
  local role="$1"
  local name="$2"
  sed -n "s/.*#\([0-9][0-9]*\) role=$role name=\"$name\".*/\1/p" "$snapshot_file" | sed -n '1p'
}
launch_scene() {
  local scene="$1"
  shift
  cleanup_process
  rm -rf "$ROOT/.zig-cache/native-sdk-automation"
  env TMPDIR="$RUN_TMP" FRIDAY_AUTOMATION_SCENE="$scene" "$@" "$APP" >"$LOG" 2>&1 &
  PID=$!
  "$CLI" automate wait >/dev/null
  "$CLI" automate assert --absent 'error event=' >/dev/null
}

# Fresh setup/recovery surfaces through the signed package.
for scene in onboarding-light unsupported-intel-light hotkey-conflict-light resume-light hf-confirmation-dark; do
  FRIDAY_APP_BINARY="$APP" FRIDAY_NATIVE_CLI="$CLI" "$ROOT/tests/ui-automation.sh" "$scene" >/dev/null
done

# The process owns a live menu-only status item, and its explicit Open Friday
# row routes the app window back to the settings page.
launch_scene model-light
"$CLI" automate assert 'role=text name="Models"' >/dev/null
"$CLI" automate tray-action 20 >/dev/null
"$CLI" automate assert 'role=button name="Check Microphone"' 'role=switch name="Launch at Login"' >/dev/null

# Manual real-microphone capture, drain, observable transcribing, silence result,
# and temp-audio deletion.
launch_scene settings-light
"$CLI" automate tray-action 10 >/dev/null
"$CLI" automate assert 'role=text name="recording"' 'role=button name="Stop Recording"' >/dev/null
sleep 0.4
"$CLI" automate tray-action 11 >/dev/null
"$CLI" automate assert 'role=text name="transcribing"' 'Transcribing locally with the active Parakeet model.' >/dev/null
"$CLI" automate assert 'role=text name="ready"' >/dev/null
if compgen -G "$RUN_TMP/Friday/Audio/*" >/dev/null; then
  echo "Packaged E2E failed: completed microphone flow left temporary audio behind." >&2
  exit 1
fi

# The signed in-process probe drives real CGEvents through the production
# session event tap and proves modifier double-tap symmetry without changing
# TCC. A separate-process helper remains a required release check when the
# controlling GUI session grants that helper event-post authority.
launch_scene settings-light
probe_id="$(widget_id button 'Run Automation Hotkey Probe')"
"$CLI" automate widget-action main-canvas "$probe_id" press >/dev/null
"$CLI" automate assert 'role=text name="recording"' 'Locked recording' >/dev/null
"$CLI" automate tray-action 12 >/dev/null
"$CLI" automate assert 'role=text name="ready"' >/dev/null
if [[ "${FRIDAY_REQUIRE_EXTERNAL_HOTKEY:-0}" == "1" ]]; then
  "$WORK/cg-post" modifier-hold 56 command,shift 650 &
  helper_pid=$!
  sleep 0.2
  "$CLI" automate assert 'role=text name="recording"' >/dev/null
  wait "$helper_pid"
  "$CLI" automate assert 'role=text name="transcribing"' >/dev/null
  "$CLI" automate assert 'role=text name="ready"' >/dev/null
else
  echo "External CGEvent helper check not required in this run; set FRIDAY_REQUIRE_EXTERNAL_HOTKEY=1 in a trusted GUI session." >&2
fi

# Cancel/stale-generation recovery uses the same packaged command channel.
launch_scene transcribing-dark
"$CLI" automate tray-action 12 >/dev/null
"$CLI" automate assert 'role=text name="ready"' >/dev/null

# Packaged hermetic negative probes: integrity/SHA/manifest/HF rejection,
# resumable relaunch state, exact duration/drop bounds, route cleanup, and
# shortcut conflicts.
launch_scene settings-light FRIDAY_AUTOMATION_CONTRACTS=1
"$CLI" automate assert 'shaFailed' 'hfCandidateUnverified' 'hfMaliciousCandidateUnverified' 'hfMaliciousPublicationRejected' 'hfRuntimeProbeRequired' 'hfUnknownFamilyFallback' 'hfPrivateRejected' 'hfAmbiguousRejected' 'hfIncompatibleRejected' 'pendingResumeHydrated' 'durationSeconds' 'reasonMatched' 'droppedFrameFailure' 'processTranslated' >/dev/null

# Generate a private, disposable 16 kHz mono Float32 five-second fixture.
say -v Samantha -r 150 -o "$WORK/fixture.aiff" 'Friday local dictation works. Friday local dictation works.'
afconvert "$WORK/fixture.aiff" "$WORK/fixture.wav" -f WAVE -d LEI16@16000 -c 1
python3 -c 'import array,struct,sys,wave; w=wave.open(sys.argv[1],"rb"); a=array.array("h"); a.frombytes(w.readframes(w.getnframes())); a.byteswap() if sys.byteorder=="big" else None; n=80000; a=a[:n]; values=[x/32768.0 for x in a]+[0.0]*max(0,n-len(a)); open(sys.argv[2],"wb").write(struct.pack("<%sf"%n,*values[:n]))' "$WORK/fixture.wav" "$WORK/fixture.f32"

# Real packaged ASR and truthful clipboard fallback. Pasteboard contents are
# restored byte-for-byte by the trap.
launch_scene settings-light FRIDAY_AUTOMATION_FIXTURE="$WORK/fixture.f32"
"$CLI" automate assert 'clipboard' >/dev/null
if [[ -z "$(pbpaste)" ]]; then echo "Fixture ASR did not leave a clipboard fallback." >&2; exit 1; fi

# An installed verified model remains ready with network endpoints disabled.
launch_scene model-light HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY='*'
"$CLI" automate assert 'role=text name="ready"' 'role=text name="● active"' 'Hugging Face · managed by Friday' 'Parakeet TDT 0.6B v3' >/dev/null

# SMAppService cycle must restore its exact prior registration state.
launch_scene settings-light FRIDAY_AUTOMATION_LOGIN=cycle
"$CLI" automate assert 'restored' >/dev/null

# Diagnostics must expose safe facts and explicit exclusion flags only.
"$CLI" automate tray-action 20 >/dev/null
diag_id="$(widget_id button Diagnostics)"
"$CLI" automate widget-action main-canvas "$diag_id" press >/dev/null
"$CLI" automate assert 'role=text name="Diagnostics"' 'transcriptIncluded' 'audioIncluded' 'rawPathsIncluded' >/dev/null
"$CLI" automate assert --absent "$WORK/fixture.f32" 'Friday local dictation works' >/dev/null

# Cleanup runs against an isolated downloads directory and cannot touch Models.
cleanup_process
mkdir -p "$DOWNLOADS/e2e-invalid"
printf 'partial' >"$DOWNLOADS/e2e-invalid/download.partial"
printf '{"invalid":true}' >"$DOWNLOADS/e2e-invalid/resume.json"
launch_scene model-light
cleanup_id="$(widget_id button 'Clean Partial Downloads')"
"$CLI" automate widget-action main-canvas "$cleanup_id" press >/dev/null
"$CLI" automate assert 'Failed and partial downloads removed.' >/dev/null
if [[ -e "$DOWNLOADS/e2e-invalid" ]]; then echo "Model cleanup left the E2E partial behind." >&2; exit 1; fi

cleanup_process
MODEL_SHA_AFTER="$(shasum -a 256 "$MODEL_PATH" | cut -d ' ' -f 1)"
if [[ "$MODEL_SHA_BEFORE" != "$MODEL_SHA_AFTER" ]]; then
  echo "Packaged E2E failed: installed model bytes changed." >&2
  exit 1
fi
if compgen -G "$RUN_TMP/Friday/Audio/*" >/dev/null; then
  echo "Packaged E2E failed: temporary audio remained after all flows." >&2
  exit 1
fi
printf 'Packaged E2E passed: onboarding, manual/hotkey capture, transcribing, ASR fallback, stale/cancel, offline readiness, integrity/route/duration, login restore, redaction, and cleanup.\n'
