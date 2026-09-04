#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUNTIME_PINS="$ROOT/release/macos-arm64-runtime.sha256"
SOURCE_REPORT="$ROOT/.native/release/source-gates.json"
E2E_REPORT="$ROOT/.native/release/package-e2e.json"
UI_SCENES=(
  onboarding-light settings-dark model-light error-dark
  recording-light transcribing-dark overlay-preview-light accessibility-dark
  unsupported-intel-light hotkey-conflict-light resume-light hf-confirmation-dark
)

die() {
  printf 'Release preflight blocked: %s\n' "$*" >&2
  exit 2
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_file() {
  [[ -f "$1" ]] || die "required file is missing: $1"
}

assert_native_arm64() {
  [[ "$(uname -m)" == "arm64" ]] || die "a native Apple Silicon shell is required"
  local translated
  translated="$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')"
  [[ "$translated" == "0" ]] || die "the process is translated by Rosetta"
}

assert_arm64_only() {
  local artifact="$1"
  require_file "$artifact"
  local arches description
  arches="$(lipo -archs "$artifact")"
  [[ "$arches" == "arm64" ]] || die "$artifact is not arm64-only (architectures=$arches)"
  description="$(file "$artifact")"
  [[ "$description" == *"arm64"* && "$description" != *"x86_64"* ]] ||
    die "$artifact has an invalid Mach-O architecture: $description"
}

validate_expected_source() {
  local expected_commit="$1"
  local expected_tag="$2"
  [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || die "--expected-commit must be a full lowercase 40-character Git commit"
  [[ -n "$expected_tag" ]] || die "--expected-tag is required"

  local head tag_commit version status
  head="$(git rev-parse HEAD)"
  [[ "$head" == "$expected_commit" ]] || die "HEAD $head does not match expected commit $expected_commit"
  git show-ref --verify --quiet "refs/tags/$expected_tag" || die "expected tag $expected_tag does not exist"
  tag_commit="$(git rev-parse "refs/tags/$expected_tag^{commit}")"
  [[ "$tag_commit" == "$expected_commit" ]] || die "tag $expected_tag resolves to $tag_commit, not $expected_commit"
  version="$(node -p "require('./app.json').version")"
  [[ "$expected_tag" == "v$version" ]] || die "tag $expected_tag does not match app version v$version"
  status="$(git status --porcelain=v1 --untracked-files=all)"
  [[ -z "$status" ]] || die "worktree is dirty; candidate provenance requires every tracked and untracked path to be accounted for"
}

verify_runtime_hashes() {
  require_file "$RUNTIME_PINS"
  shasum -a 256 -c "$RUNTIME_PINS" >/dev/null || die "vendored NeMo runtime does not match release/macos-arm64-runtime.sha256"
}

verify_dependency_contract() {
  node <<'NODE'
const fs = require('node:fs');
const fail = message => { console.error(`Release preflight blocked: ${message}`); process.exit(2); };
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const model = JSON.parse(fs.readFileSync('resources/models/parakeet-tdt-0.6b-v3.json', 'utf8'));
const exact = {
  '@native-sdk/core': '0.10.1',
  '@native-sdk/cli': '0.10.1',
  'patch-package': '8.0.0',
};
for (const [name, version] of Object.entries(exact)) {
  const declared = pkg.dependencies?.[name] ?? pkg.devDependencies?.[name];
  if (declared !== version) fail(`${name} must be declared exactly as ${version}`);
  const locked = lock.packages?.[`node_modules/${name}`]?.version;
  if (locked !== version) fail(`${name} lock entry must be exactly ${version}`);
}
if (lock.packages?.['']?.dependencies?.['@native-sdk/core'] !== exact['@native-sdk/core']) fail('package-lock root dependency is stale');
if (lock.packages?.['']?.devDependencies?.['@native-sdk/cli'] !== exact['@native-sdk/cli']) fail('package-lock root devDependency is stale');
if (model.revision !== '541d1f99c6b0c3cd0b11a95167540bb8edefd82b') fail('default model revision is not pinned');
if (model.sha256 !== 'e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e') fail('default model SHA-256 is not pinned');
if (model.expectedBytes !== 713975456) fail('default model byte count is not pinned');
NODE
  require_file "$ROOT/patches/@native-sdk+cli+0.10.1.patch"
}

verify_toolchain() {
  [[ "$(node --version)" == v24.* ]] || die "Node.js 24 is required (found $(node --version))"
  [[ "$(zig version)" == "0.16.0" ]] || die "Zig 0.16.0 is required (found $(zig version))"
  command -v xcodebuild >/dev/null || die "Xcode or Command Line Tools are required"
}

verify_repository() {
  local expected_commit="$1"
  local expected_tag="$2"
  assert_native_arm64
  validate_expected_source "$expected_commit" "$expected_tag"
  verify_toolchain
  verify_dependency_contract
  verify_runtime_hashes
  scripts/verify-icon.sh >/dev/null
  printf 'Repository provenance passed for %s (%s).\n' "$expected_tag" "$expected_commit"
}

write_source_report() {
  local expected_commit="$1"
  local expected_tag="$2"
  mkdir -p "$(dirname "$SOURCE_REPORT")"
  rm -f "$SOURCE_REPORT"
  verify_repository "$expected_commit" "$expected_tag"

  npm ci --ignore-scripts
  npx patch-package --error-on-fail
  npm run check
  npm run build
  npm test
  scripts/verify-icon.sh
  zig build -Dtarget=aarch64-macos -Dautomation=true
  export FRIDAY_APP_BINARY="$ROOT/zig-out/bin/friday"
  for scene in "${UI_SCENES[@]}"; do
    tests/ui-automation.sh "$scene"
  done
  unset FRIDAY_APP_BINARY

  validate_expected_source "$expected_commit" "$expected_tag"
  verify_runtime_hashes
  EXPECTED_COMMIT="$expected_commit" EXPECTED_TAG="$expected_tag" REPORT="$SOURCE_REPORT" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const hash = path => crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex');
const report = {
  schemaVersion: 1,
  kind: 'FridaySourceGateReport',
  source: { commit: process.env.EXPECTED_COMMIT, tag: process.env.EXPECTED_TAG },
  inputs: {
    packageLockSha256: hash('package-lock.json'),
    nativePatchSha256: hash('patches/@native-sdk+cli+0.10.1.patch'),
    modelManifestSha256: hash('resources/models/parakeet-tdt-0.6b-v3.json'),
    runtimePinsSha256: hash('release/macos-arm64-runtime.sha256'),
  },
  toolchain: {
    node: process.version,
    zig: require('node:child_process').execFileSync('zig', ['version'], { encoding: 'utf8' }).trim(),
    xcode: require('node:child_process').execFileSync('xcodebuild', ['-version'], { encoding: 'utf8' }).trim(),
  },
  gates: { npmCi: true, nativePatch: true, check: true, build: true, test: true, icon: true, uiGoldens: true, runtimeHashes: true },
};
fs.writeFileSync(process.env.REPORT, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
NODE
  printf 'Source gates passed; report: %s\n' "$SOURCE_REPORT"
}

write_e2e_report() {
  local expected_commit="$1"
  local expected_tag="$2"
  local app="$3"
  local binary="$app/Contents/MacOS/friday"
  mkdir -p "$(dirname "$E2E_REPORT")"
  rm -f "$E2E_REPORT"
  validate_expected_source "$expected_commit" "$expected_tag"
  assert_arm64_only "$binary"
  FRIDAY_E2E_APP_BINARY="$binary" tests/packaged-e2e.sh
  EXPECTED_COMMIT="$expected_commit" EXPECTED_TAG="$expected_tag" BINARY_SHA="$(sha256 "$binary")" REPORT="$E2E_REPORT" node <<'NODE'
const fs = require('node:fs');
const report = {
  schemaVersion: 1,
  kind: 'FridayPackagedE2EGateReport',
  source: { commit: process.env.EXPECTED_COMMIT, tag: process.env.EXPECTED_TAG },
  automationBinarySha256: process.env.BINARY_SHA,
  gates: { packagedE2E: true },
};
fs.writeFileSync(process.env.REPORT, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
NODE
  printf 'Packaged E2E passed; report: %s\n' "$E2E_REPORT"
}

validate_gate_reports() {
  local expected_commit="$1"
  local expected_tag="$2"
  require_file "$SOURCE_REPORT"
  require_file "$E2E_REPORT"
  EXPECTED_COMMIT="$expected_commit" EXPECTED_TAG="$expected_tag" SOURCE_REPORT="$SOURCE_REPORT" E2E_REPORT="$E2E_REPORT" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const fail = message => { console.error(`Release preflight blocked: ${message}`); process.exit(2); };
for (const [name, path, kind] of [
  ['source', process.env.SOURCE_REPORT, 'FridaySourceGateReport'],
  ['packaged E2E', process.env.E2E_REPORT, 'FridayPackagedE2EGateReport'],
]) {
  const report = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (report.kind !== kind) fail(`${name} gate report has the wrong kind`);
  if (report.source?.commit !== process.env.EXPECTED_COMMIT || report.source?.tag !== process.env.EXPECTED_TAG) fail(`${name} gate report is stale`);
  const required = name === 'source'
    ? ['npmCi', 'nativePatch', 'check', 'build', 'test', 'icon', 'uiGoldens', 'runtimeHashes']
    : ['packagedE2E'];
  for (const gate of required) if (report.gates?.[gate] !== true) fail(`${name} gate report is missing passed gate ${gate}`);
  if (name === 'source') {
    const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    for (const [key, file] of Object.entries({
      packageLockSha256: 'package-lock.json',
      nativePatchSha256: 'patches/@native-sdk+cli+0.10.1.patch',
      modelManifestSha256: 'resources/models/parakeet-tdt-0.6b-v3.json',
      runtimePinsSha256: 'release/macos-arm64-runtime.sha256',
    })) if (report.inputs?.[key] !== hash(file)) fail(`source gate report input ${key} is stale`);
    if (!report.toolchain?.node?.startsWith('v24.') || report.toolchain?.zig !== '0.16.0' || typeof report.toolchain?.xcode !== 'string') fail('source gate report toolchain is incomplete');
  } else if (!/^[0-9a-f]{64}$/.test(report.automationBinarySha256 ?? '')) fail('packaged E2E report has no automation binary hash');
}
NODE
}

verify_signed_candidate() {
  local app="$1"
  local dmg="$2"
  local team_id="$3"
  local binary="$app/Contents/MacOS/friday"
  local frameworks="$app/Contents/Frameworks"
  assert_arm64_only "$binary"
  local expected_hash source_path library runtime_count
  runtime_count=0
  while read -r expected_hash source_path; do
    [[ -n "$expected_hash" && -n "$source_path" ]] || continue
    library="$frameworks/$(basename "$source_path")"
    assert_arm64_only "$library"
    runtime_count=$((runtime_count + 1))
  done <"$RUNTIME_PINS"
  [[ "$runtime_count" == "7" ]] || die "runtime pin set must contain exactly seven packaged libraries"
  [[ "$(find "$frameworks" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' | wc -l | tr -d ' ')" == "$runtime_count" ]] ||
    die "candidate contains an unexpected embedded dylib"
  [[ "$(otool -hv "$binary")" == *"ARM64"* ]] || die "otool did not report ARM64 for the candidate executable"
  codesign --verify --deep --strict --verbose=2 "$app"
  codesign --verify --strict --verbose=2 "$dmg"
  xcrun stapler validate "$app"
  xcrun stapler validate "$dmg"
  spctl --assess --type execute --verbose=4 "$app"
  spctl --assess --type open --verbose=4 "$dmg"
  local signature
  signature="$(codesign -d --verbose=4 "$app" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application:"* ]] || die "candidate app is not signed with Developer ID Application"
  [[ "$signature" == *"TeamIdentifier=$team_id"* ]] || die "candidate TeamIdentifier does not match $team_id"
  [[ "$signature" == *"Timestamp="* && "$signature" != *"Timestamp=none"* ]] || die "candidate app signature has no trusted timestamp"
}

create_manifest() {
  local expected_commit="$1"
  local expected_tag="$2"
  local app="$3"
  local dmg="$4"
  local team_id="$5"
  local output="$6"
  verify_repository "$expected_commit" "$expected_tag"
  validate_gate_reports "$expected_commit" "$expected_tag"
  verify_signed_candidate "$app" "$dmg" "$team_id"

  local version binary signature_authority
  version="$(node -p "require('./app.json').version")"
  binary="$app/Contents/MacOS/friday"
  signature_authority="$(codesign -d --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  mkdir -p "$(dirname "$output")"
  EXPECTED_COMMIT="$expected_commit" EXPECTED_TAG="$expected_tag" VERSION="$version" APP="$app" DMG="$dmg" TEAM_ID="$team_id" AUTHORITY="$signature_authority" OUTPUT="$output" SOURCE_REPORT="$SOURCE_REPORT" E2E_REPORT="$E2E_REPORT" node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const relative = file => path.relative(process.cwd(), file);
const sourceReport = JSON.parse(fs.readFileSync(process.env.SOURCE_REPORT, 'utf8'));
const e2eReport = JSON.parse(fs.readFileSync(process.env.E2E_REPORT, 'utf8'));
const model = JSON.parse(fs.readFileSync('resources/models/parakeet-tdt-0.6b-v3.json', 'utf8'));
const pins = fs.readFileSync('release/macos-arm64-runtime.sha256', 'utf8').trim().split('\n').map(line => {
  const [sourceSha256, sourcePath] = line.trim().split(/\s+/, 2);
  const name = path.basename(sourcePath);
  const bundledPath = path.join(process.env.APP, 'Contents', 'Frameworks', name);
  if (!fs.existsSync(bundledPath)) throw new Error(`bundled runtime is missing ${name}`);
  const bundledSha256 = hash(bundledPath);
  return { name, sourceSha256, bundledSha256 };
});
const manifest = {
  schemaVersion: 1,
  kind: 'FridayReleaseCandidate',
  candidateState: 'awaiting-gui-evidence',
  generatedAt: new Date().toISOString(),
  source: { commit: process.env.EXPECTED_COMMIT, tag: process.env.EXPECTED_TAG, version: process.env.VERSION },
  dependencies: {
    packageLockSha256: sourceReport.inputs.packageLockSha256,
    nativeSdk: { version: '0.10.1', patchSha256: sourceReport.inputs.nativePatchSha256 },
    model: { manifestSha256: sourceReport.inputs.modelManifestSha256, revision: model.revision, artifactSha256: model.sha256, expectedBytes: model.expectedBytes },
    runtime: { selection: 'nemo-speech-0.1.0-macos-aarch64-metal', archiveSha256: 'f1dff4f9dd9c96214f8cb78b982812459132df8a4ad1a42409fd94de4a366244', archiveBytes: 3465028, pinsSha256: sourceReport.inputs.runtimePinsSha256, files: pins },
  },
  toolchain: sourceReport.toolchain,
  gates: { ...sourceReport.gates, packagedE2E: true, architecture: true, developerIdSignature: true, appNotarization: true, dmgNotarization: true, stapling: true, gatekeeper: true },
  validationArtifact: { automationBinarySha256: e2eReport.automationBinarySha256 },
  artifacts: {
    app: { path: relative(process.env.APP), binaryPath: relative(path.join(process.env.APP, 'Contents', 'MacOS', 'friday')), binarySha256: hash(path.join(process.env.APP, 'Contents', 'MacOS', 'friday')) },
    dmg: { path: relative(process.env.DMG), sha256: hash(process.env.DMG) },
  },
  signing: { kind: 'Developer ID Application', authority: process.env.AUTHORITY, teamIdentifier: process.env.TEAM_ID, timestamped: true, notarized: true, stapled: true, gatekeeperAccepted: true },
  promotion: { ready: false, reason: 'matching normal-GUI evidence is required' },
};
fs.writeFileSync(process.env.OUTPUT, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  printf 'Candidate manifest written: %s\n' "$output"
}

validate_gui_evidence() {
  local manifest="$1"
  local evidence="$2"
  require_file "$manifest"
  require_file "$evidence"
  MANIFEST="$manifest" EVIDENCE="$evidence" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const fail = message => { console.error(`Release preflight blocked: ${message}`); process.exit(2); };
let manifest, evidence;
try {
  manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8'));
  evidence = JSON.parse(fs.readFileSync(process.env.EVIDENCE, 'utf8'));
} catch (error) { fail(`invalid manifest or GUI evidence JSON: ${error.message}`); }
const manifestSha256 = crypto.createHash('sha256').update(fs.readFileSync(process.env.MANIFEST)).digest('hex');
if (manifest.kind !== 'FridayReleaseCandidate' || manifest.candidateState !== 'awaiting-gui-evidence') fail('manifest is not a Friday release candidate');
if (evidence.kind !== 'FridayArm64ReleaseEvidence' || evidence.schemaVersion !== 2) fail('GUI evidence has the wrong schema or kind');
if (evidence.promotionReady !== true) fail('GUI evidence is not marked complete for promotion');
if (evidence.host?.architecture !== 'arm64' || evidence.host?.processTranslated !== false) fail('GUI evidence was not recorded in a native arm64 session');
if (typeof evidence.host?.hardware !== 'string' || evidence.host.hardware.trim() === '' || typeof evidence.host?.os !== 'string' || evidence.host.os.trim() === '') fail('GUI evidence host details are incomplete');
if (typeof evidence.recordedAt !== 'string' || !Number.isFinite(Date.parse(evidence.recordedAt))) fail('GUI evidence has no valid recording timestamp');
if (!Array.isArray(evidence.externalBlockers) || evidence.externalBlockers.length !== 0) fail('GUI evidence still lists external blockers');
if (evidence.candidate?.manifestSha256 !== manifestSha256) fail('GUI evidence does not match the candidate manifest SHA-256');
for (const key of ['commit', 'tag', 'version']) if (evidence.candidate?.source?.[key] !== manifest.source?.[key]) fail(`GUI evidence source ${key} does not match the candidate`);
if (evidence.candidate?.binarySha256 !== manifest.artifacts?.app?.binarySha256) fail('GUI evidence binary SHA-256 does not match the candidate');
if (evidence.candidate?.dmgSha256 !== manifest.artifacts?.dmg?.sha256) fail('GUI evidence DMG SHA-256 does not match the candidate');
const required = [
  ['quarantineLaunch', evidence.checks?.quarantineLaunch],
  ['externalHotkey', evidence.checks?.externalHotkey],
  ['overlayExternalPointer', evidence.checks?.overlayExternalPointer],
  ['permissionsRecovery', evidence.checks?.permissionsRecovery],
  ['accessibilityAppearance', evidence.checks?.accessibilityAppearance],
  ['energy', evidence.checks?.energy],
];
for (const [name, check] of required) {
  if (check?.passed !== true) fail(`GUI evidence check ${name} has not passed`);
  if (typeof check.evidence !== 'string' || check.evidence.trim() === '') fail(`GUI evidence check ${name} has no evidence reference`);
}
const insertion = evidence.checks?.automaticInsertion;
for (const field of ['textEdit', 'terminal', 'browser', 'wrongAppFocusRefused', 'clipboardFallbackTruthful']) if (insertion?.[field] !== true) fail(`automatic insertion evidence is missing ${field}`);
if (typeof insertion?.evidence !== 'string' || insertion.evidence.trim() === '') fail('automatic insertion has no evidence reference');
const unsupported = evidence.checks?.unsupportedPlatforms;
for (const field of ['intel', 'macos13']) if (unsupported?.[field] !== true) fail(`unsupported-platform evidence is missing ${field}`);
if (typeof unsupported?.evidence !== 'string' || unsupported.evidence.trim() === '') fail('unsupported-platform checks have no evidence reference');
if (!/^[0-9a-f]{64}$/.test(evidence.checks.energy.instrumentsTraceSha256 ?? '')) fail('energy evidence must include the Instruments trace SHA-256');
console.log(`GUI evidence matches candidate manifest ${manifestSha256}.`);
NODE
}

verify_manifest_artifacts() {
  local manifest="$1"
  MANIFEST="$manifest" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const fail = message => { console.error(`Release preflight blocked: ${message}`); process.exit(2); };
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, 'utf8'));
const hash = path => crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex');
const failHash = (name, path, expected) => {
  if (!path || !fs.existsSync(path)) fail(`${name} input is missing`);
  if (hash(path) !== expected) fail(`${name} hash no longer matches the candidate manifest`);
};
if (manifest.kind !== 'FridayReleaseCandidate' || manifest.candidateState !== 'awaiting-gui-evidence') fail('manifest is not a Friday release candidate');
for (const gate of ['npmCi', 'nativePatch', 'check', 'build', 'test', 'icon', 'uiGoldens', 'runtimeHashes', 'packagedE2E', 'architecture', 'developerIdSignature', 'appNotarization', 'dmgNotarization', 'stapling', 'gatekeeper']) {
  if (manifest.gates?.[gate] !== true) fail(`candidate manifest is missing passed gate ${gate}`);
}
if (manifest.signing?.kind !== 'Developer ID Application' || manifest.signing?.timestamped !== true || manifest.signing?.notarized !== true || manifest.signing?.stapled !== true || manifest.signing?.gatekeeperAccepted !== true) fail('candidate manifest signing state is incomplete');
if (!/^[A-Z0-9]{10}$/.test(manifest.signing?.teamIdentifier ?? '')) fail('candidate manifest Team ID is invalid');
if (manifest.dependencies?.nativeSdk?.version !== '0.10.1') fail('candidate manifest Native SDK version is wrong');
if (manifest.dependencies?.model?.revision !== '541d1f99c6b0c3cd0b11a95167540bb8edefd82b' || manifest.dependencies?.model?.artifactSha256 !== 'e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e' || manifest.dependencies?.model?.expectedBytes !== 713975456) fail('candidate manifest default-model provenance is wrong');
if (manifest.dependencies?.runtime?.selection !== 'nemo-speech-0.1.0-macos-aarch64-metal' || manifest.dependencies?.runtime?.archiveSha256 !== 'f1dff4f9dd9c96214f8cb78b982812459132df8a4ad1a42409fd94de4a366244' || manifest.dependencies?.runtime?.archiveBytes !== 3465028) fail('candidate manifest NeMo archive provenance is wrong');
failHash('package lock', 'package-lock.json', manifest.dependencies?.packageLockSha256);
failHash('Native SDK patch', 'patches/@native-sdk+cli+0.10.1.patch', manifest.dependencies?.nativeSdk?.patchSha256);
failHash('model manifest', 'resources/models/parakeet-tdt-0.6b-v3.json', manifest.dependencies?.model?.manifestSha256);
failHash('runtime pin set', 'release/macos-arm64-runtime.sha256', manifest.dependencies?.runtime?.pinsSha256);
const safePath = value => {
  if (typeof value !== 'string' || value === '' || value.startsWith('/') || value.split('/').includes('..')) fail('candidate manifest contains an unsafe artifact path');
  return value;
};
for (const [name, path, expected] of [
  ['binary', manifest.artifacts?.app?.binaryPath, manifest.artifacts?.app?.binarySha256],
  ['DMG', manifest.artifacts?.dmg?.path, manifest.artifacts?.dmg?.sha256],
]) {
  const checkedPath = safePath(path);
  if (!fs.existsSync(checkedPath)) fail(`${name} artifact is missing`);
  if (hash(checkedPath) !== expected) fail(`${name} artifact hash no longer matches the candidate manifest`);
}
const pinLines = fs.readFileSync('release/macos-arm64-runtime.sha256', 'utf8').trim().split('\n').map(line => line.trim().split(/\s+/, 2));
const runtimeFiles = manifest.dependencies?.runtime?.files;
if (!Array.isArray(runtimeFiles) || runtimeFiles.length !== pinLines.length || runtimeFiles.length !== 7) fail('candidate manifest runtime closure is incomplete');
for (const [sourceSha256, sourcePath] of pinLines) {
  const name = require('node:path').basename(sourcePath);
  const runtime = runtimeFiles.find(entry => entry.name === name);
  if (!runtime || runtime.sourceSha256 !== sourceSha256) fail(`candidate manifest source runtime hash is wrong for ${name}`);
  const bundled = `${safePath(manifest.artifacts.app.path)}/Contents/Frameworks/${name}`;
  if (!fs.existsSync(bundled) || hash(bundled) !== runtime.bundledSha256) fail(`bundled runtime hash no longer matches for ${runtime.name}`);
}
NODE
}

promote() {
  local manifest="$1"
  local evidence="$2"
  validate_gui_evidence "$manifest" "$evidence"
  local expected_commit expected_tag app dmg team_id
  expected_commit="$(node -e "const x=JSON.parse(require('fs').readFileSync(process.argv[1])); process.stdout.write(x.source.commit)" "$manifest")"
  expected_tag="$(node -e "const x=JSON.parse(require('fs').readFileSync(process.argv[1])); process.stdout.write(x.source.tag)" "$manifest")"
  app="$(node -e "const x=JSON.parse(require('fs').readFileSync(process.argv[1])); process.stdout.write(x.artifacts.app.path)" "$manifest")"
  dmg="$(node -e "const x=JSON.parse(require('fs').readFileSync(process.argv[1])); process.stdout.write(x.artifacts.dmg.path)" "$manifest")"
  team_id="$(node -e "const x=JSON.parse(require('fs').readFileSync(process.argv[1])); process.stdout.write(x.signing.teamIdentifier)" "$manifest")"
  verify_repository "$expected_commit" "$expected_tag"
  verify_manifest_artifacts "$manifest"
  verify_signed_candidate "$app" "$dmg" "$team_id"
  printf 'PROMOTION READY: candidate %s (%s) has matching GUI evidence and unchanged notarized artifacts.\n' "$expected_tag" "$expected_commit"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/release-preflight.sh repository <expected-commit> <expected-tag>
  scripts/release-preflight.sh source <expected-commit> <expected-tag>
  scripts/release-preflight.sh runtime
  scripts/release-preflight.sh package-e2e <expected-commit> <expected-tag> <app>
  scripts/release-preflight.sh create-manifest <expected-commit> <expected-tag> <app> <dmg> <team-id> <output>
  scripts/release-preflight.sh verify-evidence <manifest> <gui-evidence>
  scripts/release-preflight.sh promote <manifest> <gui-evidence>
EOF
  exit 2
}

command="${1:-}"
case "$command" in
  repository) [[ $# == 3 ]] || usage; verify_repository "$2" "$3" ;;
  source) [[ $# == 3 ]] || usage; write_source_report "$2" "$3" ;;
  runtime) [[ $# == 1 ]] || usage; verify_runtime_hashes; printf 'Vendored runtime hashes passed.\n' ;;
  package-e2e) [[ $# == 4 ]] || usage; write_e2e_report "$2" "$3" "$4" ;;
  create-manifest) [[ $# == 7 ]] || usage; create_manifest "$2" "$3" "$4" "$5" "$6" "$7" ;;
  verify-evidence) [[ $# == 3 ]] || usage; validate_gui_evidence "$2" "$3" ;;
  promote) [[ $# == 3 ]] || usage; promote "$2" "$3" ;;
  *) usage ;;
esac
