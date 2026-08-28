import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";

export type BridgeState = "booting" | "ready" | "failed";
export type HostChannelState = "data" | "closed" | "rejected";
export type HostChannelKey = 7001;
const HOST_CHANNEL_KEY: HostChannelKey = 7001;

export interface Model {
  readonly bridgeState: BridgeState;
  readonly detail: Uint8Array;
  readonly permissions: Uint8Array;
  readonly hotkeyConfirmed: boolean;
  readonly hotkeyDown: boolean;
  readonly recordingLocked: boolean;
  readonly pressedAtMs: number;
  readonly lastQuickReleaseAtMs: number;
  readonly hotkeyDownCount: number;
  readonly hotkeyUpCount: number;
  readonly sourceToken: Uint8Array;
  readonly probeResult: Uint8Array;
  readonly overlayAction: Uint8Array;
}

export type Msg =
  | { readonly kind: "host_event"; readonly key: number; readonly state: HostChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "subscribed"; readonly body: Uint8Array }
  | { readonly kind: "subscribe_failed"; readonly error: Uint8Array }
  | { readonly kind: "permissions_loaded"; readonly body: Uint8Array }
  | { readonly kind: "permissions_failed"; readonly error: Uint8Array }
  | { readonly kind: "confirm_hotkey" }
  | { readonly kind: "hotkey_configured"; readonly body: Uint8Array }
  | { readonly kind: "hotkey_failed"; readonly error: Uint8Array }
  | { readonly kind: "probe_hotkey" }
  | { readonly kind: "hotkey_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_overlay" }
  | { readonly kind: "overlay_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_textedit" }
  | { readonly kind: "textedit_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_terminal" }
  | { readonly kind: "terminal_probed"; readonly body: Uint8Array }
  | { readonly kind: "probe_failed"; readonly error: Uint8Array }
  | { readonly kind: "show_overlay" }
  | { readonly kind: "hide_overlay" };

export const viewUnbound = [
  "host_event", "subscribed", "subscribe_failed", "permissions_loaded",
  "permissions_failed", "hotkey_configured", "hotkey_failed", "hotkey_probed",
  "overlay_probed", "textedit_probed", "terminal_probed", "probe_failed",
] as const;

function parseUnsigned(bytes: Uint8Array): number {
  let value = 0;
  for (const byte of bytes) {
    if (byte < 48 || byte > 57) return value;
    value = value * 10 + byte - 48;
  }
  return value;
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
  return [
    {
      bridgeState: "booting",
      detail: utf8Bytes("Connecting to FridayHost…"),
      permissions: utf8Bytes("Checking permissions…"),
      hotkeyConfirmed: false,
      hotkeyDown: false,
      recordingLocked: false,
      pressedAtMs: 0,
      lastQuickReleaseAtMs: 0,
      hotkeyDownCount: 0,
      hotkeyUpCount: 0,
      sourceToken: asciiBytes(""),
      probeResult: asciiBytes("No probe run yet."),
      overlayAction: asciiBytes("none"),
    },
    Cmd.batch([
      Cmd.channelOpen(HOST_CHANNEL_KEY, { event: "host_event" }),
      Cmd.request("friday.subscribe", asciiBytes("7001"), { key: "host-subscribe", ok: "subscribed", err: "subscribe_failed" }),
      Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
    ]),
  ];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "subscribed": return { ...model, bridgeState: "ready", detail: msg.body };
    case "subscribe_failed": return { ...model, bridgeState: "failed", detail: msg.error };
    case "permissions_loaded": return { ...model, permissions: msg.body };
    case "permissions_failed": return { ...model, permissions: msg.error };
    case "confirm_hotkey":
      return [model, Cmd.request("friday.hotkey.configure", asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0"), { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "hotkey_configured": return { ...model, hotkeyConfirmed: true, detail: msg.body };
    case "hotkey_failed": return { ...model, hotkeyConfirmed: false, detail: msg.error };
    case "probe_hotkey": return [model, Cmd.request("friday.hotkey.probe", asciiBytes(""), { key: "hotkey-probe", ok: "hotkey_probed", err: "probe_failed" })];
    case "hotkey_probed": return { ...model, probeResult: msg.body };
    case "probe_overlay": return [model, Cmd.request("friday.overlay.probe", asciiBytes(""), { key: "overlay-probe", ok: "overlay_probed", err: "probe_failed" })];
    case "overlay_probed": return { ...model, probeResult: msg.body };
    case "probe_textedit": return [model, Cmd.request("friday.delivery.probe", asciiBytes("TextEdit"), { key: "textedit-probe", ok: "textedit_probed", err: "probe_failed" })];
    case "textedit_probed": return { ...model, probeResult: msg.body };
    case "probe_terminal": return [model, Cmd.request("friday.delivery.probe", asciiBytes("Terminal"), { key: "terminal-probe", ok: "terminal_probed", err: "probe_failed" })];
    case "terminal_probed": return { ...model, probeResult: msg.body };
    case "probe_failed": return { ...model, probeResult: msg.error };
    case "show_overlay": return [model, Cmd.host("friday.overlay.show", asciiBytes("locked"))];
    case "hide_overlay": return [model, Cmd.host("friday.overlay.hide", asciiBytes(""))];
    case "host_event": {
      if (msg.state !== "data" || msg.key !== HOST_CHANNEL_KEY) return model;
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_down|"))) {
        const atEnd = findPipe(msg.bytes, 12);
        const tokenEnd = findPipe(msg.bytes, atEnd + 1);
        const parsedAt = parseUnsigned(msg.bytes.slice(12, atEnd));
        const at = Number.isFinite(parsedAt) && parsedAt >= 0 && parsedAt <= 9007199254740991 ? Math.trunc(parsedAt) : 0;
        const nextDownCount = model.hotkeyDownCount < 1000000 ? model.hotkeyDownCount + 1 : model.hotkeyDownCount;
        const lock = model.lastQuickReleaseAtMs > 0 && at - model.lastQuickReleaseAtMs <= 350;
        return [{ ...model, hotkeyDown: true, recordingLocked: lock, pressedAtMs: at, hotkeyDownCount: nextDownCount, sourceToken: msg.bytes.slice(atEnd + 1, tokenEnd) }, Cmd.host("friday.overlay.show", lock ? asciiBytes("locked") : asciiBytes("held"))];
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_up|"))) {
        const parsedAt = parseUnsigned(msg.bytes.slice(10, msg.bytes.length));
        const at = Number.isFinite(parsedAt) && parsedAt >= 0 && parsedAt <= 9007199254740991 ? Math.trunc(parsedAt) : 0;
        const nextUpCount = model.hotkeyUpCount < 1000000 ? model.hotkeyUpCount + 1 : model.hotkeyUpCount;
        if (model.recordingLocked) return { ...model, hotkeyUpCount: nextUpCount, lastQuickReleaseAtMs: at };
        return [{ ...model, hotkeyDown: false, hotkeyUpCount: nextUpCount, lastQuickReleaseAtMs: at }, Cmd.host("friday.overlay.hide", asciiBytes(""))];
      }
      if (hasPrefix(msg.bytes, asciiBytes("overlay_stop"))) return [{ ...model, hotkeyDown: false, recordingLocked: false, overlayAction: asciiBytes("stop") }, Cmd.host("friday.overlay.hide", asciiBytes(""))];
      if (hasPrefix(msg.bytes, asciiBytes("overlay_cancel"))) return [{ ...model, hotkeyDown: false, recordingLocked: false, overlayAction: asciiBytes("cancel") }, Cmd.host("friday.overlay.hide", asciiBytes(""))];
      return model;
    }
  }
}
