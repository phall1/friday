#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFLIGHT="$ROOT/scripts/release-preflight.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/friday-release-preflight.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_fails() {
  local name="$1"
  local expected="$2"
  shift 2
  local output status
  set +e
  output="$({ "$@"; } 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 && "$output" == *"$expected"* ]]; then pass "$name"; else
    printf '%s\n' "$output" >&2
    fail "$name"
  fi
}

assert_passes() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output="$({ "$@"; } 2>&1)" && [[ "$output" == *"$expected"* ]]; then pass "$name"; else
    printf '%s\n' "$output" >&2
    fail "$name"
  fi
}

make_repository_fixture() {
  local repo="$1"
  mkdir -p "$repo/scripts"
  cp "$PREFLIGHT" "$repo/scripts/release-preflight.sh"
  chmod +x "$repo/scripts/release-preflight.sh"
  printf '{"version":"0.1.0"}\n' >"$repo/app.json"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Release Test'
  git -C "$repo" config user.email 'release-test@example.invalid'
  git -C "$repo" add app.json scripts/release-preflight.sh
  git -C "$repo" commit -qm 'test fixture'
  git -C "$repo" tag v0.1.0
}

repo="$TMP_ROOT/repository"
make_repository_fixture "$repo"
commit="$(git -C "$repo" rev-parse HEAD)"
touch "$repo/untracked"
assert_fails \
  'dirty repository is rejected before release gates' \
  'worktree is dirty' \
  "$repo/scripts/release-preflight.sh" repository "$commit" v0.1.0
rm "$repo/untracked"
assert_fails \
  'missing expected tag is rejected' \
  'expected tag v9.9.9 does not exist' \
  "$repo/scripts/release-preflight.sh" repository "$commit" v9.9.9
assert_fails \
  'stale expected commit is rejected' \
  'does not match expected commit' \
  "$repo/scripts/release-preflight.sh" repository 0000000000000000000000000000000000000000 v0.1.0

failed_gate="$TMP_ROOT/failed-gate"
mkdir -p "$failed_gate/scripts" "$failed_gate/release" "$failed_gate/patches" "$failed_gate/resources/models" "$failed_gate/third_party/nemo-speech/lib" "$failed_gate/bin"
cp "$PREFLIGHT" "$failed_gate/scripts/release-preflight.sh"
chmod +x "$failed_gate/scripts/release-preflight.sh"
cat >"$failed_gate/package.json" <<'EOF'
{"dependencies":{"@native-sdk/core":"0.10.1"},"devDependencies":{"@native-sdk/cli":"0.10.1","patch-package":"8.0.0"}}
EOF
cat >"$failed_gate/package-lock.json" <<'EOF'
{"packages":{"":{"dependencies":{"@native-sdk/core":"0.10.1"},"devDependencies":{"@native-sdk/cli":"0.10.1"}},"node_modules/@native-sdk/core":{"version":"0.10.1"},"node_modules/@native-sdk/cli":{"version":"0.10.1"},"node_modules/patch-package":{"version":"8.0.0"}}}
EOF
printf '{"version":"0.1.0"}\n' >"$failed_gate/app.json"
cat >"$failed_gate/resources/models/parakeet-tdt-0.6b-v3.json" <<'EOF'
{"revision":"541d1f99c6b0c3cd0b11a95167540bb8edefd82b","sha256":"e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e","expectedBytes":713975456,"parserAdmission":"friday_production_allowlist_v1"}
EOF
printf 'patch\n' >"$failed_gate/patches/@native-sdk+cli+0.10.1.patch"
printf 'runtime\n' >"$failed_gate/third_party/nemo-speech/lib/runtime.dylib"
(cd "$failed_gate" && shasum -a 256 third_party/nemo-speech/lib/runtime.dylib >release/macos-arm64-runtime.sha256)
cat >"$failed_gate/scripts/verify-icon.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$failed_gate/bin/npm" <<'EOF'
#!/bin/bash
if [[ "$*" == "run check" ]]; then
  echo 'simulated check failure' >&2
  exit 17
fi
exit 0
EOF
cat >"$failed_gate/bin/npx" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$failed_gate/scripts/verify-icon.sh" "$failed_gate/bin/npm" "$failed_gate/bin/npx"
printf '.native/\nzig-out/\n' >"$failed_gate/.gitignore"
git -C "$failed_gate" init -q
git -C "$failed_gate" config user.name 'Release Test'
git -C "$failed_gate" config user.email 'release-test@example.invalid'
git -C "$failed_gate" add .
git -C "$failed_gate" commit -qm 'test gate fixture'
git -C "$failed_gate" tag v0.1.0
failed_commit="$(git -C "$failed_gate" rev-parse HEAD)"
assert_fails \
  'failed source check prevents a gate report' \
  'simulated check failure' \
  env PATH="$failed_gate/bin:$PATH" "$failed_gate/scripts/release-preflight.sh" source "$failed_commit" v0.1.0
