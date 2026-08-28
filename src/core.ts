import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";

export type BridgeState = "booting" | "ready" | "failed";
export type HostChannelState = "data" | "closed" | "rejected";
export type HostChannelKey = 7001;
export type WorkflowState = "idle" | "waiting_hold" | "recording" | "transcribing" | "locked" | "failed";
const HOST_CHANNEL_KEY: HostChannelKey = 7001;

export interface Model {
  readonly bridgeState: BridgeState;
  readonly detail: Uint8Array;
  readonly permissions: Uint8Array;
  readonly generation: number;
  readonly hotkeyConfirmed: boolean;
  readonly hotkeyDown: boolean;
  readonly recordingLocked: boolean;
  readonly recordingActive: boolean;
  readonly workflow: WorkflowState;
  readonly pressedAtMs: number;
  readonly lastQuickReleaseAtMs: number;
  readonly doubleTapWindowMs: number;
  readonly minimumHoldMs: number;
  readonly hotkeyDownCount: number;
  readonly hotkeyUpCount: number;
  readonly sourceToken: Uint8Array;
  readonly sessionId: number;
  readonly nextSessionId: number;
  readonly probeResult: Uint8Array;
  readonly overlayAction: Uint8Array;
  readonly audioDetail: Uint8Array;
  readonly modelDetail: Uint8Array;
  readonly modelProgress: Uint8Array;
}

export type Msg =
  | { readonly kind: "host_event"; readonly key: number; readonly state: HostChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "subscribed"; readonly body: Uint8Array }
  | { readonly kind: "subscribe_failed"; readonly error: Uint8Array }
  | { readonly kind: "permissions_loaded"; readonly body: Uint8Array }
  | { readonly kind: "permissions_failed"; readonly error: Uint8Array }
  | { readonly kind: "model_status_loaded"; readonly body: Uint8Array }
  | { readonly kind: "model_failed"; readonly error: Uint8Array }
  | { readonly kind: "confirm_hotkey" }
  | { readonly kind: "hotkey_configured"; readonly body: Uint8Array }
  | { readonly kind: "hotkey_failed"; readonly error: Uint8Array }
  | { readonly kind: "hold_elapsed"; readonly at: number }
  | { readonly kind: "audio_started"; readonly body: Uint8Array }
  | { readonly kind: "audio_finished"; readonly body: Uint8Array }
  | { readonly kind: "audio_failed"; readonly error: Uint8Array }
  | { readonly kind: "start_audio_probe" }
  | { readonly kind: "stop_audio_probe" }
  | { readonly kind: "probe_audio_storage" }
  | { readonly kind: "audio_storage_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_hotkey" }
  | { readonly kind: "hotkey_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_overlay" }
  | { readonly kind: "overlay_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_textedit" }
  | { readonly kind: "textedit_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_terminal" }
  | { readonly kind: "terminal_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_models" }
  | { readonly kind: "models_probed"; readonly body: Uint8Array }
  | { readonly kind: "download_model" }
  | { readonly kind: "model_downloaded"; readonly body: Uint8Array }
  | { readonly kind: "cancel_download" }
  | { readonly kind: "transcribe_fixture" }
  | { readonly kind: "cancel_fixture" }
  | { readonly kind: "fixture_transcribed"; readonly body: Uint8Array }
  | { readonly kind: "unload_model" }
  | { readonly kind: "model_unloaded"; readonly body: Uint8Array }
  | { readonly kind: "probe_failed"; readonly error: Uint8Array }
  | { readonly kind: "show_overlay" }
  | { readonly kind: "hide_overlay" };

export const viewUnbound = [
  "host_event", "subscribed", "subscribe_failed", "permissions_loaded", "permissions_failed",
  "model_status_loaded", "model_failed", "hotkey_configured", "hotkey_failed", "hold_elapsed",
  "audio_started", "audio_finished", "audio_failed", "audio_storage_probed", "hotkey_probed",
  "overlay_probed", "textedit_probed", "terminal_probed", "models_probed", "model_downloaded",
  "fixture_transcribed", "model_unloaded", "probe_failed",
] as const;

function parseUnsigned(bytes: Uint8Array): number {
  let value = 0;
  for (const byte of bytes) {
    if (byte < 48 || byte > 57) return value;
    value = value * 10 + byte - 48;
  }
  return value;
}

function boundedInteger(bytes: Uint8Array, start: number, end: number): number {
  const parsed = parseUnsigned(bytes.slice(start, end));
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 9007199254740991 ? Math.trunc(parsed) : 0;
}

