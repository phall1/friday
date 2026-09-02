#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${FRIDAY_PERF_APP_BINARY:-$ROOT/zig-out/package/Friday.app/Contents/MacOS/friday}"
CLI="${FRIDAY_NATIVE_CLI:-$ROOT/node_modules/.bin/native}"
SUPPORT_ROOT="$HOME/Library/Application Support/com.phall.friday"
STATE_DIR="$SUPPORT_ROOT/State"
SNAPSHOT="$SUPPORT_ROOT/snapshot.nsd"
SNAPSHOT_BAK="$SUPPORT_ROOT/snapshot.nsd.bak"
INDEX="$SUPPORT_ROOT/Models/index.json"
if [[ "$(uname -m)" != "arm64" || "$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')" == "1" ]]; then
  echo "Performance Zig helpers require native arm64 macOS; Intel and Rosetta are unsupported." >&2
  exit 2
fi
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/friday-performance.XXXXXX")"
BACKUP="$WORK/backup"
RUN_TMP="$WORK/tmp"
RAW_FIXTURE="$WORK/fixture-performance.json"
RAW_METRICS="$WORK/host-performance.json"
PROFILE="$WORK/ui-profile.txt"
PID=""
MANAGED_STATE=0
ITERATIONS="${FRIDAY_PERF_ITERATIONS:-20}"
mkdir -p "$BACKUP" "$RUN_TMP"

if [[ ! "$ITERATIONS" =~ ^[0-9]+$ || "$ITERATIONS" -lt 20 || "$ITERATIONS" -gt 50 ]]; then
  echo "FRIDAY_PERF_ITERATIONS must be an integer from 20 through 50." >&2
  exit 2
fi
if [[ ! -x "$APP" || ! -f "$INDEX" ]]; then
  echo "Performance requires an automation-enabled package and an installed active model." >&2
  exit 2
fi
if pgrep -x friday >/dev/null; then
  echo "Friday is already running; close it before performance measurement." >&2
  exit 2
fi

zig build-exe -target aarch64-macos "$ROOT/tests/PasteboardSnapshot.zig" \
  -F "$MACOS_SDK/System/Library/Frameworks" \
  -F "$MACOS_SDK/System/Library/Frameworks/ApplicationServices.framework/Frameworks" \
  -L "$MACOS_SDK/usr/lib" \
  -framework ApplicationServices -framework CoreFoundation -lc -O ReleaseSafe \
  -femit-bin="$WORK/pasteboard-snapshot"
"$WORK/pasteboard-snapshot" save "$BACKUP/pasteboard.plist"
stop_process() {
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
  stop_process
  if [[ "$MANAGED_STATE" == "1" ]]; then
    rm -rf "$STATE_DIR"
    rm -f "$SNAPSHOT" "$SNAPSHOT_BAK"
    mkdir -p "$SUPPORT_ROOT"
    if [[ -d "$BACKUP/State" ]]; then ditto "$BACKUP/State" "$STATE_DIR"; fi
    if [[ -f "$BACKUP/snapshot.nsd" ]]; then cp "$BACKUP/snapshot.nsd" "$SNAPSHOT"; fi
    if [[ -f "$BACKUP/snapshot.nsd.bak" ]]; then cp "$BACKUP/snapshot.nsd.bak" "$SNAPSHOT_BAK"; fi
  fi
  "$WORK/pasteboard-snapshot" restore "$BACKUP/pasteboard.plist" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
if [[ -d "$STATE_DIR" ]]; then ditto "$STATE_DIR" "$BACKUP/State"; fi
if [[ -f "$SNAPSHOT" ]]; then cp "$SNAPSHOT" "$BACKUP/snapshot.nsd"; fi
if [[ -f "$SNAPSHOT_BAK" ]]; then cp "$SNAPSHOT_BAK" "$BACKUP/snapshot.nsd.bak"; fi
MANAGED_STATE=1
rm -rf "$STATE_DIR"
rm -f "$SNAPSHOT" "$SNAPSHOT_BAK"

say -v Samantha -r 150 -o "$WORK/fixture.aiff" 'Friday local dictation works. Friday local dictation works.'
afconvert "$WORK/fixture.aiff" "$WORK/fixture.wav" -f WAVE -d LEI16@16000 -c 1
python3 -c 'import array,struct,sys,wave; w=wave.open(sys.argv[1],"rb"); a=array.array("h"); a.frombytes(w.readframes(w.getnframes())); a.byteswap() if sys.byteorder=="big" else None; n=80000; a=a[:n]; values=[x/32768.0 for x in a]+[0.0]*max(0,n-len(a)); open(sys.argv[2],"wb").write(struct.pack("<%sf"%n,*values[:n]))' "$WORK/fixture.wav" "$WORK/fixture.f32"

rm -rf "$ROOT/.zig-cache/native-sdk-automation"
env TMPDIR="$RUN_TMP" \
  FRIDAY_AUTOMATION_SCENE=settings-light \
  FRIDAY_AUTOMATION_PERFORMANCE="$ITERATIONS|$WORK/fixture.f32|$RAW_FIXTURE" \
  FRIDAY_AUTOMATION_METRICS_OUTPUT="$RAW_METRICS" \
  "$APP" >"$WORK/friday.log" 2>&1 &
PID=$!
"$CLI" automate wait >/dev/null
for _ in {1..300}; do
  if [[ -s "$RAW_FIXTURE" ]]; then break; fi
  sleep 0.1
done
if [[ ! -s "$RAW_FIXTURE" ]]; then echo "Performance fixture evidence was not written." >&2; exit 1; fi

snapshot_file="$ROOT/.zig-cache/native-sdk-automation/snapshot.txt"
widget_id() {
  local role="$1"
  local name="$2"
  sed -n "s/.*#\([0-9][0-9]*\) role=$role name=\"$name\".*/\1/p" "$snapshot_file" | sed -n '1p'
}
"$CLI" automate profile on >/dev/null

sample=0
while [[ "$sample" -lt "$ITERATIONS" ]]; do
  probe_id="$(widget_id button 'Run Automation Hotkey Probe')"
  "$CLI" automate widget-action main-canvas "$probe_id" press >/dev/null
  "$CLI" automate assert 'role=text name="recording"' 'Locked recording' >/dev/null
  "$CLI" automate tray-action 11 >/dev/null
  "$CLI" automate assert 'role=text name="ready"' >/dev/null
  sample=$((sample + 1))
done

# Exercise rebuild/layout/a11y paths while profiling, without changing durable
# user preferences.
for tab_name in Models Access Controls Diagnostics Controls; do
  tab_id="$(widget_id button "$tab_name")"
  "$CLI" automate widget-action main-canvas "$tab_id" press >/dev/null
done
"$CLI" automate snapshot >"$PROFILE"
"$CLI" automate assert --absent 'error event=' >/dev/null
if [[ ! -s "$RAW_METRICS" ]]; then echo "Host timing evidence was not written." >&2; exit 1; fi

stop_process
mkdir -p "$ROOT/docs"
OS_VERSION="$(sw_vers -productVersion)" ITERATIONS="$ITERATIONS" python3 - "$RAW_FIXTURE" "$RAW_METRICS" "$PROFILE" "$ROOT/docs/performance-results.json" <<'PY'
import json, math, os, platform, re, sys
fixture_path, metrics_path, profile_path, output_path = sys.argv[1:]
fixture = json.load(open(fixture_path))
metrics = json.load(open(metrics_path))
profile = open(profile_path).read()

def p95(values):
    ordered = sorted(int(value) for value in values)
    if not ordered:
        raise SystemExit("missing performance samples")
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]

