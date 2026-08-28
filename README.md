# Friday

Friday is an Apple Silicon menu-bar dictation app for macOS 14 and later. It records the microphone, transcribes locally with a compatible Parakeet TDT GGUF model, and returns only the final text to the app where dictation began. It has no cloud-ASR path and stores no transcript history.

See the [user guide](docs/friday-user-guide.md), [release checklist](docs/friday-release-checklist.md), [PRODUCT coverage matrix](docs/friday-behavior-coverage.md), and [technical specification](specs/friday/TECH.md).

## Install and run

A public release must be the arm64-only, Developer ID-signed, notarized, and stapled `Friday-0.1.0-arm64.dmg`. Open the DMG, move Friday to Applications, then launch Friday. The current repository can produce a team-signed arm64 development package, but public release remains blocked until Developer ID and notary credentials are supplied and the external checks in the release checklist pass.

Friday is arm64/aarch64 end to end and requires Apple Silicon and macOS 14+. The build graph, Objective-C++ compilation, NeMo Metal runtime, package, CI, and release scripts reject Intel, universal Mach-O slices, and Rosetta translation. The bundle permits launch on macOS 13 only so it can show a clear unsupported-system explanation; setup, downloads, and recording remain disabled there.

Friday asks separately for:

- **Microphone** — required to record.
- **Input Monitoring** — required for the system-global shortcut. Manual menu-bar Start remains available in acknowledged limited mode.
- **Accessibility** — used to return final text to the exact source app. Without it, Friday copies the final text and shows the recovery action.

Recover a revoked permission from Friday’s **Permission Status** page or System Settings → Privacy & Security, then return to Friday; it rechecks live.

## Dictation

The default shortcut is Command + Shift. Hold the confirmed shortcut to record and release to stop. A quick second press within the selected double-tap window locks recording; use Stop or Cancel afterward. Settings offers Command + Shift and Control + Option conveniences, plus a recorder for a key or function key with optional modifiers. Friday shows the captured candidate, warns about ordinary typing and known reserved/unreliable combinations, and saves only after explicit confirmation.

Normal stop drains capture, visibly enters **transcribing**, runs local final-only ASR, then pastes to the exact captured source when safe. If exact-source paste is unavailable, Friday reports a clipboard fallback. Cancel invalidates the generation immediately; stale results cannot become current. Friday warns at 9:45 and stops at exactly 10:00 while preserving a visible 10-minute explanation through the final outcome.

## Models and offline behavior

On first setup Friday offers its pinned, verified default model automatically when the model step becomes visible. Downloads are user-visible, cancellable, SHA-256 verified, resumable after relaunch, runtime-probed, and atomically installed.

Model Manager also supports:

- **Local model** — select a compatible Parakeet TDT GGUF plus its matching Friday manifest sidecar. Friday references the original file and never deletes it.
- **Public Hugging Face identifier** — enter `owner/repository`; Friday may resolve only an **unverified immutable candidate** when the public metadata has an exact revision, exactly one top-level GGUF, ASR/GGUF hints, LFS SHA/size, license, and attribution. That metadata never proves compatibility. A separately authorized download must pass exact integrity, bounded GGUF inspection, and the real local NeMo create/destroy probe before Friday publishes, lists, selects, or calls it compatible.

After a verified model is installed and active, recording and transcription work offline. Network access is limited to explicit model metadata/download actions. Remove from Friday drops a reference. Delete Friday’s Copy is shown only for Friday-managed files. Failed/partial downloads can be cleaned without deleting installed models.

Model data lives under `$HOME/Library/Application Support/com.phall.friday/Models`; partials live beside it in `ModelDownloads`. Do not edit the index or managed manifests by hand.

## Privacy and diagnostics

Audio and transcription stay on the Mac. Friday stores no transcript history and has no telemetry or cloud-ASR service. Temporary session audio is deleted after cancel, silence, successful delivery/fallback, dismissal, a superseding session, or exit; only an explicit transcription retry may retain the current failed session audio.

**Safe Diagnostics** includes versions, platform/permission usability, model integrity/storage, bounded performance facts, and safe error codes. It explicitly excludes transcript text, microphone audio, clipboard contents, document names, and raw paths. Copy/export diagnostics only when you intend to share those safe facts.