function hasPrefix(bytes: Uint8Array, prefix: Uint8Array): boolean {
  if (bytes.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i += 1) if (bytes[i] !== prefix[i]) return false;
  return true;
}

function findPipe(bytes: Uint8Array, start: number): number {
  for (let i = start; i < bytes.length; i += 1) if (bytes[i] === 124) return i;
  return bytes.length;
}

export function initialModel(): [Model, Cmd<Msg>] {
  return [{
    bridgeState: "booting", detail: utf8Bytes("Connecting to FridayHost…"), permissions: utf8Bytes("Checking permissions…"),
    generation: 0, hotkeyConfirmed: false, hotkeyDown: false, recordingLocked: false, recordingActive: false,
    workflow: "idle", pressedAtMs: 0, lastQuickReleaseAtMs: 0, doubleTapWindowMs: 350, minimumHoldMs: 300,
    hotkeyDownCount: 0, hotkeyUpCount: 0, sourceToken: asciiBytes(""), sessionId: 0, nextSessionId: 1,
    probeResult: asciiBytes("No probe run yet."), overlayAction: asciiBytes("none"), audioDetail: asciiBytes("Audio idle."),
    modelDetail: utf8Bytes("Checking local models…"), modelProgress: asciiBytes("No model operation."),
  }, Cmd.batch([
    Cmd.channelOpen(HOST_CHANNEL_KEY, { event: "host_event" }),
    Cmd.request("friday.subscribe", asciiBytes("7001"), { key: "host-subscribe", ok: "subscribed", err: "subscribe_failed" }),
    Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
    Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_failed" }),
  ])];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "subscribed": return { ...model, bridgeState: "ready", detail: msg.body };
    case "subscribe_failed": return { ...model, bridgeState: "failed", detail: msg.error };
    case "permissions_loaded": return { ...model, permissions: msg.body };
    case "permissions_failed": return { ...model, permissions: msg.error };
    case "model_status_loaded": return { ...model, modelDetail: msg.body };
    case "model_failed": return { ...model, modelDetail: msg.error };
    case "confirm_hotkey": return [model, Cmd.request("friday.hotkey.configure", asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0"), { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "hotkey_configured": return { ...model, hotkeyConfirmed: true, detail: msg.body };
    case "hotkey_failed": return { ...model, hotkeyConfirmed: false, detail: msg.error };
    case "hold_elapsed": {
      if (!model.hotkeyDown || model.recordingActive || model.recordingLocked) return model;
      const session = model.nextSessionId;
      const next = session < 1000000 ? session + 1 : 1;
      return [{ ...model, recordingActive: true, workflow: "recording", sessionId: session, nextSessionId: next }, Cmd.request("friday.audio.start", utf8Bytes(`session=${session};generation=${model.generation}`), { key: "audio-session", ok: "audio_started", err: "audio_failed" })];
    }
    case "audio_started": return { ...model, audioDetail: msg.body, recordingActive: true };
    case "audio_finished": return { ...model, audioDetail: msg.body, recordingActive: false, recordingLocked: false, hotkeyDown: false, workflow: "idle", lastQuickReleaseAtMs: 0 };
    case "audio_failed": return { ...model, audioDetail: msg.error, recordingActive: false, workflow: "failed" };
    case "start_audio_probe": {
      if (model.recordingActive) return model;
      const session = model.nextSessionId;
      const next = session < 1000000 ? session + 1 : 1;
      return [{ ...model, recordingActive: true, workflow: "recording", sessionId: session, nextSessionId: next }, Cmd.request("friday.audio.start", utf8Bytes(`session=${session};generation=${model.generation}`), { key: "audio-session", ok: "audio_started", err: "audio_failed" })];
    }
    case "stop_audio_probe":
      if (!model.recordingActive) return model;
      return [{ ...model, workflow: "transcribing" }, Cmd.request("friday.audio.finish", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_finished", err: "audio_failed" })];
    case "probe_audio_storage": return [model, Cmd.request("friday.audio.storage_probe", asciiBytes(""), { key: "audio-storage", ok: "audio_storage_probed", err: "probe_failed" })];
    case "audio_storage_probed": return { ...model, probeResult: msg.body };
    case "probe_hotkey": return [model, Cmd.request("friday.hotkey.probe", asciiBytes(""), { key: "hotkey-probe", ok: "hotkey_probed", err: "probe_failed" })];
    case "hotkey_probed": return { ...model, probeResult: msg.body };
    case "probe_overlay": return [model, Cmd.request("friday.overlay.probe", asciiBytes(""), { key: "overlay-probe", ok: "overlay_probed", err: "probe_failed" })];
    case "overlay_probed": return { ...model, probeResult: msg.body };
    case "probe_textedit": return [model, Cmd.request("friday.delivery.probe", asciiBytes("TextEdit"), { key: "textedit-probe", ok: "textedit_probed", err: "probe_failed" })];
    case "textedit_probed": return { ...model, probeResult: msg.body };
    case "probe_terminal": return [model, Cmd.request("friday.delivery.probe", asciiBytes("Terminal"), { key: "terminal-probe", ok: "terminal_probed", err: "probe_failed" })];
    case "terminal_probed": return { ...model, probeResult: msg.body };
    case "probe_models": return [model, Cmd.request("friday.model.probes", asciiBytes(""), { key: "model-probes", ok: "models_probed", err: "probe_failed" })];
    case "models_probed": return { ...model, probeResult: msg.body };
    case "download_model": return [{ ...model, modelProgress: utf8Bytes("Starting default model download…") }, Cmd.request("friday.model.download", utf8Bytes(`generation=${model.generation}`), { key: "model-download", ok: "model_downloaded", err: "model_failed" })];
    case "model_downloaded": return { ...model, modelDetail: msg.body, modelProgress: asciiBytes("Default model installed and warm.") };
    case "cancel_download": return [{ ...model, modelProgress: utf8Bytes("Cancelling model download…") }, Cmd.batch([Cmd.cancel("model-download"), Cmd.host("friday.model.cancel", asciiBytes("0"))])];
    case "transcribe_fixture": {
      const generation = model.generation < 1000000 ? model.generation + 1 : 1;
      return [{ ...model, generation, audioDetail: asciiBytes("Fixture transcription running.") }, Cmd.request("friday.nemo.transcribe_path", utf8Bytes(`session=999;generation=${generation};path=L3RtcC9mcmlkYXktZml4dHVyZS5mMzI=`), { key: "fixture-transcription", ok: "fixture_transcribed", err: "audio_failed" })];
    }
    case "cancel_fixture": return [{ ...model, audioDetail: asciiBytes("Fixture transcription cancelled.") }, Cmd.cancel("fixture-transcription")];
    case "fixture_transcribed": return { ...model, audioDetail: msg.body };
    case "unload_model": return [model, Cmd.request("friday.nemo.unload", asciiBytes(""), { key: "nemo-unload", ok: "model_unloaded", err: "model_failed" })];
    case "model_unloaded": return { ...model, modelDetail: msg.body };
    case "probe_failed": return { ...model, probeResult: msg.error };
    case "show_overlay": return [model, Cmd.host("friday.overlay.show", asciiBytes("locked"))];
    case "hide_overlay": return [model, Cmd.host("friday.overlay.hide", asciiBytes(""))];
    case "host_event": {
      if (msg.state !== "data" || msg.key !== HOST_CHANNEL_KEY) return model;
      if (msg.droppedPending > 0 || msg.droppedTotal > 0) return [{ ...model, hotkeyDown: false, recordingLocked: false, recordingActive: false, workflow: "failed", detail: asciiBytes("FridayHost event back-pressure invalidated the active session.") }, Cmd.host("friday.overlay.hide", asciiBytes(""))];
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_down|"))) {
        const generationEnd = findPipe(msg.bytes, 12), atEnd = findPipe(msg.bytes, generationEnd + 1), tokenEnd = findPipe(msg.bytes, atEnd + 1);
        const rawGeneration = boundedInteger(msg.bytes, 12, generationEnd), rawAt = boundedInteger(msg.bytes, generationEnd + 1, atEnd);
        const generation = Number.isFinite(rawGeneration) && rawGeneration > model.generation && rawGeneration <= 9007199254740991 ? Math.trunc(rawGeneration) : 0;
        const at = Number.isFinite(rawAt) && rawAt > 0 && rawAt <= 9007199254740991 ? Math.trunc(rawAt) : 0;
        if (generation === 0 || at === 0) return model;
        if (model.recordingLocked) return [{ ...model, generation, hotkeyDown: false, recordingLocked: false, workflow: "transcribing" }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.request("friday.audio.finish", utf8Bytes(`session=${model.sessionId};generation=${generation}`), { key: "audio-session", ok: "audio_finished", err: "audio_failed" }), Cmd.host("friday.overlay.transcribing", asciiBytes(""))])];
        const delta = at >= model.lastQuickReleaseAtMs ? at - model.lastQuickReleaseAtMs : model.doubleTapWindowMs + 1;
        const lock = model.lastQuickReleaseAtMs > 0 && delta <= model.doubleTapWindowMs;
        const nextDown = model.hotkeyDownCount < 1000000 ? model.hotkeyDownCount + 1 : model.hotkeyDownCount;
        if (lock) {
          const session = model.nextSessionId, next = session < 1000000 ? session + 1 : 1;
          return [{ ...model, generation, hotkeyDown: true, recordingLocked: true, recordingActive: true, workflow: "locked", pressedAtMs: at, hotkeyDownCount: nextDown, sourceToken: msg.bytes.slice(atEnd + 1, tokenEnd), sessionId: session, nextSessionId: next, lastQuickReleaseAtMs: 0 }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.request("friday.audio.start", utf8Bytes(`session=${session};generation=${generation}`), { key: "audio-session", ok: "audio_started", err: "audio_failed" }), Cmd.host("friday.overlay.show", asciiBytes("locked"))])];
        }
        return [{ ...model, generation, hotkeyDown: true, recordingLocked: false, workflow: "waiting_hold", pressedAtMs: at, hotkeyDownCount: nextDown, sourceToken: msg.bytes.slice(atEnd + 1, tokenEnd) }, Cmd.batch([Cmd.delay("hold-start", model.minimumHoldMs, "hold_elapsed"), Cmd.host("friday.overlay.show", asciiBytes("held"))])];
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_up|"))) {
        const generationEnd = findPipe(msg.bytes, 10), rawGeneration = boundedInteger(msg.bytes, 10, generationEnd), rawAt = boundedInteger(msg.bytes, generationEnd + 1, msg.bytes.length);
        const generation = Number.isFinite(rawGeneration) && rawGeneration >= 0 && rawGeneration <= 9007199254740991 ? Math.trunc(rawGeneration) : 0;
        const at = Number.isFinite(rawAt) && rawAt >= 0 && rawAt <= 9007199254740991 ? Math.trunc(rawAt) : 0;
        if (generation !== model.generation || !model.hotkeyDown || at < model.pressedAtMs) return model;
        const nextUp = model.hotkeyUpCount < 1000000 ? model.hotkeyUpCount + 1 : model.hotkeyUpCount;
        if (model.recordingLocked) return { ...model, hotkeyUpCount: nextUp };
        const duration = at - model.pressedAtMs;
        if (model.recordingActive) return [{ ...model, hotkeyDown: false, workflow: "transcribing", hotkeyUpCount: nextUp, lastQuickReleaseAtMs: 0 }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.request("friday.audio.finish", utf8Bytes(`session=${model.sessionId};generation=${generation}`), { key: "audio-session", ok: "audio_finished", err: "audio_failed" }), Cmd.host("friday.overlay.transcribing", asciiBytes(""))])];
        const quickValue = duration < model.minimumHoldMs && duration <= model.doubleTapWindowMs ? at : 0;
        const quickRelease = Number.isFinite(quickValue) && quickValue >= 0 && quickValue <= 9007199254740991 ? Math.trunc(quickValue) : 0;
        return [{ ...model, hotkeyDown: false, workflow: "idle", hotkeyUpCount: nextUp, lastQuickReleaseAtMs: quickRelease }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_cancel|"))) return [{ ...model, hotkeyDown: false, recordingLocked: false, recordingActive: false, workflow: "failed", lastQuickReleaseAtMs: 0, sourceToken: asciiBytes("") }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.cancel("audio-session"), Cmd.host("friday.source.discard", model.sourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      if (hasPrefix(msg.bytes, asciiBytes("overlay_stop|"))) return [{ ...model, hotkeyDown: false, recordingLocked: false, overlayAction: asciiBytes("stop"), workflow: model.recordingActive ? "transcribing" : "idle" }, model.recordingActive ? Cmd.request("friday.audio.finish", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_finished", err: "audio_failed" }) : Cmd.host("friday.overlay.hide", asciiBytes(""))];
      if (hasPrefix(msg.bytes, asciiBytes("overlay_cancel|"))) return [{ ...model, hotkeyDown: false, recordingLocked: false, recordingActive: false, overlayAction: asciiBytes("cancel"), workflow: "idle", sourceToken: asciiBytes("") }, Cmd.batch([Cmd.cancel("audio-session"), Cmd.host("friday.source.discard", model.sourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      if (hasPrefix(msg.bytes, asciiBytes("model_progress|"))) return { ...model, modelProgress: msg.bytes };
      if (hasPrefix(msg.bytes, asciiBytes("duration_warning|"))) return { ...model, audioDetail: asciiBytes("Recording stops automatically in 15 seconds.") };
      if (hasPrefix(msg.bytes, asciiBytes("duration_limit|")) && model.recordingActive) return [{ ...model, workflow: "transcribing" }, Cmd.request("friday.audio.finish", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_finished", err: "audio_failed" })];
      return model;
    }
  }
}
