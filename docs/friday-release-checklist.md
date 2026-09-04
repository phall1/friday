# Friday Release Checklist

A checked box means the exact artifact under release was observed. Do not infer Developer ID, notarization, AX success, overlay pointer behavior, or energy from development signing or contract probes.

## Current release state

- [x] Apple Silicon-only target enforced across Zig target resolution, the pure-Zig macOS host, Native packaging, the aarch64 NeMo Metal runtime, CI, diagnostics, and release. Intel, universal slices, and Rosetta are refused. CI also rejects tracked `.swift`, `.m`, and `.mm` implementation. The bundle minimum remains macOS 13 only to render the unsupported-system explanation; product support starts at macOS 14.

- [x] Hardened runtime and library validation stay enabled.
- [x] Embedded NeMo/ggml dylibs and app can be signed with the current Apple Development team identity.
- [x] Development app and DMG signatures are verified by `scripts/package-macos.sh`.
- [x] Generated unsigned Native SDK resource notes are overwritten before signing; no shipped resource claims `signing=none`.
- [x] The Apple Development-signed 0.1.0 candidate was installed as `/Applications/Friday.app` on 2026-09-01; LaunchServices registered it, Control Center created its visible **F** status item, close hid the Settings window without ending the process, Settings reopened from the status menu, and Quit exited without a crash report.
- [ ] **External blocker:** no Developer ID Application identity is installed in the current environment.
- [ ] **External blocker:** no authenticated `FRIDAY_NOTARY_PROFILE` is configured.
- [ ] **External blocker:** external-pointer overlay Stop/Cancel acceptance is not observed in a normal GUI session.
- [ ] **External blocker:** successful AX insertion into TextEdit, Terminal, and a browser field is not observed in a normal GUI session; truthful clipboard fallback is observed.
- [ ] **External blocker:** Instruments Energy Log is not yet recorded for the release candidate.

The strict candidate builder must fail rather than produce a candidate when either credential is absent. A notarized candidate is still **not promotion-ready** until normal-GUI evidence matches its manifest, binary, and DMG hashes.

## One-time Apple credential setup

Install a valid **Developer ID Application** certificate and private key in the signing keychain. Confirm it is visible:

```sh
security find-identity -v -p codesigning
```

Create an app-specific password for the release Apple ID, then store notary credentials in Keychain:

```sh
xcrun notarytool store-credentials friday-notary \
  --apple-id '<apple-id>' \
  --team-id '<10-character-team-id>' \
  --password '<app-specific-password>'
```

Validate the stored profile without placing secrets in repository files or shell history:

```sh
xcrun notarytool history --keychain-profile friday-notary
```

Set release environment variables for the current shell. A SHA-1 identity hash is preferred; the full identity name also works.

```sh
export FRIDAY_DEVELOPER_ID='<Developer ID Application identity hash>'
export FRIDAY_NOTARY_PROFILE='friday-notary'
```

Never commit certificate exports, private keys, Apple IDs, app-specific passwords, API keys, Keychain contents, or secret environment files.

## Source and dependency gate

- [ ] Clean worktree at the intended conventional release commit; untracked files also fail the gate.
- [ ] The expected `v<app-version>` tag exists and resolves to that exact full commit.
- [ ] Version/changelog/specs/user guide describe the shipped behavior.
- [ ] Node.js 24, Zig 0.16.0, Xcode/Command Line Tools, Native SDK 0.10.1 patch, NeMo 0.1.0, and default-model manifest pins match `specs/friday/TECH.md`.
- [ ] Exact dependency install and patch verification pass:

```sh
EXPECTED_COMMIT="$(git rev-parse HEAD)"
EXPECTED_TAG="v$(node -p "require('./app.json').version")"
scripts/release-preflight.sh repository "$EXPECTED_COMMIT" "$EXPECTED_TAG"
```