## Build and test

Requirements: Apple Silicon Mac, macOS 14+, Xcode/Command Line Tools, Node.js 24, npm, and Zig 0.16.0. The NeMo runtime/model pins are documented in `specs/friday/TECH.md`.

```sh
npm ci --ignore-scripts
npx patch-package --error-on-fail
npm run check
npm run build
npm test
```

Run the development binary:

```sh
zig build -Dtarget=aarch64-macos run
```

Build automation and compare every strict UI golden:

```sh
zig build -Dtarget=aarch64-macos -Dautomation=true
export FRIDAY_APP_BINARY="$PWD/zig-out/bin/friday"
for scene in onboarding-light settings-dark model-light error-dark \
  recording-light transcribing-dark overlay-preview-light accessibility-dark \
  unsupported-intel-light hotkey-conflict-light resume-light hf-confirmation-dark; do
  tests/ui-automation.sh "$scene"
done
```

Regenerate an intentionally reviewed golden only with `tests/ui-automation.sh --update <scene>`. Verify icon reproducibility with:

```sh
generated="$(mktemp -t friday-icon).png"
swift scripts/generate-icon.swift assets/icon.svg "$generated"
cmp "$generated" assets/icon.png
rm -f "$generated"
```

## Package and release

A local development package requires a real team signing identity because hardened runtime library validation remains enabled:

```sh
FRIDAY_SIGN_IDENTITY="<Apple Development identity hash or name>" npm run package
codesign --verify --deep --strict --verbose=2 zig-out/package/friday.app
```

The package script signs every embedded dylib, the app, and the development DMG and replaces the Native SDK’s unsigned scaffold metadata. It does **not** claim notarization.

The public release path is intentionally strict and fails before building if credentials are absent:

```sh
file zig-out/package/friday.app/Contents/MacOS/friday
lipo -archs zig-out/package/friday.app/Contents/MacOS/friday
otool -hv zig-out/package/friday.app/Contents/MacOS/friday
sysctl -in sysctl.proc_translated
export FRIDAY_DEVELOPER_ID="Developer ID Application: Example (TEAMID)"
export FRIDAY_NOTARY_PROFILE="friday-notary"
scripts/release-macos.sh
```

That script validates the identity kind and Team ID, requires timestamps, signs nested dylibs/app/DMG, submits the zipped app and DMG with `notarytool --wait`, staples and validates both, and runs `spctl`. Credential setup and the current external blockers are in `docs/friday-release-checklist.md`.

Run release validation from a signed automation package:

```sh
FRIDAY_AUTOMATION=1 npm run package
tests/packaged-e2e.sh
tests/performance.sh
```

Both harnesses refuse to race a running Friday process, preserve and restore app state and pasteboard contents, leave installed models and TCC grants intact, and fail on cleanup/privacy regressions.

## Architecture

- `src/core.ts` — deterministic Model/Msg/update workflow, readiness, stale-generation rules, persistence projection, menus, and automation routes. It compiles to native code; no JavaScript runtime ships.
- `src/app.native` — Native markup for unsupported/setup/settings/model/permission/diagnostic/result surfaces.
- `native/friday_host.zig` — exactly-once bridge between Native SDK effects and the Objective-C++ host.
- `native/macos/GlobalInputMonitor.mm` — global shortcut capture, validation, press/release, sleep/wake.
- `native/macos/AudioSession.mm` — realtime-safe AVAudioEngine capture, conversion, bounded storage, drain, route/failure cleanup.
- `native/macos/ModelRepository.mm` — verified default/local/Hugging Face models, resume, atomic publication, bounded deletion.
- `native/macos/NemoRecognizer.mm` — one serialized in-process NeMo recognizer.
- `native/macos/TextDelivery.mm` — exact-source AX/pasteboard delivery and truthful fallback.
- `native/macos/OverlayWindow.mm` — nonactivating recording/transcribing capsule.

Known system-context gaps are not hidden: external pointer acceptance for the overlay and successful AX insertion into TextEdit/Terminal/browser fields have not been observed in this loginwindow-bound harness; public notarization cannot run without Developer ID/notary credentials; energy remains an Instruments check. These are release-checklist items, not inferred passes.
