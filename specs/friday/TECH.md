# Friday TECH

## Context and decision

Friday implements [PRODUCT.md](./PRODUCT.md) as an Apple Silicon macOS menu-bar dictation app. There is no existing app code.

Use one architecture:

> **Vercel Labs Native SDK deterministic TypeScript core + one deep macOS `FridayHost` adapter + in-process NeMo-Speech.cpp ASR C ABI.**

The TypeScript core owns product state and sequencing. `FridayHost` owns global input, permission usability, source-app identity, microphone capture, model storage/activation, NeMo lifetime, and final delivery. Audio and native handles never enter TypeScript `Model`.

Official assumptions:

- [Native SDK TypeScript core/effects](https://native-sdk.dev/docs/typescript): `Model`/`Msg`/pure `update`, `Cmd` effects, status items, windows, and bounded microphone capture.
- [Native SDK services](https://native-sdk.dev/docs/typescript/services): imperative TypeScript services are not a general FFI surface; platform work belongs in the host/Zig layer.
- [Native SDK macOS support](https://native-sdk.dev/docs/platform-support), [overlay windows](https://native-sdk.dev/docs/windows#overlay-windows), [packaging](https://native-sdk.dev/docs/packaging), [ejection](https://native-sdk.dev/docs/cli), and [testing](https://native-sdk.dev/docs/testing).
- [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp), [ASR C ABI](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/sdk.md), [build guide](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/build.md), and [model guide](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/cli.md). The C API uses opaque handles and accepts mono Float32 at 8–96 kHz.
- [NeMo checkpoints](https://docs.nvidia.com/nemo/speech/nightly/asr/asr_checkpoints.html) and [Parakeet v3 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) currently disagree on language scope. Pin an immutable artifact/revision/SHA and display capabilities from its manifest.

Native SDK does not document Friday's required system-global press/release hotkey or paste into a previously focused app. Its overlay flags also do not prove interactive Stop/Cancel can remain nonactivating. These requirements are **not reduced**: isolate them in `FridayHost` and prove them in signed-app spikes before the full build.

Hex lessons transferred:

- Hotkeys: `../hex/HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift`, `RecordingDecision.swift`, `Constants.swift`, and `HexCore/Tests/HexCoreTests/HotKeyProcessorTests.swift`.
- Input permission resilience: `../hex/Hex/Clients/KeyEventMonitorClient.swift`.
- Session/generation and route handling: `../hex/Hex/Clients/RecordingClient.swift` and `SuperFastCaptureController.swift`.
- Source capture/stale cleanup: `../hex/Hex/Features/Transcription/TranscriptionFeature.swift`.
- Clipboard preservation/fallback: `../hex/Hex/Clients/PasteboardClient.swift`.
- Model readiness: `../hex/Hex/Features/Settings/ModelDownload/ModelDownloadFeature.swift`.

Reject Hex's workflow booleans, giant `RecordingClientLive`, dual inference engines, legacy cache scans, approximate progress, full-screen `InvisibleWindow`, media control, AppleScript Paste-menu traversal, and disabled library validation.

## Module shape

```text
app.json
build.zig                         # owned via native eject
src/
  core.ts                         # Model, Msg, update, status item/windows
  domain/{workflow,hotkey,model}.ts
  app.native
  windows/{onboarding,model-manager,overlay,diagnostics}.native
native/
  friday_host.zig                 # Native command/channel registration
  include/friday_host.h
  macos/
    FridayHost.mm                 # serial session owner
    GlobalInputMonitor.mm
    AudioSession.mm
    ModelRepository.mm
    NemoRecognizer.mm             # concrete, no backend protocol
    TextDelivery.mm
    OverlayWindow.mm
resources/{models,licenses}/
```

Core owns the single workflow, onboarding/settings state, session IDs, stale-event rejection, legal commands, menu/windows, and user-facing errors. It does not own PCM, paths/bookmarks, PIDs, AX objects, NeMo handles, or clipboard objects.

`FridayHost` serializes session commands. `GlobalInputMonitor` owns CGEvent/TCC facts; `AudioSession` owns AVAudioEngine; `ModelRepository` owns model bytes/manifests; `NemoRecognizer` owns the one active NeMo handle; `TextDelivery` owns exact-target paste/fallback; `OverlayWindow` fills only the interactive-nonactivation gap. Inference never runs on the audio callback or UI thread.

## Core/native interface

```ts
interface HotkeySpec {
  readonly key: Uint8Array; // empty = modifier-only
  readonly command: boolean; readonly shift: boolean;
  readonly option: boolean; readonly control: boolean; readonly fn: boolean;
  readonly doubleTapEnabled: boolean;
  readonly doubleTapWindowMs: number;
  readonly minimumHoldMs: number;
}
interface SourceTarget {
  readonly token: Uint8Array; // opaque/session-scoped
  readonly appName: Uint8Array; readonly bundleId: Uint8Array;
}
interface StartRequest { readonly sessionId: number; readonly modelKey: number; readonly requestedAtMs: number }
interface StartResult {
  readonly sessionId: number; readonly source: SourceTarget;
  readonly captureStartedAtMs: number; readonly firstAudioAtMs: number;
  readonly sampleRate: number; readonly channels: number;
}
interface TranscriptResult {
  readonly sessionId: number; readonly text: Uint8Array;
  readonly audioDurationMs: number; readonly captureStoppedAtMs: number;
  readonly inferenceStartedAtMs: number; readonly transcriptReadyAtMs: number;
  readonly retryAudioAvailable: boolean;
}
type DeliveryKind = "pasted" | "clipboard" | "shown";
interface DeliverResult {
  readonly sessionId: number; readonly kind: DeliveryKind;
  readonly pastePostedAtMs: number; readonly message: Uint8Array;
}
type HostEvent =
  | { readonly kind: "hotkey_down"; readonly atMs: number; readonly source: SourceTarget }
  | { readonly kind: "hotkey_up"; readonly atMs: number }
  | { readonly kind: "escape"; readonly atMs: number }
  | { readonly kind: "meter"; readonly sessionId: number; readonly rms: number; readonly peak: number; readonly capturedFrames: number }
  | { readonly kind: "permissions"; readonly microphone: boolean; readonly accessibility: boolean; readonly inputMonitoring: boolean }
  | { readonly kind: "audio_interrupted"; readonly sessionId: number; readonly reason: Uint8Array }
  | { readonly kind: "model_progress"; readonly operationId: number; readonly state: ModelOperationState; readonly downloadedBytes: number; readonly totalBytes: number }
  | { readonly kind: "host_fault"; readonly sessionId: number; readonly code: Uint8Array; readonly message: Uint8Array };
```

`friday_host.zig` supplies typed `Cmd<Msg>` constructors: `hostSubscribe`, `hostConfigureHotkey`, `hostStart`, `hostFinish`, `hostCancel`, `hostRetryTranscription`, `hostDeliver`, and `hostModelOperation`. `hostFinish` is deep: stop/drain capture, confirm active model, run final-only inference, and return one result. The core never coordinates WAV paths or NeMo handles.

## Single workflow

```ts
type SetupBlocker = "unsupported_platform" | "microphone_permission" | "input_monitoring_permission" | "hotkey" | "model";
type RecordingControl = "held" | "locked";
type StopDisposition = "transcribe" | "discard" | "cancel" | "duration_limit";
type FailureStage = "capture" | "model" | "transcription" | "delivery";
interface ImmediateResult { readonly kind: DeliveryKind; readonly text: Uint8Array; readonly message: Uint8Array }
type DictationWorkflow =
  | { readonly kind: "booting" }
  | { readonly kind: "not_ready"; readonly blockers: readonly SetupBlocker[]; readonly message: Uint8Array }
  | { readonly kind: "ready"; readonly modelKey: number; readonly lastQuickReleaseAtMs: number; readonly result: ImmediateResult | null }
  | { readonly kind: "starting"; readonly sessionId: number; readonly modelKey: number; readonly source: SourceTarget; readonly pressedAtMs: number; readonly lockCandidate: boolean }
  | { readonly kind: "recording"; readonly sessionId: number; readonly modelKey: number; readonly source: SourceTarget; readonly pressedAtMs: number; readonly control: RecordingControl; readonly capturedFrames: number; readonly rms: number; readonly peak: number; readonly warnedDurationLimit: boolean }
  | { readonly kind: "stopping"; readonly sessionId: number; readonly modelKey: number; readonly source: SourceTarget; readonly disposition: StopDisposition }
  | { readonly kind: "transcribing"; readonly sessionId: number; readonly modelKey: number; readonly source: SourceTarget; readonly audioDurationMs: number; readonly retryAudioAvailable: boolean }
  | { readonly kind: "delivering"; readonly sessionId: number; readonly modelKey: number; readonly source: SourceTarget; readonly transcript: Uint8Array }
  | { readonly kind: "failed"; readonly stage: FailureStage; readonly sessionId: number; readonly modelKey: number; readonly message: Uint8Array; readonly retryAudioAvailable: boolean; readonly transcript: Uint8Array | null };
```

No separate `isRecording`/`isTranscribing` fields.

Rules: readiness requires platform, usable mic/input monitoring, confirmed hotkey, and active model. A second start preserves the current recording; a start during transcription cancels/invalidates it and starts fresh. Every native fact has `sessionId`; stale facts are ignored. Short modifier-only holds below `max(minimumHoldMs, 300)` discard. Double-tap locks only on unambiguous intent. Warn at 9:45; finish at exactly 10:00. Only current nonempty final text enters delivery. Delivery truthfully returns pasted/clipboard/shown. Failed transcription retains retry audio only until Retry, dismiss, new session, or exit.

## Event and audio flow

`global hotkey → host event with source token → pure transition → hostStart → 16 kHz capture → release/locked stop → hostFinish → NeMo recognize_f32 → final text → hostDeliver exact source → pasted/clipboard/shown → ready`.

Canonical audio: 16,000 Hz, mono, normalized Float32 `[-1,1]`, ordered frames, final-only, maximum 600 seconds. Hardware input is converted off the realtime callback. A bounded single-producer queue feeds conversion/temp storage; known dropped frames fail the session rather than silently transcribe corruption. No warm/pre-roll mic in v1.

Converted audio uses a session Float32 temp file; ten minutes is ~38.4 MB. Core receives meter summaries at ≤15 Hz, never PCM. Delete audio on cancel/discard/silence/success/fallback/dismiss/stale; retain only failed-session audio needed for explicit Retry; sweep stale files at launch.

## Models

```text
Application Support/Friday/Models/<id>/<revision>/{manifest.json,model.gguf,companions...}
Application Support/Friday/ModelDownloads/<operation-id>/{download.partial,resume.json}
```

Manifest fields: schema/version, numeric key, ID/display name, source kind, immutable HF repository/revision, engine=`nemo_speech_cpp`, family=`parakeet_tdt`, format=`gguf`, artifact/companions, SHA-256, expected/installed bytes, languages, license/attribution, managed flag, compatibility.

Default manifest pins revision, size, SHA, license, and attribution. Downloads stage outside ready models, support cancel, verify size/hash/companions, fsync, run a background recognizer create/destroy probe, then atomically rename. Failed/canceled downloads are never selectable or invisibly retried. Active model cannot switch during a session. Cleanup only deletes Friday-managed roots.

Compatible custom models are readable GGUF bundles identifying a NeMo-Speech-supported Parakeet TDT architecture, with all companions, and passing the runtime probe. HF IDs must resolve to an immutable supported GGUF revision with integrity/license metadata and explicit user confirmation. Reject `.nemo`, PyTorch, Core ML, ONNX, arbitrary GGUF families/repositories, and in-app conversion. Removing a user local model removes only Friday's reference.

## Delivery and UI

Capture exact source at hotkey down. Delivery: validate current/nonempty/source; focus exact source and try AX insertion; otherwise snapshot rich pasteboard, write/commit text, focus exact source, synthesize Command-V; restore old clipboard only after supported success. On failure leave/copy text to clipboard; if that fails show immediate result with Copy. Never guess another app.

UI direction:

- Menu bar derives ready/recording/transcribing/error/not-ready plus Start/Stop/Cancel, Settings, Model Manager, Permission Status, Launch at Login, Quit.
- Overlay is a 120–180 × 36–44 pt voice capsule on the source display: truthful meter + elapsed time; lock with Stop/Cancel; held Cancel/release cue; transcribing pulse + Cancel; no partial text; movable/dismissible; reduced-motion form.
- Onboarding: platform → three permissions → hotkey → default model → ready/explicit limited mode.
- Settings: privacy, permissions, shortcut/practice, model/storage, system mic level, delivery/overlay, login, diagnostics.
- Model Manager: active/available/source/license/size, Add Local/HF, Retry/Cancel/Remove, total managed usage.

Use native typography, 8/12/16 spacing, graphite neutral, coral recording, amber errors, and state/audio-driven motion. No dashboards, analytics, gradients, AI sparkles, or transcript feed.

## Packaging, privacy, performance

Target `aarch64-macos`, macOS 14+. Pin Native SDK/NeMo. `native eject`; link Objective-C++ host and NeMo Metal libraries. Preserve RPATH/runtime under `Contents/Frameworks`, include licenses, sign nested libraries then app, hardened runtime, notarized DMG. Do not disable library validation. Direct-distribution v1 does not depend on App Sandbox; use minimum TCC descriptions/entitlements and revisit sandbox only after signed hotkey/paste proof. Default model downloads during onboarding.

No remote telemetry. Logs contain session ID, stage, safe code, pinned model revision, timings, and drop counts; never transcript, PCM, clipboard, raw local paths, document titles, or field contents. Diagnostics export safe versions/permissions/manifest/integrity/disk/timings/errors. Audio/transcript inclusion requires explicit opt-in.

Budgets to validate, not observed claims: hotkey→first sample p95 ≤75 ms; zero clipped-leading fixture; stop→drain p95 ≤100 ms; warm 5-second stop→text p95 ≤1,000 ms on baseline M1; text→delivery p95 ≤75 ms; no ordinary dropped frames or >16 ms UI stalls. Probe every stage and measure cold/warm, 0.5/2/5/15-second and 10-minute recordings, route/sleep changes, default/local model, RSS, and energy.

## Validation mapped to PRODUCT

- **1–12:** platform/menu, source target, one session, cancel-old/start-new, stale facts.
- **13–25:** onboarding, separate permissions, limited mode, live recheck, readiness.
- **26–54, 147–149:** model progress/cancel/retry/offline/integrity/compatibility/switch/remove/disk/privacy.
- **55–68, 150–152:** true global hotkey, conflicts, hold/lock/ambiguity, ordinary typing rejection, mic gate; port Hex table cases.
- **69–82:** nonactivating accessible overlay, controls, elapsed, no partial, transcribing Cancel.
- **83–110:** cancel/stale, delivery fallback, silence, short/long, 10-minute limit, route/model/inference failure/retry.
- **111–146, 153–154:** diagnostics/menu/settings/login/accessibility/persistence/revocation and v1 non-goals/recovery.

Use pure core/effect assertions; hermetic model HTTP/cache and GGUF fixtures; signed TCC/global-input/paste tests; AVAudioEngine interruption/cancel/quit tests; Native headless UI/automation/accessibility screenshots; packaged `.app` scenarios in TextEdit, Terminal, and browser fields.

## Blocking spikes and sequence

Before full build:

1. Ejected Native build registers command/channel, links Objective-C++, packages/signs without library-validation exception.
2. Signed global hotkey proves press/release, modifier-only, double-tap, sleep/wake, revoke/regrant across apps.
3. Signed automatic paste proves exact-source delivery and truthful fallback; no wrong-app paste.
4. Interactive overlay Stop/Cancel does not activate Friday or steal source focus.
5. Embedded NeMo Metal loads pinned v3, transcribes/cancels/faults/unloads in packaged app; record latency/RSS.
6. Audio proves queue/conversion/route loss/retry cleanup/exact 10 minutes.
7. Model repository proves resumable cancel, SHA failure, atomic install, local probe, constrained HF resolution.

Spikes 1–5 block full implementation. Then freeze crossing types/workflow/fake host; build shell; implement input/permissions, audio, models/NeMo, transcription, delivery, UI/login/diagnostics; finally run mapped tests, budgets, signing, notarization. Hotkey and automatic paste are not late polish.

## Rejected alternatives

- **Managed sidecar:** warm/crash-isolated, but adds IPC versioning, restart/backoff, split-brain sessions, helper TCC identity, orphan handling, and nested signing. Reconsider only if embedded instability is measured.
- **One-shot `nemo-speech` CLI:** useful benchmark/diagnostic harness, but pays process/model/Metal startup per dictation and leaks WAV/process semantics upward. Not a runtime backend.
