import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";

export type HostChannelState = "data" | "closed" | "rejected";
export type HostChannelKey = 7001;
export type DeliveryKind = "pasted" | "clipboard" | "shown";
export type FailureStage = "capture" | "model" | "transcription" | "delivery";
export type RecordingControl = "held" | "locked";
export type StopDisposition = "transcribe" | "discard" | "cancel" | "duration_limit";
const HOST_CHANNEL_KEY: HostChannelKey = 7001;


export type DictationWorkflow =
  | { readonly kind: "booting" }
  | { readonly kind: "not_ready" }
  | { readonly kind: "ready"; readonly modelKey: number }
  | { readonly kind: "starting"; readonly lockCandidate: boolean }
  | { readonly kind: "recording"; readonly control: RecordingControl; readonly warnedDurationLimit: boolean }
  | { readonly kind: "stopping"; readonly disposition: StopDisposition }
  | { readonly kind: "transcribing"; readonly retryAudioAvailable: boolean }
  | { readonly kind: "delivering" }
  | { readonly kind: "failed"; readonly stage: FailureStage; readonly retryAudioAvailable: boolean };

export interface Model {
  readonly workflow: DictationWorkflow;
  readonly sessionId: number;
  readonly generation: number;
  readonly pressedAtMs: number;
  readonly lastQuickReleaseAtMs: number;
  readonly capturedFrames: number;
  readonly sessionSourceToken: Uint8Array;
  readonly workflowMessage: Uint8Array;
  readonly hasImmediateResult: boolean;
  readonly immediateResultKind: DeliveryKind;
  readonly immediateResultMessage: Uint8Array;
  readonly permissionsLoaded: boolean;
  readonly modelsLoaded: boolean;
  readonly microphonePermission: boolean;
  readonly accessibilityPermission: boolean;
  readonly inputMonitoringPermission: boolean;
  readonly modelReady: boolean;
  readonly selectedModelKey: number;
  readonly onboardingComplete: boolean;
  readonly limitedModeAccepted: boolean;
  readonly hotkeyConfirmed: boolean;
  readonly doubleTapEnabled: boolean;
  readonly doubleTapWindowMs: number;
  readonly minimumHoldMs: number;
  readonly overlayEnabled: boolean;
  readonly pasteAutomatically: boolean;
  readonly launchAtLogin: boolean;
  readonly ambientDetail: Uint8Array;
}

export type Msg =
  | { readonly kind: "host_event"; readonly key: number; readonly state: HostChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "subscribed"; readonly body: Uint8Array }
  | { readonly kind: "subscribe_failed"; readonly error: Uint8Array }
  | { readonly kind: "permissions_loaded"; readonly body: Uint8Array }
  | { readonly kind: "permissions_failed"; readonly error: Uint8Array }
  | { readonly kind: "model_status_loaded"; readonly body: Uint8Array }
  | { readonly kind: "model_status_failed"; readonly error: Uint8Array }
  | { readonly kind: "model_downloaded"; readonly body: Uint8Array }
  | { readonly kind: "model_download_failed"; readonly error: Uint8Array }
  | { readonly kind: "restored" }
  | { readonly kind: "fresh_boot" }
  | { readonly kind: "restore_failed"; readonly error: Uint8Array }
  | { readonly kind: "confirm_hotkey" }
  | { readonly kind: "hotkey_configured"; readonly body: Uint8Array }
  | { readonly kind: "hotkey_failed"; readonly error: Uint8Array }
  | { readonly kind: "request_microphone" }
  | { readonly kind: "request_accessibility" }
  | { readonly kind: "request_input_monitoring" }
  | { readonly kind: "complete_onboarding" }
  | { readonly kind: "toggle_double_tap" }
  | { readonly kind: "toggle_overlay" }
  | { readonly kind: "toggle_paste" }
  | { readonly kind: "toggle_launch_at_login" }
  | { readonly kind: "start_recording" }
  | { readonly kind: "stop_recording" }
  | { readonly kind: "cancel_active" }
  | { readonly kind: "hold_elapsed"; readonly at: number }
  | { readonly kind: "audio_started"; readonly body: Uint8Array }
  | { readonly kind: "audio_start_failed"; readonly error: Uint8Array }
  | { readonly kind: "transcript_ready"; readonly body: Uint8Array }
  | { readonly kind: "transcription_failed"; readonly error: Uint8Array }
  | { readonly kind: "delivery_finished"; readonly body: Uint8Array }
  | { readonly kind: "delivery_failed"; readonly error: Uint8Array }
  | { readonly kind: "retry_transcription" }
  | { readonly kind: "source_captured"; readonly body: Uint8Array }
  | { readonly kind: "source_capture_failed"; readonly error: Uint8Array }
  | { readonly kind: "dismiss_failure" }
  | { readonly kind: "debug_fixture_requested"; readonly value: Uint8Array }
  | { readonly kind: "debug_fixture_finished"; readonly body: Uint8Array }
  | { readonly kind: "debug_fixture_failed"; readonly error: Uint8Array }
  | { readonly kind: "dismiss_result" };

