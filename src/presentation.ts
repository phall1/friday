import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { StatusItemMenuItem, StatusItemState, ThemeState } from "@native-sdk/core/events";
import type { Model, ModelRow } from "./domain.ts";
import { byteEquals, contains, decodeNativeMessage } from "./protocol.ts";
export function projectBlockerText(model: Model): Uint8Array {
  if (!model.platformLoaded) return utf8Bytes("Checking Mac compatibility.");
  if (!model.platformSupported) return model.platformMessage;
  if (!model.permissionsLoaded || !model.modelsLoaded) return utf8Bytes("Checking Friday’s local requirements.");
  if (!model.microphonePermission) return utf8Bytes("Microphone permission is required to record.");
  if (!model.inputMonitoringPermission && !model.limitedModeAccepted) return utf8Bytes("Input Monitoring is required for the global shortcut. Manual Start remains available in limited mode.");
  if (!model.hotkeyConfirmed && !model.limitedModeAccepted) return utf8Bytes("Choose and confirm a global dictation shortcut.");
  if (!model.modelReady || model.selectedModelKey === 0) {
    if (model.modelDownloadState === "failed") return utf8Bytes("The Parakeet model download failed. Retry or choose an allowlisted local artifact.");
    return utf8Bytes("Download or select a Friday-allowlisted Parakeet TDT GGUF artifact.");
  }
  if (!model.onboardingComplete) return utf8Bytes("Finish setup before using Friday.");
  return utf8Bytes("Friday is ready.");
}