if [[ -e "$failed_gate/.native/release/source-gates.json" ]]; then fail 'failed source check leaves no success report'; else pass 'failed source check leaves no success report'; fi

runtime="$TMP_ROOT/runtime"
mkdir -p "$runtime/scripts" "$runtime/release" "$runtime/third_party/nemo-speech/lib"
cp "$PREFLIGHT" "$runtime/scripts/release-preflight.sh"
chmod +x "$runtime/scripts/release-preflight.sh"
printf 'trusted-runtime\n' >"$runtime/third_party/nemo-speech/lib/runtime.dylib"
(cd "$runtime" && shasum -a 256 third_party/nemo-speech/lib/runtime.dylib >release/macos-arm64-runtime.sha256)
assert_passes \
  'pinned vendored runtime passes' \
  'Vendored runtime hashes passed' \
  "$runtime/scripts/release-preflight.sh" runtime
printf 'tampered\n' >>"$runtime/third_party/nemo-speech/lib/runtime.dylib"
assert_fails \
  'tampered vendored runtime is rejected' \
  'vendored NeMo runtime does not match' \
  "$runtime/scripts/release-preflight.sh" runtime

manifest="$TMP_ROOT/candidate.json"
evidence="$TMP_ROOT/evidence.json"
cat >"$manifest" <<'EOF'
{
  "schemaVersion": 1,
  "kind": "FridayReleaseCandidate",
  "candidateState": "awaiting-gui-evidence",
  "source": { "commit": "1111111111111111111111111111111111111111", "tag": "v0.1.0", "version": "0.1.0" },
  "artifacts": {
    "app": { "binarySha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
    "dmg": { "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }
}
EOF
MANIFEST="$manifest" EVIDENCE="$evidence" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const manifestSha256 = crypto.createHash('sha256').update(fs.readFileSync(process.env.MANIFEST)).digest('hex');
const evidence = {
  schemaVersion: 2,
  kind: 'FridayArm64ReleaseEvidence',
  recordedAt: '2026-09-04T00:00:00Z',
  promotionReady: true,
  candidate: {
    manifestSha256,
    source: { commit: '1111111111111111111111111111111111111111', tag: 'v0.1.0', version: '0.1.0' },
    binarySha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    dmgSha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  },
  checks: {
    quarantineLaunch: { passed: true, evidence: 'quarantine-launch.log' },
    externalHotkey: { passed: true, evidence: 'hotkey.mov' },
    overlayExternalPointer: { passed: true, evidence: 'overlay.mov' },
    automaticInsertion: { textEdit: true, terminal: true, browser: true, wrongAppFocusRefused: true, clipboardFallbackTruthful: true, evidence: 'insertion.mov' },
    permissionsRecovery: { passed: true, evidence: 'permissions.mov' },
    unsupportedPlatforms: { intel: true, macos13: true, evidence: 'unsupported.log' },
    accessibilityAppearance: { passed: true, evidence: 'appearance.mov' },
    energy: { passed: true, instrumentsTraceSha256: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', evidence: 'energy.trace' },
  },
  host: { architecture: 'arm64', processTranslated: false, hardware: 'Test Mac', os: 'macOS test' },
  externalBlockers: [],
};
fs.writeFileSync(process.env.EVIDENCE, `${JSON.stringify(evidence, null, 2)}\n`);
NODE
assert_passes \
  'complete GUI evidence matching exact artifact hashes passes linkage verification' \
  'GUI evidence matches candidate manifest' \
  "$PREFLIGHT" verify-evidence "$manifest" "$evidence"

node -e "const fs=require('fs'); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p)); x.candidate.dmgSha256='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'; fs.writeFileSync(p, JSON.stringify(x));" "$evidence"
assert_fails \
  'GUI evidence for a different DMG is rejected' \
  'DMG SHA-256 does not match' \
  "$PREFLIGHT" verify-evidence "$manifest" "$evidence"

MANIFEST="$manifest" EVIDENCE="$evidence" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const x = JSON.parse(fs.readFileSync(process.env.EVIDENCE));
x.candidate.dmgSha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
x.candidate.manifestSha256 = crypto.createHash('sha256').update('stale manifest').digest('hex');
fs.writeFileSync(process.env.EVIDENCE, JSON.stringify(x));
NODE
assert_fails \
  'GUI evidence for a stale manifest is rejected' \
  'does not match the candidate manifest SHA-256' \
  "$PREFLIGHT" verify-evidence "$manifest" "$evidence"

if [[ $failures -ne 0 ]]; then
  printf '%d release preflight test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All release preflight negative/linkage tests passed.\n'