export const envMsgs = [
  { env: "FRIDAY_AUTOMATION_FIXTURE", msg: "debug_fixture_requested" },
] as const;

export const viewUnbound = [
  "host_event", "subscribed", "subscribe_failed", "permissions_loaded", "permissions_failed",
  "model_status_loaded", "model_status_failed", "model_downloaded", "model_download_failed",
  "restored", "fresh_boot", "restore_failed", "source_captured", "source_capture_failed", "hotkey_configured", "hotkey_failed", "hold_elapsed",
  "audio_started", "audio_start_failed", "transcript_ready", "transcription_failed",
  "delivery_finished", "delivery_failed", "debug_fixture_requested", "debug_fixture_finished", "debug_fixture_failed", "sessionSourceToken", "workflowMessage",
] as const;

function hasPrefix(bytes: Uint8Array, prefix: Uint8Array): boolean {
  if (bytes.length < prefix.length) return false;
  for (let index = 0; index < prefix.length; index += 1) if (bytes[index] !== prefix[index]) return false;
  return true;
}

function contains(bytes: Uint8Array, needle: Uint8Array): boolean {
  if (needle.length === 0) return true;
  if (bytes.length < needle.length) return false;
  for (let start = 0; start <= bytes.length - needle.length; start += 1) {
    let match = true;
    for (let index = 0; index < needle.length; index += 1) if (bytes[start + index] !== needle[index]) match = false;
    if (match) return true;
  }
  return false;
}

function findPipe(bytes: Uint8Array, start: number): number {
  for (let index = start; index < bytes.length; index += 1) if (bytes[index] === 124) return index;
  return bytes.length;
}

function parseUnsigned(bytes: Uint8Array, start: number, end: number): number {
  let value = 0;
  for (let index = start; index < end; index += 1) {
    const byte = bytes[index];
    if (byte < 48 || byte > 57) return 0;
    value = value * 10 + byte - 48;
  }
  if (!Number.isFinite(value) || value < 0 || value > 9007199254740991) return 0;
  return Math.trunc(value);
}

function jsonInteger(bytes: Uint8Array, key: Uint8Array): number {
  if (key.length === 0 || bytes.length < key.length) return 0;
  for (let start = 0; start <= bytes.length - key.length; start += 1) {
    let match = true;
    for (let index = 0; index < key.length; index += 1) if (bytes[start + index] !== key[index]) match = false;
    if (!match) continue;
    let end = start + key.length;
    while (end < bytes.length && bytes[end] >= 48 && bytes[end] <= 57) end += 1;
    return parseUnsigned(bytes, start + key.length, end);
  }
  return 0;
}

function eventMatches(bytes: Uint8Array, prefix: Uint8Array, model: Model): boolean {
  if (!hasPrefix(bytes, prefix)) return false;
  const generationEnd = findPipe(bytes, prefix.length);
  const sessionEnd = findPipe(bytes, generationEnd + 1);
  const generation = parseUnsigned(bytes, prefix.length, generationEnd);
  const session = parseUnsigned(bytes, generationEnd + 1, sessionEnd);
  return generation === model.generation && session === model.sessionId;
}

