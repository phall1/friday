# Friday

Friday is an Apple Silicon menu-bar dictation app for macOS 14 and later. It records the microphone, transcribes locally with a compatible Parakeet GGUF model, and returns only the final text to the app where dictation began. It has no cloud-ASR path and stores no transcript history.

See the [user guide](docs/friday-user-guide.md), [release checklist](docs/friday-release-checklist.md), [PRODUCT coverage matrix](docs/friday-behavior-coverage.md), and [technical specification](specs/friday/TECH.md).

## Install and run

A public release must be the arm64-only, Developer ID-signed, notarized, and stapled `Friday-0.1.0-arm64.dmg`. Open the DMG, move Friday to Applications, then launch Friday. The current repository can produce a team-signed arm64 development package, but public release remains blocked until Developer ID and notary credentials are supplied and the external checks in the release checklist pass.

Friday is arm64/aarch64 end to end and requires Apple Silicon and macOS 14+. The pure-Zig application host, direct macOS C APIs, NeMo Metal runtime, package, CI, and release scripts reject Intel, universal Mach-O slices, and Rosetta translation. The bundle permits launch on macOS 13 only so it can show a clear unsupported-system explanation; setup, downloads, and recording remain disabled there.

Friday asks separately for:

- **Microphone** — required to record.
- **Input Monitoring** — required for the system-global shortcut. Manual menu-bar Start remains available in acknowledged limited mode.
- **Accessibility** — used to return final text to the exact source app. Without it, Friday copies the final text and shows the recovery action.

Recover a revoked permission from Friday’s **Access** page or System Settings → Privacy & Security, then return to Friday; it rechecks live.

Closing Friday’s window hides it without quitting, and the Dock icon follows the window: opening Friday shows it, closing the window removes it, while the always-on **Friday** menu-bar item stays put. Clicking the menu-bar mark opens only its menu; choose **Open Friday…** for the main window, or use the menu to manage models and permissions, start recording, or quit. The mark keeps one identity in every state — red while recording, dimmed while transcribing, and a `!` badge only on failure.

## Dictation

The default shortcut is Command + Shift. Hold the confirmed shortcut to record and release to stop. A quick second press within the selected double-tap window locks recording; use Stop or Cancel afterward. Controls offers Command + Shift and Control + Option conveniences, plus a recorder for Fn/Globe by itself, an F-key, or another key combination. Presets apply immediately. Friday reviews custom candidates, warns about ordinary typing and known reserved/unreliable combinations, and changes the active shortcut only after explicit confirmation.

Normal stop drains capture, visibly enters **transcribing**, runs local final-only ASR, then pastes to the exact captured source when safe. If exact-source paste is unavailable, Friday reports a clipboard fallback. Cancel invalidates the generation immediately; stale results cannot become current. Friday warns at 9:45 and stops at exactly 10:00 while preserving a visible 10-minute explanation through the final outcome.

## Models and offline behavior

On first setup Friday offers its pinned, verified default model automatically when the model step becomes visible. Downloads are user-visible, cancellable, SHA-256 verified, resumable after relaunch, runtime-probed, and atomically installed.

The Models page also supports:

- **Local model** — select a compatible Parakeet TDT GGUF plus its matching Friday manifest sidecar. Friday references the original file and never deletes it.
- **Known Parakeet alternative** — choose Parakeet CTC 1.1B to fill its official repository identifier, then explicitly authorize metadata resolution and exact local verification.
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

Regenerate an intentionally reviewed golden only with `tests/ui-automation.sh --update <scene>`. Verify the checked-in SVG and 1024×1024 PNG icon pair with:

```sh
scripts/verify-icon.sh
```

## Package and release

A local development package requires a real team signing identity because hardened runtime library validation remains enabled:

```sh
FRIDAY_SIGN_IDENTITY="<Apple Development identity hash or name>" npm run package
codesign --verify --deep --strict --verbose=2 zig-out/package/Friday.app
```

The package script signs every embedded dylib, the `Friday.app` bundle, and the development DMG with one team identity, verifies the release-only framework rpath and menu-bar bundle metadata, and replaces the Native SDK’s unsigned scaffold metadata. It does **not** claim notarization.

The public release path is intentionally strict and fails before building if credentials are absent:

```sh
file zig-out/package/Friday.app/Contents/MacOS/friday
lipo -archs zig-out/package/Friday.app/Contents/MacOS/friday
otool -hv zig-out/package/Friday.app/Contents/MacOS/friday
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

- `src/core.ts` — Native SDK entry adapter: Model/Msg contract, effect routing, dictation workflow, and exported view bindings. It compiles to native code; no JavaScript runtime ships.
- `src/state.ts` — default and durable state projections plus readiness invariants.
- `src/protocol.ts` — bounded byte/wire decoding for host responses and events.
- `src/model-transitions.ts` and `src/app-transitions.ts` — pure domain transitions, separate from Native SDK effects.
- `src/automation.ts` — deterministic visual-test fixtures, isolated from production transitions.
- `src/app.native` — Native markup for unsupported/setup/settings/model/permission/diagnostic/result surfaces.
- `native/friday_host.zig` — direct pure-Zig Native SDK host, session owner, command dispatcher, and exactly-once completion registry.
- `native/macos/system.zig` and `json.zig` — platform-service adapter plus typed wire JSON/base64.
- `native/macos/input.zig` — CGEvent/TCC global shortcut capture, validation, press/release, and sleep/wake handling.
- `native/macos/audio.zig` and `ring.zig` — capture/conversion, allocation-free Zig SPSC, bounded storage, drain, and route/failure cleanup.
- `native/macos/models.zig` — `std.http`/files/hash/JSON verified default/local/Hugging Face models, resume, atomic publication, and bounded deletion.
- `native/macos/nemo.zig` — one serialized in-process NeMo C-ABI recognizer.
- `native/macos/delivery.zig` — exact-source AX and Native SDK clipboard delivery with truthful fallback.
- `native/macos/overlay.zig` — nonactivating recording/transcribing capsule.
- `native/macos/objc.zig` — one narrow typed dynamic runtime wrapper per unavoidable AppKit selector; no Objective-C source or bridge.

Known system-context gaps are not hidden: external pointer acceptance for the overlay and successful AX insertion into TextEdit/Terminal/browser fields have not been observed in this loginwindow-bound harness; public notarization cannot run without Developer ID/notary credentials; energy remains an Instruments check. These are release-checklist items, not inferred passes.
