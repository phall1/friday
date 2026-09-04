# Friday

Friday is an Apple Silicon menu-bar dictation app for macOS 14+. Hold a global shortcut to record; release to transcribe locally with a Parakeet model and paste the text into whatever app you were in. No cloud ASR, no transcript history, no telemetry.

## Install from source

One command on an Apple Silicon Mac with Xcode Command Line Tools:

```sh
git clone <your-fork-url> && cd friday
npm run install:app          # or: FRIDAY_PM=bun npm run install:app
```

That script checks the toolchain (Zig 0.16.0, Node 24+ or Bun, an Apple Development signing identity — hardened runtime requires one), builds arm64-only, packages, code-signs, verifies, and installs `Friday.app` into `/Applications` (or `~/Applications` if `/Applications` isn't writable). Re-running it safely replaces the installed copy.

Package manager is pick-your-poison: npm is the default (reproducible via `package-lock.json`); `FRIDAY_PM=bun` is much faster and applies the same patch set.

Requirements and manual equivalent:

```sh
npm ci --ignore-scripts && npx patch-package --error-on-fail
npm run build
FRIDAY_SIGN_IDENTITY="<identity hash>" npm run package
open zig-out/package/Friday.app
```

First launch asks for **Microphone** (recording), **Input Monitoring** (the global shortcut), and **Accessibility** (pasting back into the exact source app). Friday rechecks these live if you revoke or restore them; without Input Monitoring, the menu-bar Start button still works in a limited mode.

## Using it

- Hold the default shortcut (**Command + Shift**) to record; release to transcribe and paste. A double-tap locks recording; **Stop** or **Cancel** ends it. Change the shortcut from the recorder in **Controls** — it warns about ordinary typing keys and reserved combos and only switches after confirmation.
- The menu-bar mark is always present: red while recording, dimmed while transcribing, `!` on failure. Closing the window hides it; the mark stays.
- Recording caps at 10 minutes (warning at 9:45). Cancel invalidates the session immediately — stale results never become current.

## Models

Setup offers a pinned, SHA-verified default Parakeet model with resumable, cancellable downloads. The Models page also accepts a local Parakeet TDT GGUF + manifest sidecar, the known Parakeet CTC 1.1B alternative, or a public Hugging Face `owner/repository` identifier — anything not pinned goes through exact integrity checks and a real local recognizer probe before Friday calls it compatible.

After a model is active, everything works offline; the network is only touched for explicit model actions. Model data lives under `$HOME/Library/Application Support/com.phall.friday/Models`.

## Privacy

Audio and transcription never leave the Mac. No telemetry, no transcript history. Session audio is deleted after cancel, silence, delivery, dismissal, or exit. Safe Diagnostics exports version/model/permission/performance facts only — never transcript text, audio, clipboard, or raw paths.

## Docs

- [User guide](docs/friday-user-guide.md) — day-to-day behavior in detail
- [Module architecture](docs/module-architecture.md) and [technical spec](specs/friday/TECH.md)
- [ASR quality benchmark](docs/asr-quality-benchmark.md)
- [Release checklist](docs/friday-release-checklist.md) — Developer ID + notarization requirements for a public DMG
- [Behavior coverage matrix](docs/friday-behavior-coverage.md)

## Development

```sh
npm run check    # native checks
npm test         # tsx tests + zig build test
npm run quality  # privacy-safe ASR benchmark
```

Strict UI goldens are compared with `tests/ui-automation.sh <scene>` (scene list in the script); regenerate an intentionally reviewed golden only with `--update <scene>`. Verify the icon pair with `scripts/verify-icon.sh`.

### Architecture

- `src/core.ts` — Native SDK entry adapter, dictation workflow, effect routing (compiles to native; no JS runtime ships)
- `src/state.ts`, `src/protocol.ts`, `src/model-transitions.ts`, `src/app-transitions.ts` — durable state projections, bounded wire decoding, pure domain transitions
- `native/friday_host.zig` — pure-Zig host, session owner, exactly-once completion registry
- `native/macos/` — platform adapters: input (CGEvent/TCC shortcut), audio (SPSC ring), models (verified downloads), `nemo.zig` (in-process C-ABI recognizer), delivery (AX paste + clipboard fallback), overlay, and a narrow typed `objc.zig` wrapper

### Release

Local development packages are Apple Development-signed but not notarized. The public release path (`scripts/release-macos.sh`) enforces Developer ID + notary credentials, signs, notarizes with `notarytool --wait`, staples, and runs `spctl` — it fails before building if credentials are absent. Current external blockers and evidence requirements are in the [release checklist](docs/friday-release-checklist.md).

A Homebrew cask is planned once a public notarized DMG exists; Homebrew requires stable, publicly downloadable, notarized artifacts, so install-from-source is the supported path until then.