function defaultModel(): Model {
  return {
    workflow: { kind: "booting" },
    sessionId: 0 / 1,
    generation: 0 / 1,
    pressedAtMs: 0 / 1,
    lastQuickReleaseAtMs: 0 / 1,
    capturedFrames: 0 / 1,
    sessionSourceToken: asciiBytes(""),
    workflowMessage: asciiBytes(""),
    hasImmediateResult: false,
    immediateResultKind: "shown",
    immediateResultMessage: asciiBytes(""),
    permissionsLoaded: false,
    modelsLoaded: false,
    microphonePermission: false,
    accessibilityPermission: false,
    inputMonitoringPermission: false,
    modelReady: false,
    selectedModelKey: 0 / 1,
    onboardingComplete: false,
    limitedModeAccepted: false,
    hotkeyConfirmed: false,
    doubleTapEnabled: true,
    doubleTapWindowMs: 350 / 1,
    minimumHoldMs: 300 / 1,
    overlayEnabled: true,
    pasteAutomatically: true,
    launchAtLogin: false,
    ambientDetail: utf8Bytes("Checking permissions and local model readiness…"),
  };
}

export function migrate(snapshot: Uint8Array, fromVersion: number): Model {
  if (fromVersion === 1 && snapshot.length >= 0) return defaultModel();
  return defaultModel();
}

function readiness(model: Model): DictationWorkflow {
  if (!model.permissionsLoaded || !model.modelsLoaded) return { kind: "booting" };
  if (!model.microphonePermission) return { kind: "not_ready" };

  if (!model.inputMonitoringPermission) return { kind: "not_ready" };
  if (!model.hotkeyConfirmed) return { kind: "not_ready" };
  if (!model.modelReady || model.selectedModelKey === 0) return { kind: "not_ready" };
  if (!model.onboardingComplete && !model.limitedModeAccepted) return { kind: "not_ready" };
  return { kind: "ready", modelKey: model.selectedModelKey };
}
function durableModel(model: Model): Model {
  return {
    ...model,
    workflow: { kind: "booting" },
    sessionId: 0 / 1,
    generation: 0 / 1,
    pressedAtMs: 0 / 1,
    lastQuickReleaseAtMs: 0 / 1,
    capturedFrames: 0 / 1,
    sessionSourceToken: asciiBytes(""),
    workflowMessage: asciiBytes(""),
    hasImmediateResult: false,
    immediateResultKind: "shown",
    immediateResultMessage: asciiBytes(""),
    permissionsLoaded: false,
    modelsLoaded: false,
    microphonePermission: false,
    accessibilityPermission: false,
    inputMonitoringPermission: false,
    modelReady: false,
    ambientDetail: asciiBytes(""),
  };
}

function notReadyMessage(model: Model): Uint8Array {
  if (!model.microphonePermission) return utf8Bytes("Microphone permission is required before recording.");
  if (!model.inputMonitoringPermission) return utf8Bytes("Input Monitoring permission is required for the global hotkey.");
  if (!model.hotkeyConfirmed) return utf8Bytes("Confirm a global hotkey to enable dictation.");
  if (!model.modelReady || model.selectedModelKey === 0) return utf8Bytes("Download or select a compatible Parakeet TDT GGUF model.");
  return utf8Bytes("Complete onboarding before using Friday.");
}


export function initialModel(): [Model, Cmd<Msg>] {
  return [defaultModel(), Cmd.batch([
    Cmd.channelOpen(HOST_CHANNEL_KEY, { event: "host_event" }),
    Cmd.request("friday.subscribe", asciiBytes("7001"), { key: "host-subscribe", ok: "subscribed", err: "subscribe_failed" }),
    Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
    Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
  ])];
}