This fast repository check fails on a dirty/stale commit or tag, wrong Node/Zig/architecture, lock drift, model-pin drift, icon drift, or any mismatch against `release/macos-arm64-runtime.sha256`. The full candidate flow additionally runs `npm ci --ignore-scripts` and `npx patch-package --error-on-fail` before checks.

- [ ] Core/markup/manifest check, build, and all tests pass:

```sh
scripts/release-preflight.sh source "$EXPECTED_COMMIT" "$EXPECTED_TAG"
```

The source preflight runs `npm run check`, `npm run build`, `npm test`, the icon check, an automation build, and all twelve UI/accessibility/keyboard goldens. It writes an ignored, commit/tag-bound gate report only after every command passes and the worktree remains clean.

- [ ] Canonical icon SVG and 1024×1024 PNG pass their pinned integrity check:

```sh
scripts/verify-icon.sh
```

## UI and behavior evidence

Build the raw automation binary and compare all twelve committed 640×480 scenes. The harness backs up/restores Native state and refuses to race a running Friday process.

```sh
zig build -Dtarget=aarch64-macos -Dautomation=true
export FRIDAY_APP_BINARY="$PWD/zig-out/bin/friday"
for scene in onboarding-light settings-dark model-light error-dark \
  recording-light transcribing-dark overlay-preview-light accessibility-dark \
  unsupported-intel-light hotkey-conflict-light resume-light hf-confirmation-dark; do
  tests/ui-automation.sh "$scene"
done
unset FRIDAY_APP_BINARY
```

- [ ] All PNGs match byte-for-byte.
- [ ] Every scene has required accessible roles/names.
- [ ] Tab and Shift-Tab traversal succeeds.
- [ ] No automation dispatch error is present.
- [ ] `docs/friday-behavior-coverage.md` has a row for each PRODUCT invariant 1–170 and no external item is represented as an automated pass.
- [ ] The packaged native-contract result reports `keyboardContract`, `voiceOverContract`, `announcementContract`, `noLiveUpdateAnnouncements`, `nonColorStateContract`, `hitRegionContract`, and `terminalContract` as `true`, with identical nonzero `sourcePid`/`frontmostPid` and `fridayActive:false`.

The native capsule contract exercises the production AppKit controls and
announcement gate. It proves configured key equivalents/focus order, exposed
AXPress actions, target-action dispatch, point-sized hit regions, semantic
de-duplication, excluded timer/meter accessibility updates, appearance policy,
and process nonactivation. It does not prove what VoiceOver speaks, how Full
Keyboard Access or Voice Control behaves in a user's configuration, pointer
delivery from another process, or visual readability.

## Signed packaged E2E and privacy

Create an automation-enabled team-signed development package, then run the state-preserving E2E harness:

```sh
FRIDAY_AUTOMATION=1 FRIDAY_SIGN_IDENTITY='<team identity hash>' npm run package
FRIDAY_REQUIRE_EXTERNAL_HOTKEY=1 tests/packaged-e2e.sh
```

- [x] Fresh setup/recovery surfaces pass.
- [x] Real microphone manual Start/Stop reaches recording → transcribing → ready and silence leaves no temp audio.
- [ ] External CGEvent hold and double-tap reach held/locked behavior without changing TCC grants.
- [x] Cancel/stale recovery returns to ready and no canceled result is delivered.
- [x] Five-second fixture ASR reaches truthful clipboard fallback and pasteboard contents are restored afterward.
- [x] Installed active model remains ready with network endpoints disabled.
- [x] Packaged repository probes reject malformed, corrupt, SHA-failed, private, gated, ambiguous, incompatible, and unhashed inputs and hydrate resumable state.
- [x] Exact 9:45/10:00/drop and route/converter cleanup probes pass.
- [x] Launch-at-login register/unregister cycle reports `restored=true` and leaves the prior state unchanged.
- [x] Diagnostics redaction flags are false for transcript/audio/raw paths and known fixture text/path are absent.
- [x] Model cleanup removes only the isolated partial; installed model SHA is unchanged.
- [x] Harness restores app snapshots/window state/download partials/model index/pasteboard and does not mutate TCC grants.

