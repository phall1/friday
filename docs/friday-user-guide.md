# Friday User Guide

## Requirements and installation

Friday supports Apple Silicon Macs running macOS 14 or later. Intel Macs are unsupported. A macOS 13 launch can show the unsupported-system explanation, but Friday disables setup, downloads, and recording.

For a public release, open the notarized arm64-only `Friday-0.1.0-arm64.dmg`, drag Friday to Applications, and launch it there. A development build may be team-signed but unnotarized; it is for local validation, not redistribution. Friday never ships an Intel or universal slice and refuses to run through Rosetta.

Friday lives in the menu bar and does not open its main window after completed setup. Clicking the menu-bar item opens only its menu; choose **Open Friday…** when you want the main window. Closing that window does not quit Friday. Use **Quit Friday** in the menu to stop it.

## Setup and permissions

Friday explains and requests each permission separately:

1. **Microphone** records speech. Friday cannot record without it.
2. **Accessibility** lets Friday return final text to the exact app where dictation began. Without it, final text is copied instead of pasted.
3. **Input Monitoring** lets Friday observe the confirmed global shortcut while another app is focused. Without it, manual **Start Recording** remains available after limited-mode acknowledgement.

Friday does not mark a permission usable merely because a request was made. It polls the actual macOS state and rechecks when the app becomes active.

If access is denied or later revoked:

1. Open Friday → **Permission Status**.
2. Choose the recovery action for the missing permission.
3. In System Settings → Privacy & Security, enable Friday for that permission.
4. Return to Friday. It rechecks automatically; use the page action again if macOS has not refreshed yet.

A missing Microphone permission blocks recording. Missing Input Monitoring disables the global shortcut but not manual Start. Missing Accessibility changes delivery to a clearly reported clipboard fallback.

## Shortcut behavior

The initial convenience is **Command + Shift**. **Control + Option** is also available. The two presets apply immediately. To choose Fn/Globe, an F-key, or another key combination:

1. Open Settings → Shortcut.
2. Choose **Change Shortcut…**.
3. Press and release **Fn/Globe** by itself, an F-key, or another key combination.
4. Review the displayed candidate and any warning.
5. Choose **Use This Shortcut** only when enabled. Until then, your existing shortcut remains active.

Friday rejects ordinary unmodified typing and warns about known macOS-reserved, standard app-command, modifier-only reliability, and indistinguishable combinations. Capturing or discarding a candidate never disables the active shortcut.

### Hold and double-tap

- Press and hold the shortcut; recording begins after the deliberate hold threshold. Release to stop and transcribe.
- A very short first press seeds double-tap detection without recording usable audio.
- Press again within the selected Fast (250 ms), Balanced (300 ms), or Deliberate (400 ms) window to lock recording.
- A locked session continues after release. Use **Stop Recording** to transcribe or **Cancel** to discard.
- A normal long hold never seeds a later lock.

Friday allows one active session. Cancel invalidates it immediately, and late results from that generation are ignored.

## Recording, transcription, and delivery

The menu-bar and settings surfaces distinguish ready, recording, transcribing, failure, and not-ready without relying on color alone. The optional compact overlay shows elapsed recording, Stop for locked recording, Cancel, and a separate Hide action that does not cancel.

Normal Stop performs these steps:

1. Stop accepting microphone frames.
2. Drain and flush conversion/storage.
3. Commit and show the transcribing state.
4. Run final-only local Parakeet inference.
5. Return the final text to the exact captured source when it is still safe.

Friday never shows or delivers partial text. It never guesses a different destination. Outcomes are explicit:

- **Pasted** — exact-source automatic delivery succeeded.
- **Copied** — automatic paste was unavailable or unsafe; the final text is on the clipboard.
- **Shown** — clipboard fallback also failed; Friday shows the final text with a Copy action.
- **No speech detected** — nothing was pasted or copied.

Friday warns at 9:45 and stops at exactly 10:00. The final message continues to say that the 10-minute limit was reached, including silence and clipboard outcomes.

If transcription fails and retry audio is available, choose **Retry Transcription**. Dismiss, Cancel, a new session, successful delivery, or app exit removes retained session audio.

## Models

### Verified default model

The setup model page offers **Parakeet TDT 0.6B v3**, pinned to an immutable Hugging Face revision, exact byte count, and SHA-256. Friday shows downloaded and total bytes, supports explicit Cancel/Retry, resumes a valid partial after relaunch, verifies size/hash, probes the runtime, and publishes atomically before selection.

### Local model