export function workflowName(model: Model): Uint8Array {
  switch (model.workflow.kind) {
    case "booting": return asciiBytes("booting");
    case "not_ready": return asciiBytes("not ready");
    case "ready": return asciiBytes("ready");
    case "starting": return asciiBytes("starting");
    case "recording": return asciiBytes("recording");
    case "stopping": return asciiBytes("stopping");
    case "transcribing": return asciiBytes("transcribing");
    case "delivering": return asciiBytes("delivering");
    case "failed": return asciiBytes("failed");
  }
}
export function workflowDetail(model: Model): Uint8Array {
  switch (model.workflow.kind) {
    case "booting": return utf8Bytes("Checking Friday’s local services…");
    case "not_ready": return notReadyMessage(model);
    case "ready": return model.hasImmediateResult ? model.immediateResultMessage : asciiBytes("Ready for local dictation.");
    case "starting": return asciiBytes("Waiting for an intentional hold or second tap.");
    case "recording": return model.workflow.control === "locked" ? asciiBytes("Recording is locked. Press the hotkey or Stop to finish.") : asciiBytes("Recording while the hotkey is held.");
    case "stopping": return asciiBytes("Draining captured audio.");
    case "transcribing": return asciiBytes("Transcribing locally with the selected model.");
    case "delivering": return asciiBytes("Delivering only the final transcript to the exact source.");
    case "failed": return model.workflowMessage;
  }
}
export function isReady(model: Model): boolean { return model.workflow.kind === "ready"; }
export function isRecording(model: Model): boolean { return model.workflow.kind === "recording"; }
export function isLocked(model: Model): boolean { return model.workflow.kind === "recording" && model.workflow.control === "locked"; }
export function isBusy(model: Model): boolean { return model.workflow.kind === "starting" || model.workflow.kind === "recording" || model.workflow.kind === "stopping" || model.workflow.kind === "transcribing" || model.workflow.kind === "delivering"; }
export function canRetry(model: Model): boolean { return model.workflow.kind === "failed" && model.workflow.stage === "transcription" && model.workflow.retryAudioAvailable; }
export function permissionSummary(model: Model): Uint8Array {
  if (!model.permissionsLoaded) return utf8Bytes("Checking…");
  if (model.microphonePermission && model.accessibilityPermission && model.inputMonitoringPermission) return asciiBytes("Microphone, Accessibility, and Input Monitoring granted.");
  if (!model.microphonePermission) return asciiBytes("Microphone missing.");
  if (!model.inputMonitoringPermission) return asciiBytes("Input Monitoring missing.");
  return asciiBytes("Accessibility missing; Friday will use clipboard fallback.");
}
export function modelSummary(model: Model): Uint8Array { return model.modelReady ? asciiBytes("Parakeet TDT model ready.") : asciiBytes("No compatible model ready."); }