Inspect cleanup directly after the run:

```sh
if compgen -G "${TMPDIR:-/tmp}/Friday/Audio/*" >/dev/null; then
  echo 'unexpected Friday temp audio remains' >&2
  exit 1
fi
```

## Performance gate

Run at least twenty samples on the Apple M1 baseline with the signed automation package and an installed active model:

```sh
tests/performance.sh
```

- [x] `docs/performance-results.json` contains raw samples, p95 summary, baseline, method, budgets, privacy flags, and an explicit energy external check.
- [x] Hotkey receipt → first converted sample p95 ≤75 ms.
- [x] Stop request → drained capture p95 ≤100 ms.
- [x] Warm exact-five-second fixture Stop → final text p95 ≤1,000 ms, including the shipped 250 ms presentation fence.
- [x] Final text → delivery p95 ≤75 ms.
- [x] Dropped frames total is zero.
- [x] Native UI dispatch errors are zero and the worst profiled rebuild/layout/reconcile/emit/a11y/plan/patch/encode/present/host stage is ≤16 ms. Record the runtime’s stricter 8.33 ms input-latency counter separately; it is evidence, not the TECH 16 ms stall threshold.
- [x] RSS maximum is recorded, not treated as a configurable pass threshold.
- [ ] Instruments Energy Log is attached as external release evidence.

If a deterministic budget fails, optimize the implementation and rerun. Do not change the budget to fit the result.

## Developer ID signing, notarization, and Gatekeeper

Run only with the credentials above:

```sh
EXPECTED_COMMIT="$(git rev-parse HEAD)"
EXPECTED_TAG="v$(node -p "require('./app.json').version")"
scripts/release-macos.sh candidate \
  --expected-commit "$EXPECTED_COMMIT" \
  --expected-tag "$EXPECTED_TAG"
```

`candidate` is the only credentialed phase. It runs the source gates, builds a team-signed automation sibling for packaged E2E, then replaces it with a production build before Developer ID signing and notarization. It writes `zig-out/package/Friday-<version>-arm64.release-manifest.json` and explicitly stops at `awaiting-gui-evidence`; it never publishes or claims promotion readiness.

The script must perform and pass all of the following:

- [ ] Resolve `FRIDAY_DEVELOPER_ID` to **Developer ID Application**, not Apple Development/Distribution or ad hoc.
- [ ] Extract a 10-character Team ID and verify the final app `TeamIdentifier` matches.
- [ ] Verify `FRIDAY_NOTARY_PROFILE` authenticates before building.
- [ ] Timestamp/sign every embedded dylib and the app with hardened runtime and the checked-in entitlements.
- [ ] Verify nested libraries and app with `codesign --verify --deep --strict`.
- [ ] Confirm `Authority=Developer ID Application:` and a non-`none` timestamp.
- [ ] Zip and submit the app with `xcrun notarytool submit --wait`.
- [ ] Staple/validate the app and pass `spctl --assess --type execute`.
- [ ] Build and timestamp-sign the DMG from the stapled app.
- [ ] `uname -m` is `arm64` and `sysctl -in sysctl.proc_translated` is `0`.
- [ ] `file`, `lipo -archs`, and `otool -hv` report arm64 for the main Mach-O and every bundled dylib; no artifact contains an `x86_64` slice.
- [ ] Submit the DMG with `notarytool --wait`, staple/validate it, and pass `spctl --assess --type open`.
- [ ] Verify the bundle resources do not contain `signing=none` or “unsigned local package”.
- [ ] Candidate manifest binds the exact source commit/tag/version, Node/Zig/Xcode toolchain, package lock, Native SDK patch, default-model revision/hash/size, NeMo archive and per-library hashes, automation validation binary, production binary, DMG, Developer ID authority/Team ID, timestamps, notarization, stapling, Gatekeeper, and every automated gate.

