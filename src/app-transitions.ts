import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { Model, Msg } from "./core.ts";
import { contains, jsonString } from "./protocol.ts";
import { readiness } from "./state.ts";

function nativeReason(bytes: Uint8Array, fallback: Uint8Array): Uint8Array {
  const reason = jsonString(bytes, asciiBytes("\"message\":\""));
  return reason.length > 0 ? reason : fallback;
}

export function updateAppState(model: Model, msg: Msg): Model | null {
  switch (msg.kind) {
    case "appearance_changed":
      return { ...model, systemColorScheme: msg.colorScheme, reduceMotion: msg.reduceMotion, highContrast: msg.highContrast };
    case "platform_failed":
      return { ...model, platformLoaded: true, platformSupported: false, platformMessage: utf8Bytes("Friday could not verify this Mac. Friday requires Apple Silicon and macOS 14 or later."), workflow: { kind: "not_ready" } };
    case "automation_login_finished":
    case "automation_contracts_finished":
    case "automation_hotkey_probe_finished":
      return { ...model, hasImmediateResult: true, immediateResultKind: "shown", immediateResultMessage: msg.body, ambientDetail: msg.body };
    case "automation_login_failed":
    case "automation_contracts_failed":
    case "automation_hotkey_probe_failed":
      return { ...model, hasImmediateResult: true, immediateResultKind: "shown", immediateResultMessage: msg.error, ambientDetail: msg.error };
    case "performance_fixture_finished":
      return { ...model, ambientDetail: msg.body };
    case "performance_fixture_failed":
      return { ...model, hasImmediateResult: true, immediateResultKind: "shown", immediateResultMessage: msg.error, ambientDetail: msg.error };
    case "dismiss_overlay_preview":
      return model.automationSceneActive ? { ...model, automationOverlayPreview: false } : model;
    case "accept_limited_mode":
      return { ...model, limitedModeAccepted: true };
    case "hotkey_candidate":
      return {
        ...model,
        hotkeyCaptureActive: false,
        hotkeyChoice: "custom",
        hotkeyCandidateConfig: jsonString(msg.body, asciiBytes("\"config\":\"")),
        hotkeyCandidateDisplay: jsonString(msg.body, asciiBytes("\"display\":\"")),
        hotkeyCandidateWarning: jsonString(msg.body, asciiBytes("\"warning\":\"")),
        hotkeyCandidateValid: contains(msg.body, asciiBytes("\"valid\":true")),
      };
    case "hotkey_capture_failed":
      return { ...model, hotkeyCaptureActive: false, hotkeyCandidateWarning: nativeReason(msg.error, utf8Bytes("Friday could not record that shortcut.")), hotkeyCandidateValid: false };
    case "microphone_loaded":
      if (model.automationSceneActive) return model;
      return { ...model, microphoneName: jsonString(msg.body, asciiBytes("\"deviceName\":\"")), microphoneDetail: jsonString(msg.body, asciiBytes("\"detail\":\"")) };
    case "microphone_failed":
      return { ...model, microphoneDetail: msg.error };
    case "diagnostics_loaded":
      return { ...model, diagnostics: msg.body };
    case "diagnostics_failed":
    case "diagnostics_copy_failed":
    case "diagnostics_export_failed":
      return { ...model, diagnostics: msg.error };
    case "login_status_loaded": {
      if (model.automationSceneActive) return model;
      const enabled = contains(msg.body, asciiBytes("\"enabled\":true"));
      const approval = contains(msg.body, asciiBytes("\"requiresApproval\":true"));
      return { ...model, launchAtLogin: enabled, loginStatus: approval ? "requires_approval" : enabled ? "enabled" : "disabled" };
    }
    case "login_status_failed":
    case "login_setting_failed":
      return { ...model, loginStatus: "unavailable", ambientDetail: msg.error };
    case "subscribed":
      return model.automationSceneActive ? model : { ...model, ambientDetail: msg.body };
    case "subscribe_failed":
      return { ...model, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "debug_fixture_finished":
      return { ...model, hasImmediateResult: true, immediateResultKind: contains(msg.body, asciiBytes("\"kind\":\"clipboard\"")) ? "clipboard" : "shown", immediateResultMessage: msg.body, ambientDetail: msg.body };
    case "debug_fixture_failed":
      return { ...model, hasImmediateResult: true, immediateResultKind: "shown", immediateResultMessage: msg.error, ambientDetail: msg.error };
    case "permissions_loaded": {
      if (model.automationSceneActive) return model;
      const next = {
        ...model,
        permissionsLoaded: true,
        microphonePermission: contains(msg.body, asciiBytes("\"microphone\":true")),
        accessibilityPermission: contains(msg.body, asciiBytes("\"accessibility\":1")) || contains(msg.body, asciiBytes("\"accessibility\":true")),
        inputMonitoringPermission: contains(msg.body, asciiBytes("\"inputMonitoring\":true")),
        ambientDetail: msg.body,
      };
      if (model.workflow.kind === "booting" || model.workflow.kind === "not_ready" || model.workflow.kind === "ready") return { ...next, workflow: readiness(next) };
      return next;
    }
    case "permissions_failed":
      return { ...model, permissionsLoaded: true, workflow: { kind: "not_ready" }, workflowMessage: msg.error, ambientDetail: msg.error };
    case "hotkey_failed": {
      const reason = nativeReason(msg.error, utf8Bytes("Friday could not activate that global shortcut."));
      return { ...model, hotkeyConfirmed: false, workflow: { kind: "not_ready" }, hotkeyCandidateWarning: reason, workflowMessage: reason, ambientDetail: reason };
    }
    default:
      return null;
  }
}