export function projectWorkflowName(model: Model): Uint8Array {
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
export function projectWorkflowDetail(model: Model): Uint8Array {
  switch (model.workflow.kind) {
    case "booting": return utf8Bytes("Checking Friday’s local services…");
    case "not_ready": return projectBlockerText(model);
    case "ready": return model.hasImmediateResult ? model.immediateResultMessage : utf8Bytes("Ready. Hold the shortcut and speak naturally.");
    case "starting": return utf8Bytes("Keep holding to record, or release to dismiss.");
    case "recording": return model.workflow.control === "locked" ? utf8Bytes("Locked recording. Stop when you’re finished.") : utf8Bytes("Listening while the shortcut is held.");
    case "stopping": return utf8Bytes("Finishing and saving the recording.");
    case "transcribing": return model.workflow.disposition === "duration_limit" ? utf8Bytes("10-minute limit reached. Transcribing captured audio locally.") : utf8Bytes("Transcribing locally with the active Parakeet model.");
    case "delivering": return model.workflow.disposition === "duration_limit" ? utf8Bytes("10-minute limit reached. Returning the final words.") : utf8Bytes("Returning the final words to the app where you started.");
    case "failed": return projectFailureDetail(model);
  }
}
export function projectIsReady(model: Model): boolean { return model.workflow.kind === "ready"; }
export function projectIsRecording(model: Model): boolean { return model.workflow.kind === "recording"; }
export function projectIsLocked(model: Model): boolean { return model.workflow.kind === "recording" && model.workflow.control === "locked"; }
export function projectIsBusy(model: Model): boolean { return model.workflow.kind === "starting" || model.workflow.kind === "recording" || model.workflow.kind === "stopping" || model.workflow.kind === "transcribing" || model.workflow.kind === "delivering"; }
export function projectCanRetry(model: Model): boolean { return model.workflow.kind === "failed" && model.workflow.stage === "transcription" && model.workflow.retryAudioAvailable; }
export function projectPermissionSummary(model: Model): Uint8Array {
  if (!model.permissionsLoaded) return utf8Bytes("Checking…");
  if (model.microphonePermission && model.accessibilityPermission && model.inputMonitoringPermission) return asciiBytes("Microphone, Accessibility, and Input Monitoring granted.");
  if (!model.microphonePermission) return asciiBytes("Microphone missing.");
  if (!model.inputMonitoringPermission) return asciiBytes("Input Monitoring missing.");
  return asciiBytes("Accessibility missing; Friday will use clipboard fallback.");
}
export function projectModelSummary(model: Model): Uint8Array { return model.modelReady ? asciiBytes("Parakeet TDT model ready.") : asciiBytes("No compatible model ready."); }

export function projectShowUnsupported(model: Model): boolean { return model.platformLoaded && !model.platformSupported; }
export function projectShowOnboarding(model: Model): boolean { return !model.onboardingComplete; }
export function projectShowSettings(model: Model): boolean { return model.onboardingComplete && model.page === "settings"; }
export function projectShowModels(model: Model): boolean { return model.onboardingComplete && model.page === "models"; }
export function projectAvailableModels(model: Model): readonly ModelRow[] { return model.modelRows.filter((row) => !row.active); }
export function projectDefaultModelInstalled(model: Model): boolean {
  for (let index = 0; index < model.modelRows.length; index += 1) if (byteEquals(model.modelRows[index].modelKey, asciiBytes("1"))) return true;
  return false;
}
export function projectShowPermissions(model: Model): boolean { return model.onboardingComplete && model.page === "permissions"; }
export function projectShowDiagnostics(model: Model): boolean { return model.onboardingComplete && model.page === "diagnostics"; }
export function projectIsTranscribing(model: Model): boolean { return model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping"; }
export function projectIsFailed(model: Model): boolean { return model.workflow.kind === "failed"; }
export function projectHasActiveModel(model: Model): boolean { return model.selectedModelKey > 0 && model.activeModelName.length > 0; }
export function projectIsDefaultModelActive(model: Model): boolean { return model.selectedModelKey === 1; }
export function projectCanCompleteOnboarding(model: Model): boolean {
  return model.microphonePermission && model.modelReady &&
    ((model.accessibilityPermission && model.inputMonitoringPermission && model.hotkeyConfirmed) || model.limitedModeAccepted);
}
export function projectOnboardingProgress(model: Model): Uint8Array {
  if (model.onboardingStep === 0) return utf8Bytes("Step 1 of 4 · Privacy");
  if (model.onboardingStep === 1) return utf8Bytes("Step 2 of 4 · Permissions");
  if (model.onboardingStep === 2) return utf8Bytes("Step 3 of 4 · Shortcut");
  return utf8Bytes("Step 4 of 4 · Local model");
}
export function projectMicrophoneDisplayName(model: Model): Uint8Array {
  return contains(model.microphoneName, asciiBytes("System default microphone"))
    ? utf8Bytes("Default microphone")
    : model.microphoneName;
}
export function projectPermissionMicrophoneState(model: Model): Uint8Array { return model.microphonePermission ? utf8Bytes("Granted and usable") : utf8Bytes("Required to record"); }
export function projectOnboardingStepLabel(model: Model): Uint8Array { return utf8Bytes(`STEP ${Math.min(4, Math.max(1, Math.trunc(model.onboardingStep) + 1))} / 4`); }
export function projectHasHotkeyCandidate(model: Model): boolean { return model.hotkeyCandidateDisplay.length > 0; }
export function projectHasHotkeyWarning(model: Model): boolean { return model.hotkeyCandidateWarning.length > 0; }
export function projectPermissionAccessibilityState(model: Model): Uint8Array { return model.accessibilityPermission ? utf8Bytes("Granted and usable") : utf8Bytes("Accessibility missing — completed text will be copied"); }
export function projectPermissionInputState(model: Model): Uint8Array { return model.inputMonitoringPermission ? utf8Bytes("Granted and usable") : utf8Bytes("Required for the global shortcut"); }
export function projectHotkeyLabel(model: Model): Uint8Array { return model.hotkeyDisplay; }
export function projectWaveformGlyph(model: Model): Uint8Array {
  if (model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping") return utf8Bytes("▂ ▃ ▅ ▃ ▂");
  if (model.workflow.kind !== "recording") return utf8Bytes("▁ ▁ ▁ ▁ ▁");
  if (model.meterLevel === "high") return utf8Bytes("▃ ▆ █ ▇ ▄");
  if (model.meterLevel === "medium") return utf8Bytes("▂ ▅ ▇ ▅ ▃");
  if (model.meterLevel === "low") return utf8Bytes("▁ ▃ ▅ ▃ ▂");
  return utf8Bytes("▁ ▂ ▂ ▂ ▁");
}
export function projectWaveformSignature(model: Model): Uint8Array {
  if (model.workflow.kind === "recording") return utf8Bytes("╱╲╱╲╱╲──╱╲╱╲");
  if (model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping") return utf8Bytes("──╱╲╱╲╱╲╱╲──");
  if (model.workflow.kind === "failed") return utf8Bytes("╱╲──╱╲──╱╲──");
  return utf8Bytes("──╱╲────╱╲──");
}
export function projectModelDownloadActive(model: Model): boolean { return model.modelDownloadState === "downloading" || model.modelDownloadState === "verifying"; }
export function projectModelDownloadFailed(model: Model): boolean { return model.modelDownloadState === "failed" || model.modelDownloadState === "cancelled"; }
export function projectModelDownloadPaused(model: Model): boolean { return model.modelDownloadState === "paused"; }
export function projectLoginStatusText(model: Model): Uint8Array {
  if (model.loginStatus === "enabled") return utf8Bytes("Enabled");
  if (model.loginStatus === "disabled") return utf8Bytes("Off");
  if (model.loginStatus === "requires_approval") return utf8Bytes("Needs approval in Login Items");
  if (model.loginStatus === "unavailable") return utf8Bytes("Unavailable — try again from Applications");
  return utf8Bytes("Checking…");
}
function nativeReason(bytes: Uint8Array, fallback: Uint8Array): Uint8Array {
  const reason = decodeNativeMessage(bytes);
  return reason !== null && reason.length > 0 ? reason : fallback;
}

export function projectFailureModelName(model: Model): Uint8Array {
  return model.activeModelName.length > 0 ? model.activeModelName : utf8Bytes("Active local model");
}
export function projectFailureDetail(model: Model): Uint8Array {
  if (model.workflow.kind !== "failed") return asciiBytes("");
  if (model.workflow.stage === "capture") return nativeReason(model.workflowMessage, utf8Bytes("Friday lost microphone input. Check the selected microphone, then try again."));
  if (model.workflow.stage === "model") return nativeReason(model.workflowMessage, utf8Bytes("The active model is unavailable. Select or download a compatible model."));
  if (model.workflow.stage === "transcription") return nativeReason(model.workflowMessage, utf8Bytes("Local transcription did not finish. Retry the retained recording or change model."));
  return nativeReason(model.workflowMessage, utf8Bytes("Friday could not return the final text. Copy it manually when available."));
}

export function projectElapsedLabel(model: Model): Uint8Array {
  const minutes = Math.trunc(model.elapsedMilliseconds / 60000);
  const seconds = Math.trunc(model.elapsedMilliseconds / 1000) % 60;
  return seconds < 10 ? utf8Bytes(`${minutes}:0${seconds}`) : utf8Bytes(`${minutes}:${seconds}`);
}
export function projectHasDiagnosticsExport(model: Model): boolean { return model.diagnosticsExported; }
export function projectShowOverlayPreview(model: Model): boolean { return model.automationSceneActive && model.automationOverlayPreview; }
export function projectThemeState(model: Model): ThemeState {
  return { pack: "geist", colorScheme: model.appearanceOverride };
}

function statusRow(id: number, label: Uint8Array, command: Uint8Array, enabled: boolean, detail: Uint8Array, role: "command" | "info"): StatusItemMenuItem {
  const safeId = Number.isFinite(id) && id >= 0 && id <= 9007199254740991 ? Math.trunc(id) : 0;
  return { id: safeId, label, command, separator: false, enabled, detail, role, key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } };
}

export function projectStatusItem(model: Model): StatusItemState {
  if (projectShowUnsupported(model)) {
    const unsupportedItems: StatusItemMenuItem[] = [];
    unsupportedItems[unsupportedItems.length] = statusRow(1, utf8Bytes("unsupported"), asciiBytes(""), false, model.platformMessage, "info");
    unsupportedItems[unsupportedItems.length] = { id: 0, label: asciiBytes(""), command: asciiBytes(""), separator: true, enabled: false, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } };
    unsupportedItems[unsupportedItems.length] = statusRow(20, utf8Bytes("Open Friday…"), asciiBytes("friday.settings"), true, asciiBytes(""), "command");
    unsupportedItems[unsupportedItems.length] = statusRow(30, utf8Bytes("Quit Friday"), asciiBytes("friday.quit"), true, asciiBytes(""), "command");
    return {
      iconPath: asciiBytes(""),
      tooltip: model.platformMessage,
      activationCommand: asciiBytes(""),
      alternateActivationCommand: asciiBytes(""),
      openCommand: asciiBytes(""),
      presentation: { title: utf8Bytes("!"), width: 28, tone: "critical", iconOpacity: 1.0, monospaced: true, fontSize: 13.0, fontWeight: "semibold" },
      items: unsupportedItems,
    };
  }
  const items: StatusItemMenuItem[] = [];
  items[items.length] = statusRow(1, projectWorkflowName(model), asciiBytes(""), false, model.workflow.kind === "not_ready" || model.workflow.kind === "booting" ? projectBlockerText(model) : projectWorkflowDetail(model), "info");
  if (model.workflow.kind === "ready") items[items.length] = statusRow(10, utf8Bytes("Start Recording"), asciiBytes("friday.start"), true, asciiBytes(""), "command");
  if (model.workflow.kind === "recording") items[items.length] = statusRow(11, utf8Bytes("Stop Recording"), asciiBytes("friday.stop"), true, asciiBytes(""), "command");
  if (projectIsBusy(model)) items[items.length] = statusRow(12, utf8Bytes("Cancel"), asciiBytes("friday.cancel"), true, asciiBytes(""), "command");
  items[items.length] = { id: 0, label: asciiBytes(""), command: asciiBytes(""), separator: true, enabled: false, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } };
  items[items.length] = statusRow(20, utf8Bytes("Open Friday…"), asciiBytes("friday.settings"), true, asciiBytes(""), "command");
  items[items.length] = statusRow(21, utf8Bytes("Models…"), asciiBytes("friday.models"), true, asciiBytes(""), "command");
  items[items.length] = statusRow(22, utf8Bytes("Access…"), asciiBytes("friday.permissions"), true, asciiBytes(""), "command");
  items[items.length] = statusRow(23, model.launchAtLogin ? utf8Bytes("Disable Launch at Login") : utf8Bytes("Enable Launch at Login"), asciiBytes("friday.login"), model.loginStatus !== "checking", asciiBytes(""), "command");
  items[items.length] = { id: 0, label: asciiBytes(""), command: asciiBytes(""), separator: true, enabled: false, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } };
  items[items.length] = statusRow(30, utf8Bytes("Quit Friday"), asciiBytes("friday.quit"), true, asciiBytes(""), "command");
  // The menu-bar mark never changes identity: the Friday waveform stays put
  // and only its treatment moves — red while live, dimmed while working,
  // ghosted while blocked, and a "!" badge only for a real failure.
  const busy = model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping";
  const live = model.workflow.kind === "recording" || model.workflow.kind === "starting";
  const failed = model.workflow.kind === "failed";
  const blocked = model.workflow.kind === "not_ready" || model.workflow.kind === "booting";
  const title = failed ? utf8Bytes("!") : asciiBytes("");
  const tone = failed || live ? "critical" : "normal";
  const iconOpacity = failed || live ? 1.0 : busy ? 0.55 : blocked ? 0.35 : 1.0;
  return {
    iconPath: asciiBytes("assets/menubar-icon.png"),
    tooltip: projectWorkflowDetail(model),
    activationCommand: asciiBytes(""),
    alternateActivationCommand: asciiBytes(""),
    openCommand: asciiBytes(""),
    presentation: { title, width: 0, tone, iconOpacity, monospaced: true, fontSize: 13.0, fontWeight: "semibold" },
    items,
  };
}