samples = {
    "hotkeyToFirstSampleMs": metrics["hotkeyToFirstSampleMs"],
    "stopToDrainMs": metrics["stopToDrainMs"],
    "warmFiveSecondStopToTextMs": fixture["warmFiveSecondStopToTextMs"],
    "textToDeliveryMs": fixture["textToDeliveryMs"],
    "droppedFrames": metrics["droppedFrames"],
    "residentBytes": fixture["residentBytes"],
}
summary = {
    "hotkeyToFirstSampleP95Ms": p95(samples["hotkeyToFirstSampleMs"]),
    "stopToDrainP95Ms": p95(samples["stopToDrainMs"]),
    "warmFiveSecondStopToTextP95Ms": p95(samples["warmFiveSecondStopToTextMs"]),
    "textToDeliveryP95Ms": p95(samples["textToDeliveryMs"]),
    "droppedFramesTotal": sum(int(x) for x in samples["droppedFrames"]),
    "residentBytesMax": max(int(x) for x in samples["residentBytes"]),
    "uiInputLatencyBudgetExceeded": int(re.search(r"gpu_input_latency_budget_exceeded=(\d+)", profile).group(1)),
    "uiDispatchErrors": int(re.search(r"dispatch_errors=(\d+)", profile).group(1)),
}
stage_names = {"rebuild", "layout", "reconcile", "emit", "a11y", "plan", "patch", "encode", "present", "host_decode", "host_draw"}
stage_maxima = {name: int(value) for name, value in re.findall(r"([a-z0-9_]+)_max_us=(\d+)", profile) if name in stage_names}
summary["uiStageMaxMicroseconds"] = stage_maxima
summary["uiStageWorstMicroseconds"] = max(stage_maxima.values(), default=0)
budgets = {
    "hotkeyToFirstSampleP95Ms": 75,
    "stopToDrainP95Ms": 100,
    "warmFiveSecondStopToTextP95Ms": 1000,
    "textToDeliveryP95Ms": 75,
    "uiStageWorstMicroseconds": 16000,
}
passes = {name: summary[name] <= limit for name, limit in budgets.items()}
passes["droppedFramesTotal"] = summary["droppedFramesTotal"] == 0
passes["uiDispatchErrors"] = summary["uiDispatchErrors"] == 0
result = {
    "schemaVersion": 1,
    "baseline": {"hardware": "Apple M1 Max", "os": f"macOS {os.environ['OS_VERSION']}", "architecture": platform.machine()},
    "iterations": int(os.environ["ITERATIONS"]),
    "method": {
        "hotkeyToFirstSample": "production CGEvent session-tap receipt to the pure-Zig 16 kHz capture path's first converted sample using the signed app's deterministic modifier probe",
        "stopToDrain": "friday.audio.stop receipt to drained capture completion",
        "warmFiveSecondStopToText": "twenty in-process warm recognitions of an exact five-second 16 kHz Float32 fixture plus the shipped 250 ms presentation fence",
        "textToDelivery": "final transcript ready to truthful clipboard delivery completion",
        "ui": "Native automation frame profile plus dispatch/input latency counters",
        "energy": "external Instruments Energy Log check required"
    },
    "rawSamples": samples,
    "summary": summary,
    "budgets": budgets,
    "passes": passes,
    "externalChecks": {"energy": "required before public release; no trustworthy noninteractive sampler is used"},
    "privacy": {"transcriptIncluded": False, "audioIncluded": False, "rawPathsIncluded": False},
}
json.dump(result, open(output_path, "w"), indent=2, sort_keys=True)
open(output_path, "a").write("\n")
failed = [name for name, passed in passes.items() if not passed]
if failed:
    raise SystemExit("performance budget failure: " + ", ".join(failed))
PY
printf 'Performance budgets passed; wrote %s\n' "$ROOT/docs/performance-results.json"