Choose **Add Local Model…** and select a compatible Parakeet TDT GGUF with its matching Friday manifest sidecar. The sidecar must identify engine/family/format, immutable identity, exact size/SHA, license, languages, and required artifacts. Friday references user-owned local files. **Remove from Friday** removes only the reference and never deletes the original.

### Public Hugging Face model

Enter a public `owner/repository` identifier. Friday first asks permission to contact Hugging Face for public metadata. Resolution can produce only an **Unverified candidate**, and only when metadata establishes:

- a public, ungated repository and immutable 40-hex revision,
- exactly one top-level `.gguf` artifact,
- ASR/GGUF hints,
- LFS SHA-256 and exact byte size,
- bounded license and attribution.

Repository names, tags, and claims do not prove model family or compatibility. Friday shows the exact candidate metadata and asks whether to download those bytes for local verification. The download must pass size/SHA, bounded GGUF metadata inspection, and the real local NeMo recognizer create/destroy probe. Only then does Friday publish and select it as compatible. When bounded GGUF metadata does not prove Parakeet TDT but the supported final-ASR runtime probe succeeds, Friday records the truthful family `runtime_verified_asr` rather than inventing a Parakeet label. Private, gated, ambiguous, unhashed, malformed, non-ASR-hinted, or runtime-rejected candidates never become selectable.

### Offline use, storage, and removal

Once a verified active model is installed, capture and transcription operate offline. Network access is limited to explicit metadata resolution and model downloads. Model hosting providers can see the identifier/download request during those actions.

Friday-managed data is under:

```text
$HOME/Library/Application Support/com.phall.friday/Models
$HOME/Library/Application Support/com.phall.friday/ModelDownloads
```

**Delete Friday’s Copy** appears only for Friday-managed models and refuses paths outside that root. **Clean Failed and Partial Downloads** removes only failed/partial download staging, not installed models. Do not hand-edit `index.json`, managed manifests, or partial resume metadata.

## Privacy and retention

- Dictation audio and ASR stay on the Mac.
- Friday has no cloud-ASR or telemetry path.
- Friday stores no transcript history.
- The deterministic persisted state excludes transcript/result/failure/source/session bytes, diagnostics, permission/model-list facts, automation state, shortcut candidates, and unconfirmed Hugging Face metadata.
- Temporary audio is removed on cancel, silence, success, fallback, dismissal, superseding session, converter/route failure, launch sweep, and exit. Only the current failed transcription may retain retry audio until the user retries or dismisses it.
- Friday does not include transcript text, audio, clipboard data, document names, or raw paths in diagnostics.

## Safe Diagnostics

Open **Safe Diagnostics** to inspect versions, platform/permission usability, model identity/integrity/storage, bounded timing/RSS/drop counters, and safe error codes. The diagnostic object includes explicit `transcriptIncluded=false`, `audioIncluded=false`, and `rawPathsIncluded=false` flags.

- **Refresh** obtains current facts.
- **Copy Diagnostics** copies the safe diagnostic JSON.
- **Export and Reveal** writes the safe JSON under Friday’s application-support Diagnostics directory and reveals it.

Review the JSON before sharing it. Audio or transcript collection is never implicit.

## Recovery

- **Unsupported Mac/system:** use a supported Apple Silicon Mac on macOS 14+. Setup and recording remain disabled.
- **Permission denied/revoked:** use Permission Status and System Settings; Friday rechecks live.
- **Shortcut conflict:** record a different candidate and explicitly save it.
- **Download failed/canceled:** use Retry/Resume or remove the partial. Friday does not silently loop.
- **Model incompatible/corrupt:** choose a compatible verified model; it cannot become active.
- **Recording route/converter failure:** the session is canceled, partial audio is deleted, and Friday reports a recoverable microphone error.
- **Transcription failure:** Retry if retained audio is offered, change model, or dismiss to ready.
- **Paste failure:** use the reported clipboard/shown result; Friday never claims a paste it did not perform.

## Known external validation gaps

The implementation and hermetic/signed harness prove truthful fallback and AppKit nonactivation contracts. In the current loginwindow-bound automation environment, an external pointer could not reach the overlay panel, and successful AX insertion into TextEdit, Terminal, and browser fields could not be observed because those apps could not become the controlling frontmost app. Validate both in a normal interactive user session before public release.

Public Gatekeeper distribution also remains blocked until a Developer ID Application identity and notary profile run the strict release script successfully. Energy impact remains an explicit Instruments Energy Log validation because no trustworthy noninteractive replacement is used.