export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "subscribed": return { ...model, ambientDetail: msg.body };
    case "subscribe_failed": return { ...model, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "debug_fixture_requested":
      return [model, Cmd.request("friday.debug.fixture_delivery", msg.value, { key: "debug-fixture", ok: "debug_fixture_finished", err: "debug_fixture_failed" })];
    case "debug_fixture_finished":
      return { ...model, hasImmediateResult: true, immediateResultKind: contains(msg.body, asciiBytes("\"kind\":\"clipboard\"")) ? "clipboard" : "shown", immediateResultMessage: msg.body, ambientDetail: msg.body };
    case "debug_fixture_failed":
      return { ...model, hasImmediateResult: true, immediateResultKind: "shown", immediateResultMessage: msg.error, ambientDetail: msg.error };
    case "restored": {
      const restored = durableModel(model);
      if (restored.hotkeyConfirmed) return [restored, Cmd.batch([
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
        Cmd.request("friday.hotkey.configure", asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0"), { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" }),
      ])];
      return [restored, Cmd.batch([
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
    }
    case "fresh_boot": return [durableModel(model), Cmd.batch([
      Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
      Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
    ])];
    case "restore_failed": return [durableModel(model), Cmd.batch([
      Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
      Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
    ])];
    case "permissions_loaded": {
      const next = { ...model,
        permissionsLoaded: true,
        microphonePermission: contains(msg.body, asciiBytes("\"microphone\":true")),
        accessibilityPermission: contains(msg.body, asciiBytes("\"accessibility\":1")) || contains(msg.body, asciiBytes("\"accessibility\":true")),
        inputMonitoringPermission: contains(msg.body, asciiBytes("\"inputMonitoring\":true")),
        ambientDetail: msg.body,
      };
      if (model.workflow.kind === "booting" || model.workflow.kind === "not_ready" || model.workflow.kind === "ready") return { ...next, workflow: readiness(next) };
      return next;
    }
    case "permissions_failed": return { ...model, permissionsLoaded: true, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "model_status_loaded": {
      const key = jsonInteger(msg.body, asciiBytes("\"activeModelKey\":"));
      const ready =
          key > 0 &&
          contains(msg.body, asciiBytes("\"activeModelReady\":true"));
      const selectedKey = key > 0 ? key / 1 : 0 / 1;
      const next = { ...model, modelsLoaded: true, modelReady: ready, selectedModelKey: selectedKey, ambientDetail: msg.body };
      if (!ready && !model.onboardingComplete) return [{ ...next, workflow: readiness(next) }, Cmd.request("friday.model.download", asciiBytes(""), { key: "model-download", ok: "model_downloaded", err: "model_download_failed" })];
      if (model.workflow.kind === "booting" || model.workflow.kind === "not_ready" || model.workflow.kind === "ready") return { ...next, workflow: readiness(next) };
      return next;
    }
    case "model_status_failed": return { ...model, modelsLoaded: true, modelReady: false, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "model_downloaded": {
      const next = { ...model, modelsLoaded: true, modelReady: true, selectedModelKey: 1 / 1, ambientDetail: msg.body };
      const durable = durableModel(next);
      return [durable, Cmd.batch([
        Cmd.persist(),
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
    }
    case "model_download_failed": return { ...model, modelsLoaded: true, modelReady: false, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "confirm_hotkey": return [model, Cmd.request("friday.hotkey.configure", asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0"), { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "hotkey_configured": {
      const next = { ...model, hotkeyConfirmed: true, ambientDetail: msg.body };
      const durable = durableModel(next);
      return [durable, Cmd.batch([
        Cmd.persist(),
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
    }
    case "hotkey_failed": return { ...model, hotkeyConfirmed: false, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "request_microphone": return [model, Cmd.request("friday.permissions.request", asciiBytes("microphone"), { key: "permission-request", ok: "permissions_loaded", err: "permissions_failed" })];
    case "request_accessibility": return [model, Cmd.request("friday.permissions.request", asciiBytes("accessibility"), { key: "permission-request", ok: "permissions_loaded", err: "permissions_failed" })];
    case "request_input_monitoring": return [model, Cmd.request("friday.permissions.request", asciiBytes("input"), { key: "permission-request", ok: "permissions_loaded", err: "permissions_failed" })];
    case "complete_onboarding": {
      if (!model.microphonePermission || !model.inputMonitoringPermission || !model.hotkeyConfirmed || !model.modelReady) return model;
      const durable = durableModel({ ...model, onboardingComplete: true });
      return [durable, Cmd.batch([
        Cmd.persist(),
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
    }
    case "toggle_double_tap": {
      if (isBusy(model)) return model;
      const durable = durableModel({ ...model, doubleTapEnabled: !model.doubleTapEnabled });
      return [durable, Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    }
    case "toggle_overlay": {
      if (isBusy(model)) return model;
      const durable = durableModel({ ...model, overlayEnabled: !model.overlayEnabled });
      return [durable, Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    }
    case "toggle_paste": {
      if (isBusy(model)) return model;
      const durable = durableModel({ ...model, pasteAutomatically: !model.pasteAutomatically });
      return [durable, Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    }
    case "toggle_launch_at_login": {
      if (isBusy(model)) return model;
      const durable = durableModel({ ...model, launchAtLogin: !model.launchAtLogin });
      return [durable, Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    }
    case "start_recording": {
      if (model.workflow.kind !== "ready") return model;
      return [{ ...model, workflow: { kind: "starting", lockCandidate: false }, sessionId: 0 / 1, generation: 0 / 1, pressedAtMs: 0 / 1 }, Cmd.request("friday.source.capture", asciiBytes(""), { key: "source-capture", ok: "source_captured", err: "source_capture_failed" })];
    }
    case "source_captured": {
      if (model.workflow.kind !== "starting" || model.generation !== 0) return model;
      const generation = jsonInteger(msg.body, asciiBytes("\"generation\":"));
      if (generation === 0) return model;
      const current = model.workflow;
      const safeGeneration = generation / 1;
      return [{ ...model, workflow: current, sessionId: safeGeneration, generation: safeGeneration }, Cmd.request("friday.audio.start", asciiBytes(""), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" })];
    }
    case "source_capture_failed": {
      if (model.workflow.kind !== "starting") return model;
      const current = model.workflow;
      return { ...model, workflow: { kind: "failed", stage: "capture", retryAudioAvailable: false }, workflowMessage: msg.error };
    }
    case "stop_recording": {
      if (model.workflow.kind !== "recording") return model;
      const current = model.workflow;
      return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.request("friday.audio.finish", asciiBytes(""), { key: "audio-session", ok: "transcript_ready", err: "transcription_failed" })];
    }
    case "cancel_active": {
      if (!isBusy(model) && model.workflow.kind !== "failed") return model;
      const source = model.workflow.kind === "ready" || model.workflow.kind === "not_ready" || model.workflow.kind === "booting" ? asciiBytes("") : model.sessionSourceToken;
      return [{ ...model, workflow: readiness(model) }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.cancel("audio-session"), Cmd.host("friday.source.discard", source), Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
    }
    case "hold_elapsed": {
      if (model.workflow.kind !== "starting" || model.workflow.lockCandidate) return model;
      const current = model.workflow;
      return [model, Cmd.request("friday.audio.start", asciiBytes(""), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" })];
    }
    case "audio_started": {
      if (model.workflow.kind !== "starting") return model;
      const session = jsonInteger(msg.body, asciiBytes("\"sessionId\":"));
      if (session !== model.sessionId) return model;
      const current = model.workflow;
      return { ...model, capturedFrames: 0 / 1, workflow: { kind: "recording", control: current.lockCandidate ? "locked" : "held", warnedDurationLimit: false } };
    }
    case "audio_start_failed": {
      if (model.workflow.kind !== "starting") return model;
      const current = model.workflow;
      return { ...model, workflow: { kind: "failed", stage: "capture", retryAudioAvailable: false }, workflowMessage: msg.error };
    }
    case "transcript_ready": {
      if (model.workflow.kind !== "stopping" && model.workflow.kind !== "transcribing") return model;
      const current = model.workflow;
      const session = jsonInteger(msg.body, asciiBytes("\"sessionId\":"));
      const generation = jsonInteger(msg.body, asciiBytes("\"generation\":"));
      if (session !== model.sessionId || generation !== model.generation) return model;
      if (contains(msg.body, asciiBytes("\"silence\":true"))) return [{ ...model, hasImmediateResult: true, immediateResultKind: "shown", sessionSourceToken: asciiBytes(""), immediateResultMessage: asciiBytes("No speech detected."), lastQuickReleaseAtMs: 0 / 1, workflow: { kind: "ready", modelKey: model.selectedModelKey } }, Cmd.batch([Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.source.discard", model.sessionSourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      const deliverSession = Number.isFinite(session) && session > 0 && session <= 9007199254740991 ? Math.trunc(session) : 0;
      const deliverGeneration = Number.isFinite(generation) && generation > 0 && generation <= 9007199254740991 ? Math.trunc(generation) : 0;
      if (deliverSession === 0 || deliverGeneration === 0) return model;
      return [{ ...model, workflow: { kind: "delivering" } }, Cmd.request("friday.deliver_session", utf8Bytes(`session=${deliverSession};generation=${deliverGeneration};paste=${model.pasteAutomatically ? 1 : 0}`), { key: "delivery", ok: "delivery_finished", err: "delivery_failed" })];
    }
    case "transcription_failed": {
      if (model.workflow.kind !== "stopping" && model.workflow.kind !== "transcribing") return model;
      const current = model.workflow;
      const session = jsonInteger(msg.error, asciiBytes("\"sessionId\":"));
      const generation = jsonInteger(msg.error, asciiBytes("\"generation\":"));
      if (session !== model.sessionId || generation !== model.generation) return model;
      return { ...model, workflow: { kind: "failed", stage: "transcription", retryAudioAvailable: contains(msg.error, asciiBytes("\"retryAudioAvailable\":true")) }, workflowMessage: msg.error };
    }
    case "delivery_finished": {
      if (model.workflow.kind !== "delivering") return model;
      const session = jsonInteger(msg.body, asciiBytes("\"sessionId\":"));
      const generation = jsonInteger(msg.body, asciiBytes("\"generation\":"));
      if (session !== model.sessionId || generation !== model.generation) return model;
      const kind: DeliveryKind = contains(msg.body, asciiBytes("\"kind\":\"pasted\"")) ? "pasted" : contains(msg.body, asciiBytes("\"kind\":\"clipboard\"")) ? "clipboard" : "shown";
      return { ...model, hasImmediateResult: true, immediateResultKind: kind, sessionSourceToken: asciiBytes(""), immediateResultMessage: msg.body, workflow: { kind: "ready", modelKey: model.selectedModelKey } };
    }
    case "delivery_failed": {
      if (model.workflow.kind !== "delivering") return model;
      const current = model.workflow;
      return { ...model, workflow: { kind: "failed", stage: "delivery", retryAudioAvailable: false }, workflowMessage: msg.error };
    }
    case "retry_transcription": {
      if (model.workflow.kind !== "failed" || model.workflow.stage !== "transcription" || !model.workflow.retryAudioAvailable) return model;
      const current = model.workflow;
      return [{ ...model, workflow: { kind: "transcribing", retryAudioAvailable: true } }, Cmd.request("friday.audio.retry", asciiBytes(""), { key: "audio-session", ok: "transcript_ready", err: "transcription_failed" })];
    }
    case "dismiss_failure": {
      if (model.workflow.kind !== "failed") return model;
      const current = model.workflow;
      return [{ ...model, workflow: readiness(model) }, Cmd.batch([Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.source.discard", model.sessionSourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
    }
    case "dismiss_result": {
      if (model.workflow.kind !== "ready") return model;
      return { ...model, hasImmediateResult: false, immediateResultMessage: asciiBytes("") };
    }
    case "host_event": {
      if (msg.state !== "data" || msg.key !== HOST_CHANNEL_KEY) return model;
      if (msg.droppedPending > 0 || msg.droppedTotal > 0) return [{ ...model, workflow: { kind: "not_ready" }, workflowMessage: asciiBytes("FridayHost event back-pressure invalidated the active session.") }, Cmd.batch([Cmd.cancel("audio-session"), Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      if (hasPrefix(msg.bytes, asciiBytes("permissions|"))) return [model, Cmd.batch([
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_down|"))) {
        const generationEnd = findPipe(msg.bytes, 12);
        const atEnd = findPipe(msg.bytes, generationEnd + 1);
        const tokenEnd = findPipe(msg.bytes, atEnd + 1);
        const generation = parseUnsigned(msg.bytes, 12, generationEnd);
        const at = parseUnsigned(msg.bytes, generationEnd + 1, atEnd);
        const token = msg.bytes.slice(atEnd + 1, tokenEnd);
        if (generation === 0 || at === 0) return model;
        if (model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping") {
          const old = model.workflow;
          const session = generation;
          const workflow: DictationWorkflow = { kind: "starting", lockCandidate: false };
          return [{ ...model, workflow, sessionId: session / 1, generation: generation / 1, pressedAtMs: at / 1, sessionSourceToken: token }, Cmd.batch([
            Cmd.cancel("audio-session"), Cmd.cancel("delivery"),
            Cmd.host("friday.audio.discard", asciiBytes("")),
            Cmd.host("friday.source.discard", model.sessionSourceToken),
            Cmd.delay("hold-start", 300, "hold_elapsed"),
            model.overlayEnabled ? Cmd.host("friday.overlay.show", asciiBytes("held")) : Cmd.none,
          ])];
        }
        if (model.workflow.kind === "recording" && model.workflow.control === "locked") {
          const current = model.workflow;
          return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.batch([Cmd.host("friday.source.discard", token), Cmd.request("friday.audio.finish", asciiBytes(""), { key: "audio-session", ok: "transcript_ready", err: "transcription_failed" }), Cmd.host("friday.overlay.transcribing", asciiBytes(""))])];
        }
        if (model.workflow.kind !== "ready") return model;
        const session = generation;
        const delta = at >= model.lastQuickReleaseAtMs ? at - model.lastQuickReleaseAtMs : model.doubleTapWindowMs + 1;
        const lockCandidate = model.doubleTapEnabled && model.lastQuickReleaseAtMs > 0 && delta <= model.doubleTapWindowMs;
        const workflow: DictationWorkflow = { kind: "starting", lockCandidate };
        if (lockCandidate) return [{ ...model, workflow, sessionId: session / 1, generation: generation / 1, pressedAtMs: at / 1, sessionSourceToken: token }, Cmd.batch([
          Cmd.request("friday.audio.start", asciiBytes(""), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" }),
          model.overlayEnabled ? Cmd.host("friday.overlay.show", asciiBytes("locked")) : Cmd.none,
        ])];
        return [{ ...model, workflow, sessionId: session / 1, generation: generation / 1, pressedAtMs: at / 1, sessionSourceToken: token }, Cmd.batch([
          Cmd.delay("hold-start", 300, "hold_elapsed"),
          model.overlayEnabled ? Cmd.host("friday.overlay.show", asciiBytes("held")) : Cmd.none,
        ])];
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_up|"))) {
        const generationEnd = findPipe(msg.bytes, 10);
        const generation = parseUnsigned(msg.bytes, 10, generationEnd);
        const at = parseUnsigned(msg.bytes, generationEnd + 1, msg.bytes.length);
        if (model.workflow.kind === "recording") {
          if (generation !== model.generation || at < model.pressedAtMs) return model;
          if (model.workflow.control === "locked") return model;
          const current = model.workflow;
          return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.batch([Cmd.request("friday.audio.finish", asciiBytes(""), { key: "audio-session", ok: "transcript_ready", err: "transcription_failed" }), Cmd.host("friday.overlay.transcribing", asciiBytes(""))])];
        }
        if (model.workflow.kind === "starting") {
          if (generation !== model.generation || at < model.pressedAtMs) return model;
          const current = model.workflow;
          const duration = at - model.pressedAtMs;
          const quick = duration < model.minimumHoldMs && duration <= model.doubleTapWindowMs ? at / 1 : 0 / 1;
          return [{ ...model, hasImmediateResult: false, sessionSourceToken: asciiBytes(""), immediateResultMessage: asciiBytes(""), lastQuickReleaseAtMs: quick, workflow: { kind: "ready", modelKey: model.selectedModelKey } }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.host("friday.source.discard", model.sessionSourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
        }
        return model;
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_cancel|")) || hasPrefix(msg.bytes, asciiBytes("overlay_cancel|"))) return update(model, { kind: "cancel_active" });
      if (hasPrefix(msg.bytes, asciiBytes("overlay_stop|"))) return update(model, { kind: "stop_recording" });
      if (eventMatches(msg.bytes, asciiBytes("duration_warning|"), model) &&
          model.workflow.kind === "recording")
        return { ...model, workflow: { ...model.workflow, warnedDurationLimit: true } };
      if (eventMatches(msg.bytes, asciiBytes("duration_limit|"), model) &&
          model.workflow.kind === "recording")
        return [{ ...model, workflow: { kind: "stopping", disposition: "duration_limit" } },
                Cmd.request("friday.audio.finish", asciiBytes(""),
                            { key: "audio-session", ok: "transcript_ready",
                              err: "transcription_failed" })];
      if (eventMatches(msg.bytes, asciiBytes("audio_interrupted|"), model) &&
          (model.workflow.kind === "recording" ||
           model.workflow.kind === "starting"))
        return [{ ...model,
                  workflow: { kind: "failed", stage: "capture",
                              retryAudioAvailable: false },
                  workflowMessage: msg.bytes,
                  sessionSourceToken: asciiBytes("") },
                Cmd.batch([Cmd.cancel("audio-session"),
                           Cmd.host("friday.audio.discard", asciiBytes("")),
                           Cmd.host("friday.source.discard",
                                    model.sessionSourceToken),
                           Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      return model;
    }
  }
}