Independent inspection commands:

```sh
codesign -d --verbose=4 zig-out/package/Friday.app
codesign --verify --deep --strict --verbose=2 zig-out/package/Friday.app
codesign --verify --strict --verbose=2 zig-out/package/Friday-0.1.0-arm64.dmg
xcrun stapler validate zig-out/package/Friday.app
xcrun stapler validate zig-out/package/Friday-0.1.0-arm64.dmg
spctl --assess --type execute --verbose=4 zig-out/package/Friday.app
spctl --assess --type open --verbose=4 zig-out/package/Friday-0.1.0-arm64.dmg
```

## Required external interactive checks

Use the exact notarized candidate in a normal logged-in GUI session:

- [ ] Launch from Applications after downloading the stapled DMG through a quarantine-applying path.
- [ ] External CGEvent hold, release, and double-tap lock work in the normal logged-in GUI session.
- [ ] External pointer clicks overlay Stop and Cancel while Friday remains inactive and the source app retains focus.
- [ ] With Full Keyboard Access enabled, traverse the real capsule and invoke Stop, Hide, Cancel, and any shown recovery action; Friday remains inactive and the source app retains focus until an explicitly activating recovery destination is chosen.
- [ ] With VoiceOver enabled, invoke the real capsule actions and hear exactly one semantic announcement for recording, locked recording, transcribing, paste/copy, and failure transitions; hear no timer, meter, or partial-transcript chatter.
- [ ] With Voice Control enabled, address each capsule action by its exposed name and confirm its hit region matches the visible control.
- [ ] Automatic AX delivery succeeds into TextEdit, Terminal, and a browser text field; wrong-app focus is refused; clipboard fallback still reports truthfully.
- [ ] Revoke/regrant Microphone, Input Monitoring, and Accessibility and observe live recovery without deleting grants afterward.
- [ ] Observe unsupported Intel and macOS 13 launch/message on real hardware or a supported VM; setup/download/recording stay disabled.
- [ ] Inspect settings/overlay at representative display scales in increased contrast, reduced transparency, and reduced motion.
- [ ] Capture Instruments Energy Log for idle menu-bar, recording, and warm five-second transcription.

Record dates, OS/hardware, artifact SHA-256, pass/fail, and screenshot/log/trace paths. These items remain blockers until observed; contract probes are not substitutes.

## GUI evidence and promotion

Use `docs/arm64-release-evidence.schema.json` for the normal-GUI record. `docs/arm64-release-evidence.json` is the prior development observation and intentionally has `promotionReady: false`; do not turn its unchecked fields into passes. Create a new evidence file for the notarized candidate and copy all bindings from the generated manifest:

- SHA-256 of the candidate manifest file itself.
- Source commit, tag, and version.
- Production executable and DMG SHA-256.
- Native arm64 host/OS and evidence references for every required interactive check.
- SHA-256 of the Instruments trace.

Every check must be observed against that exact candidate and set to `true`, `externalBlockers` must be empty, and only then may the record set `promotionReady: true`. Validate linkage without credentials:

```sh
MANIFEST="zig-out/package/Friday-0.1.0-arm64.release-manifest.json"
EVIDENCE="/path/to/Friday-0.1.0-arm64.gui-evidence.json"
scripts/release-preflight.sh verify-evidence "$MANIFEST" "$EVIDENCE"
```

Only the separate, read-only promotion check may print `PROMOTION READY`. It recomputes artifact/runtime hashes, rechecks the clean expected commit/tag, Developer ID signatures, notarization tickets, stapling, and Gatekeeper, then requires matching complete GUI evidence:

```sh
scripts/release-macos.sh promote \
  --manifest "$MANIFEST" \
  --gui-evidence "$EVIDENCE"
```

This command does not upload, notarize, tag, publish, or modify artifacts. Actual distribution remains a separate authorized action.
