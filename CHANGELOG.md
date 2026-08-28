# Changelog

All notable changes to Friday are documented here.

## [Unreleased]

### Added

- Apple Silicon/macOS 14 launch probe with non-dismissible unsupported-hardware/system UI and a Quit-only unsupported status menu.
- Recorded custom key/function-key shortcuts, explicit candidate confirmation, reserved/unreliable shortcut warnings, and safe modifier-only conveniences.
- Safe public Hugging Face `owner/repository` candidate resolution with immutable revision, one top-level GGUF, ASR/GGUF hints, LFS SHA/size, license, attribution, explicit download-for-verification authorization, resumable transfer, bounded GGUF inspection, real runtime probe, and atomic publication only after verification.
- Visible paused/resumable model downloads with exact downloaded/total byte labels after relaunch.
- Explicit recording → stop/drain → visible transcribing → local ASR sequencing and persistent 10-minute-limit outcome copy.
- State-preserving signed packaged E2E, packaged negative probes, PRODUCT 1–154 coverage matrix, and measured p95 performance harness.
- Strict macOS CI for dependency/patch verification, Native check/build/tests, icon reproducibility, and twelve accessibility/keyboard/golden scenes.
- Developer ID/notarytool release script with nested/app/DMG timestamps, app and DMG notarization/stapling, and Gatekeeper assessment.
- Friday user guide and release checklist.

### Changed

- Replaced Native SDK scaffold documentation and unsigned package metadata with Friday-specific, signature-truthful content.
- Development packaging now signs embedded dylibs, app, and DMG with a real team identity while preserving hardened runtime and library validation.
- Persistence schema advances with safe migration and continues to scrub transient source/audio/transcript/result/diagnostic/automation/model-resolution facts.
- Replaced the settings-dashboard/card stack with a precision-studio interface: compact navigation rail, live waveform transport stage, etched settings rows, audio-rack model library, focused onboarding ceremony, and technical diagnostic ledger.
- Forced arm64/aarch64 throughout target resolution, Objective-C++ compilation, aarch64 NeMo Metal selection, CI, packaging, diagnostics, and release. Intel, universal Mach-O slices, and Rosetta translation now fail closed; architecture-bearing artifacts use the `-arm64` suffix.

### Security and privacy

- Diagnostics and performance evidence explicitly exclude transcript text, microphone audio, clipboard contents, document names, and raw paths.
- Packaged validation preserves/restores user state and pasteboard contents, never deletes installed user models, and never changes TCC grants.
- Model cleanup and managed deletion remain bounded to Friday-owned roots; local model removal remains reference-only.

### External release blockers

- Developer ID Application and authenticated notary credentials are not available in the current environment, so notarization is not claimed.
- External-pointer overlay acceptance and successful AX insertion into TextEdit, Terminal, and browser fields require a normal logged-in GUI session; the current harness proves nonactivation contracts and truthful clipboard fallback only.
- Energy remains an explicit Instruments Energy Log release check.
