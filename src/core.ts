import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";
import { type TextInputEvent } from "@native-sdk/core/text";
import { type StatusItemMenuItem, type StatusItemState, type ThemeState } from "@native-sdk/core/events";
import { byteEquals, contains, decodeNativeMessage, decodeTranscriptReady, encodeDeliveryRequest, encodeTranscriptionRequest, eventMatches, findPipe, groupedDigits, hasPrefix, jsonInteger, jsonString, parseUnsigned } from "./protocol.ts";
import { defaultModel, durableModel, readiness } from "./state.ts";
import { automationScene } from "./automation.ts";
import { updateModelState } from "./model-transitions.ts";
import { updateAppState } from "./app-transitions.ts";
import { updateWorkflowState } from "./workflow-transitions.ts";

export type HostChannelState = "data" | "closed" | "rejected";
export type HostChannelKey = 7001;
export type DeliveryKind = "pasted" | "clipboard" | "shown";
export type FailureStage = "capture" | "model" | "transcription" | "delivery";
export type RecordingControl = "held" | "locked";
export type StopDisposition = "transcribe" | "discard" | "cancel" | "duration_limit";
const HOST_CHANNEL_KEY: HostChannelKey = 7001;
export type AppPage = "settings" | "models" | "permissions" | "diagnostics";
export type HotkeyChoice = "command_shift" | "control_option" | "custom";
export type ModelDownloadState = "idle" | "paused" | "downloading" | "verifying" | "installed" | "cancelled" | "failed";
export type LoginStatus = "checking" | "disabled" | "enabled" | "requires_approval" | "unavailable";
export type MeterLevel = "quiet" | "low" | "medium" | "high";
export type AppearanceChoice = "system" | "light" | "dark";
export type SystemColorScheme = "light" | "dark";

export interface ModelRow {
  readonly modelKey: Uint8Array;
  readonly name: Uint8Array;
  readonly source: Uint8Array;
  readonly license: Uint8Array;
  readonly languages: Uint8Array;
  readonly size: Uint8Array;
  readonly managed: boolean;
  readonly active: boolean;
}
export type DictationWorkflow =
  | { readonly kind: "booting" }
  | { readonly kind: "not_ready" }
  | { readonly kind: "ready"; readonly modelKey: number }
  | { readonly kind: "starting"; readonly lockCandidate: boolean; readonly committed: boolean; readonly audioStarted: boolean; readonly releasePending: boolean }
  | { readonly kind: "recording"; readonly control: RecordingControl; readonly warnedDurationLimit: boolean }
  | { readonly kind: "stopping"; readonly disposition: StopDisposition }
  | { readonly kind: "transcribing"; readonly retryAudioAvailable: boolean; readonly disposition: StopDisposition }
  | { readonly kind: "delivering"; readonly disposition: StopDisposition }
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
  readonly durationLimitReached: boolean;
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
  readonly page: AppPage;
  readonly platformLoaded: boolean;
  readonly platformSupported: boolean;
  readonly platformArchitecture: Uint8Array;
  readonly platformOSVersion: Uint8Array;
  readonly platformMessage: Uint8Array;
  readonly onboardingStep: number;
  readonly hotkeyChoice: HotkeyChoice;
  readonly hotkeyPracticed: boolean;
  readonly hotkeyConfig: Uint8Array;
  readonly hotkeyDisplay: Uint8Array;
  readonly hotkeyCandidateConfig: Uint8Array;
  readonly hotkeyCandidateDisplay: Uint8Array;
  readonly hotkeyCandidateWarning: Uint8Array;
  readonly hotkeyCandidateValid: boolean;
  readonly hotkeyCaptureActive: boolean;
  readonly modelDownloadState: ModelDownloadState;
  readonly modelDownloadUserCancelled: boolean;
  readonly modelDownloadedBytes: number;
  readonly modelTotalBytes: number;
  readonly modelDownloadedBytesLabel: Uint8Array;
  readonly modelTotalBytesLabel: Uint8Array;
  readonly modelDownloadMessage: Uint8Array;
  readonly managedModelBytes: number;
  readonly modelCount: number;
  readonly activeModelName: Uint8Array;
  readonly activeModelSource: Uint8Array;
  readonly activeModelLicense: Uint8Array;
  readonly activeModelLanguages: Uint8Array;
  readonly activeModelSizeText: Uint8Array;
  readonly managedModelSizeText: Uint8Array;
  readonly hfResolved: boolean;
  readonly hfResolvedIdentifier: Uint8Array;
  readonly hfResolvedRevision: Uint8Array;
  readonly hfResolvedArtifact: Uint8Array;
  readonly hfResolvedSize: Uint8Array;
  readonly hfResolvedLicense: Uint8Array;
  readonly hfResolvedProvider: Uint8Array;
  readonly hfResolvedAttribution: Uint8Array;
  readonly hfResolvedConfirmed: boolean;
  readonly activeModelBytes: number;
  readonly hfDraft: Uint8Array;
  readonly hfSourceConfirmed: boolean;
  readonly modelRows: readonly ModelRow[];
  readonly diagnostics: Uint8Array;
  readonly diagnosticsExported: boolean;
  readonly microphoneName: Uint8Array;
  readonly microphoneDetail: Uint8Array;
  readonly meterLevel: MeterLevel;
  readonly elapsedMilliseconds: number;
  readonly loginStatus: LoginStatus;
  readonly appearanceOverride: AppearanceChoice;
  readonly systemColorScheme: SystemColorScheme;
  readonly reduceMotion: boolean;
  readonly automationSceneActive: boolean;
  readonly automationOverlayPreview: boolean;
  readonly highContrast: boolean;
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
  | { readonly kind: "platform_loaded"; readonly body: Uint8Array }
  | { readonly kind: "platform_failed"; readonly error: Uint8Array }
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
  | { readonly kind: "audio_stopped"; readonly body: Uint8Array }
  | { readonly kind: "audio_stop_failed"; readonly error: Uint8Array }
  | { readonly kind: "begin_transcription"; readonly at: number }
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
  | { readonly kind: "show_settings" }
  | { readonly kind: "show_models" }
  | { readonly kind: "show_permissions" }
  | { readonly kind: "show_diagnostics" }
  | { readonly kind: "quit_app" }
  | { readonly kind: "onboarding_next" }
  | { readonly kind: "onboarding_back" }
  | { readonly kind: "accept_limited_mode" }
  | { readonly kind: "start_hotkey_capture" }
  | { readonly kind: "hotkey_candidate"; readonly body: Uint8Array }
  | { readonly kind: "hotkey_capture_failed"; readonly error: Uint8Array }
  | { readonly kind: "cancel_hotkey_capture" }
  | { readonly kind: "confirm_hotkey_candidate" }
  | { readonly kind: "choose_command_shift" }
  | { readonly kind: "choose_control_option" }
  | { readonly kind: "set_double_tap_fast" }
  | { readonly kind: "set_double_tap_balanced" }
  | { readonly kind: "set_double_tap_deliberate" }
  | { readonly kind: "cancel_model_download" }
  | { readonly kind: "retry_model_download" }
  | { readonly kind: "hf_model_resolved"; readonly body: Uint8Array }
  | { readonly kind: "hf_resolve_failed"; readonly error: Uint8Array }
  | { readonly kind: "toggle_hf_download_confirmation" }
  | { readonly kind: "download_resolved_hf" }
  | { readonly kind: "clear_hf_candidate" }
  | { readonly kind: "choose_local_model" }
  | { readonly kind: "local_model_added"; readonly body: Uint8Array }
  | { readonly kind: "local_model_failed"; readonly error: Uint8Array }
  | { readonly kind: "hf_draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "toggle_hf_source_confirmation" }
  | { readonly kind: "choose_parakeet_ctc" }
  | { readonly kind: "add_hugging_face_model" }
  | { readonly kind: "hf_model_added"; readonly body: Uint8Array }
  | { readonly kind: "hf_model_failed"; readonly error: Uint8Array }
  | { readonly kind: "model_selected"; readonly body: Uint8Array }
  | { readonly kind: "model_select_failed"; readonly error: Uint8Array }
  | { readonly kind: "remove_model_reference" }
  | { readonly kind: "delete_managed_model" }
  | { readonly kind: "model_removed"; readonly body: Uint8Array }
  | { readonly kind: "model_remove_failed"; readonly error: Uint8Array }
  | { readonly kind: "cleanup_model_downloads" }
  | { readonly kind: "model_cleanup_finished"; readonly body: Uint8Array }
  | { readonly kind: "model_cleanup_failed"; readonly error: Uint8Array }
  | { readonly kind: "refresh_microphone" }
  | { readonly kind: "select_model"; readonly rowKey: Uint8Array }
  | { readonly kind: "microphone_loaded"; readonly body: Uint8Array }
  | { readonly kind: "remove_model"; readonly rowKey: Uint8Array }
  | { readonly kind: "delete_model"; readonly rowKey: Uint8Array }
  | { readonly kind: "microphone_failed"; readonly error: Uint8Array }
  | { readonly kind: "refresh_diagnostics" }
  | { readonly kind: "diagnostics_loaded"; readonly body: Uint8Array }
  | { readonly kind: "diagnostics_failed"; readonly error: Uint8Array }
  | { readonly kind: "copy_diagnostics_fresh" }
  | { readonly kind: "diagnostics_copy_loaded"; readonly body: Uint8Array }
  | { readonly kind: "diagnostics_copy_failed"; readonly error: Uint8Array }
  | { readonly kind: "copy_diagnostics" }
  | { readonly kind: "export_diagnostics" }
  | { readonly kind: "diagnostics_exported"; readonly body: Uint8Array }
  | { readonly kind: "diagnostics_export_failed"; readonly error: Uint8Array }
  | { readonly kind: "reveal_diagnostics" }
  | { readonly kind: "login_status_loaded"; readonly body: Uint8Array }
  | { readonly kind: "login_status_failed"; readonly error: Uint8Array }
  | { readonly kind: "login_setting_saved"; readonly body: Uint8Array }
  | { readonly kind: "login_setting_failed"; readonly error: Uint8Array }
  | { readonly kind: "appearance_changed"; readonly colorScheme: SystemColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "automation_scene_requested"; readonly value: Uint8Array }
  | { readonly kind: "automation_login_requested"; readonly value: Uint8Array }
  | { readonly kind: "automation_login_finished"; readonly body: Uint8Array }
  | { readonly kind: "automation_login_failed"; readonly error: Uint8Array }
  | { readonly kind: "debug_fixture_requested"; readonly value: Uint8Array }
  | { readonly kind: "debug_fixture_finished"; readonly body: Uint8Array }
  | { readonly kind: "automation_contracts_requested"; readonly value: Uint8Array }
  | { readonly kind: "automation_contracts_finished"; readonly body: Uint8Array }
  | { readonly kind: "automation_contracts_failed"; readonly error: Uint8Array }
  | { readonly kind: "performance_fixture_requested"; readonly value: Uint8Array }
  | { readonly kind: "performance_fixture_finished"; readonly body: Uint8Array }
  | { readonly kind: "performance_fixture_failed"; readonly error: Uint8Array }
  | { readonly kind: "automation_hotkey_probe_requested"; readonly value: Uint8Array }
  | { readonly kind: "automation_hotkey_probe_finished"; readonly body: Uint8Array }
  | { readonly kind: "automation_hotkey_probe_failed"; readonly error: Uint8Array }
  | { readonly kind: "automation_hotkey_probe_now" }
  | { readonly kind: "debug_fixture_failed"; readonly error: Uint8Array }
  | { readonly kind: "copy_immediate_result" }
  | { readonly kind: "dismiss_overlay_preview" }
  | { readonly kind: "dismiss_result" };

export const envMsgs = [
  { env: "FRIDAY_AUTOMATION_FIXTURE", msg: "debug_fixture_requested" },
  { env: "FRIDAY_AUTOMATION_SCENE", msg: "automation_scene_requested" },
  { env: "FRIDAY_AUTOMATION_CONTRACTS", msg: "automation_contracts_requested" },
  { env: "FRIDAY_AUTOMATION_PERFORMANCE", msg: "performance_fixture_requested" },
  { env: "FRIDAY_AUTOMATION_HOTKEY_PROBE", msg: "automation_hotkey_probe_requested" },
  { env: "FRIDAY_AUTOMATION_LOGIN", msg: "automation_login_requested" },
] as const;
export const appearanceMsg = "appearance_changed";
export const viewUnbound = [
  "host_event", "subscribed", "subscribe_failed", "permissions_loaded", "permissions_failed",
  "model_status_loaded", "model_status_failed", "model_downloaded", "model_download_failed",
  "restored", "fresh_boot", "restore_failed", "source_captured", "source_capture_failed", "hotkey_configured", "hotkey_failed", "hold_elapsed",
  "audio_started", "audio_start_failed", "audio_stopped", "audio_stop_failed", "begin_transcription", "transcript_ready", "transcription_failed",
  "delivery_finished", "delivery_failed", "debug_fixture_requested", "debug_fixture_finished", "debug_fixture_failed",
  "local_model_added", "local_model_failed", "hf_model_added", "hf_model_failed", "model_selected", "model_select_failed", "model_removed", "model_remove_failed", "model_cleanup_finished", "model_cleanup_failed",
  "microphone_loaded", "microphone_failed", "diagnostics_loaded", "diagnostics_failed", "diagnostics_copy_loaded", "diagnostics_copy_failed", "diagnostics_exported", "diagnostics_export_failed",
  "login_status_loaded", "login_status_failed", "login_setting_saved", "login_setting_failed", "appearance_changed",
  "automation_scene_requested", "automation_login_requested", "automation_login_finished", "automation_login_failed", "automation_contracts_requested", "automation_contracts_finished", "automation_contracts_failed", "performance_fixture_requested", "performance_fixture_finished", "performance_fixture_failed", "automation_hotkey_probe_requested", "automation_hotkey_probe_finished", "automation_hotkey_probe_failed", "automation_hotkey_probe_now", "automationSceneActive", "systemColorScheme", "reduceMotion", "highContrast", "sessionSourceToken", "workflowMessage",
] as const;

export function migrate(snapshot: Uint8Array, fromVersion: number): Model {
  if (fromVersion === 1 && snapshot.length >= 0) return defaultModel();
  return defaultModel();
}

export function blockerText(model: Model): Uint8Array {
  if (!model.platformLoaded) return utf8Bytes("Checking Mac compatibility.");
  if (!model.platformSupported) return model.platformMessage;
  if (!model.permissionsLoaded || !model.modelsLoaded) return utf8Bytes("Checking Friday’s local requirements.");
  if (!model.microphonePermission) return utf8Bytes("Microphone permission is required to record.");
  if (!model.inputMonitoringPermission && !model.limitedModeAccepted) return utf8Bytes("Input Monitoring is required for the global shortcut. Manual Start remains available in limited mode.");
  if (!model.hotkeyConfirmed && !model.limitedModeAccepted) return utf8Bytes("Choose and confirm a global dictation shortcut.");
  if (!model.modelReady || model.selectedModelKey === 0) {
    if (model.modelDownloadState === "failed") return utf8Bytes("The Parakeet model download failed. Retry or choose a compatible local model.");
    return utf8Bytes("Download or select a compatible Parakeet TDT GGUF model.");
  }
  if (!model.onboardingComplete) return utf8Bytes("Finish setup before using Friday.");
  return utf8Bytes("Friday is ready.");
}


export function initialModel(): [Model, Cmd<Msg>] {
  return [defaultModel(), Cmd.batch([
    Cmd.channelOpen(HOST_CHANNEL_KEY, { event: "host_event" }),
    Cmd.request("friday.subscribe", asciiBytes("7001"), { key: "host-subscribe", ok: "subscribed", err: "subscribe_failed" }),
    Cmd.request("friday.platform", asciiBytes(""), { key: "platform-status", ok: "platform_loaded", err: "platform_failed" }),
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
    case "not_ready": return blockerText(model);
    case "ready": return model.hasImmediateResult ? model.immediateResultMessage : utf8Bytes("Ready. Hold the shortcut and speak naturally.");
    case "starting": return utf8Bytes("Keep holding to record, or release to dismiss.");
    case "recording": return model.workflow.control === "locked" ? utf8Bytes("Locked recording. Stop when you’re finished.") : utf8Bytes("Listening while the shortcut is held.");
    case "stopping": return utf8Bytes("Finishing and saving the recording.");
    case "transcribing": return model.workflow.disposition === "duration_limit" ? utf8Bytes("10-minute limit reached. Transcribing captured audio locally.") : utf8Bytes("Transcribing locally with the active Parakeet model.");
    case "delivering": return model.workflow.disposition === "duration_limit" ? utf8Bytes("10-minute limit reached. Returning the final words.") : utf8Bytes("Returning the final words to the app where you started.");
    case "failed": return failureDetail(model);
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

export function showUnsupported(model: Model): boolean { return model.platformLoaded && !model.platformSupported; }
export function showOnboarding(model: Model): boolean { return !model.onboardingComplete; }
export function showSettings(model: Model): boolean { return model.onboardingComplete && model.page === "settings"; }
export function showModels(model: Model): boolean { return model.onboardingComplete && model.page === "models"; }
export function availableModels(model: Model): readonly ModelRow[] { return model.modelRows.filter((row) => !row.active); }
export function defaultModelInstalled(model: Model): boolean {
  for (let index = 0; index < model.modelRows.length; index += 1) if (byteEquals(model.modelRows[index].modelKey, asciiBytes("1"))) return true;
  return false;
}
export function showPermissions(model: Model): boolean { return model.onboardingComplete && model.page === "permissions"; }
export function showDiagnostics(model: Model): boolean { return model.onboardingComplete && model.page === "diagnostics"; }
export function isTranscribing(model: Model): boolean { return model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping"; }
export function isFailed(model: Model): boolean { return model.workflow.kind === "failed"; }
export function hasActiveModel(model: Model): boolean { return model.selectedModelKey > 0 && model.activeModelName.length > 0; }
export function isDefaultModelActive(model: Model): boolean { return model.selectedModelKey === 1; }
export function canCompleteOnboarding(model: Model): boolean {
  return model.microphonePermission && model.modelReady &&
    ((model.accessibilityPermission && model.inputMonitoringPermission && model.hotkeyConfirmed) || model.limitedModeAccepted);
}
export function onboardingProgress(model: Model): Uint8Array {
  if (model.onboardingStep === 0) return utf8Bytes("Step 1 of 4 · Privacy");
  if (model.onboardingStep === 1) return utf8Bytes("Step 2 of 4 · Permissions");
  if (model.onboardingStep === 2) return utf8Bytes("Step 3 of 4 · Shortcut");
  return utf8Bytes("Step 4 of 4 · Local model");
}
export function microphoneDisplayName(model: Model): Uint8Array {
  return contains(model.microphoneName, asciiBytes("System default microphone"))
    ? utf8Bytes("Default microphone")
    : model.microphoneName;
}
export function permissionMicrophoneState(model: Model): Uint8Array { return model.microphonePermission ? utf8Bytes("Granted and usable") : utf8Bytes("Required to record"); }
export function onboardingStepLabel(model: Model): Uint8Array { return utf8Bytes(`STEP ${Math.min(4, Math.max(1, Math.trunc(model.onboardingStep) + 1))} / 4`); }
export function hasHotkeyCandidate(model: Model): boolean { return model.hotkeyCandidateDisplay.length > 0; }
export function hasHotkeyWarning(model: Model): boolean { return model.hotkeyCandidateWarning.length > 0; }
export function permissionAccessibilityState(model: Model): Uint8Array { return model.accessibilityPermission ? utf8Bytes("Granted and usable") : utf8Bytes("Accessibility missing — completed text will be copied"); }
export function permissionInputState(model: Model): Uint8Array { return model.inputMonitoringPermission ? utf8Bytes("Granted and usable") : utf8Bytes("Required for the global shortcut"); }
export function hotkeyLabel(model: Model): Uint8Array { return model.hotkeyDisplay; }
export function waveformGlyph(model: Model): Uint8Array {
  if (model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping") return utf8Bytes("▂ ▃ ▅ ▃ ▂");
  if (model.workflow.kind !== "recording") return utf8Bytes("▁ ▁ ▁ ▁ ▁");
  if (model.meterLevel === "high") return utf8Bytes("▃ ▆ █ ▇ ▄");
  if (model.meterLevel === "medium") return utf8Bytes("▂ ▅ ▇ ▅ ▃");
  if (model.meterLevel === "low") return utf8Bytes("▁ ▃ ▅ ▃ ▂");
  return utf8Bytes("▁ ▂ ▂ ▂ ▁");
}
export function waveformSignature(model: Model): Uint8Array {
  if (model.workflow.kind === "recording") return utf8Bytes("╱╲╱╲╱╲──╱╲╱╲");
  if (model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping") return utf8Bytes("──╱╲╱╲╱╲╱╲──");
  if (model.workflow.kind === "failed") return utf8Bytes("╱╲──╱╲──╱╲──");
  return utf8Bytes("──╱╲────╱╲──");
}
export function modelDownloadActive(model: Model): boolean { return model.modelDownloadState === "downloading" || model.modelDownloadState === "verifying"; }
export function modelDownloadFailed(model: Model): boolean { return model.modelDownloadState === "failed" || model.modelDownloadState === "cancelled"; }
export function modelDownloadPaused(model: Model): boolean { return model.modelDownloadState === "paused"; }
export function loginStatusText(model: Model): Uint8Array {
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

export function failureModelName(model: Model): Uint8Array {
  return model.activeModelName.length > 0 ? model.activeModelName : utf8Bytes("Active local model");
}
export function failureDetail(model: Model): Uint8Array {
  if (model.workflow.kind !== "failed") return asciiBytes("");
  if (model.workflow.stage === "capture") return nativeReason(model.workflowMessage, utf8Bytes("Friday lost microphone input. Check the selected microphone, then try again."));
  if (model.workflow.stage === "model") return nativeReason(model.workflowMessage, utf8Bytes("The active model is unavailable. Select or download a compatible model."));
  if (model.workflow.stage === "transcription") return nativeReason(model.workflowMessage, utf8Bytes("Local transcription did not finish. Retry the retained recording or change model."));
  return nativeReason(model.workflowMessage, utf8Bytes("Friday could not return the final text. Copy it manually when available."));
}

export function elapsedLabel(model: Model): Uint8Array {
  const minutes = Math.trunc(model.elapsedMilliseconds / 60000);
  const seconds = Math.trunc(model.elapsedMilliseconds / 1000) % 60;
  return seconds < 10 ? utf8Bytes(`${minutes}:0${seconds}`) : utf8Bytes(`${minutes}:${seconds}`);
}
export function hasDiagnosticsExport(model: Model): boolean { return model.diagnosticsExported; }
export function showOverlayPreview(model: Model): boolean { return model.automationSceneActive && model.automationOverlayPreview; }
export function themeState(model: Model): ThemeState {
  return { pack: "geist", colorScheme: model.appearanceOverride };
}

function statusRow(id: number, label: Uint8Array, command: Uint8Array, enabled: boolean, detail: Uint8Array, role: "command" | "info"): StatusItemMenuItem {
  const safeId = Number.isFinite(id) && id >= 0 && id <= 9007199254740991 ? Math.trunc(id) : 0;
  return { id: safeId, label, command, separator: false, enabled, detail, role, key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } };
}

export function statusItem(model: Model): StatusItemState {
  if (showUnsupported(model)) {
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
  items[items.length] = statusRow(1, workflowName(model), asciiBytes(""), false, model.workflow.kind === "not_ready" || model.workflow.kind === "booting" ? blockerText(model) : workflowDetail(model), "info");
  if (model.workflow.kind === "ready") items[items.length] = statusRow(10, utf8Bytes("Start Recording"), asciiBytes("friday.start"), true, asciiBytes(""), "command");
  if (model.workflow.kind === "recording") items[items.length] = statusRow(11, utf8Bytes("Stop Recording"), asciiBytes("friday.stop"), true, asciiBytes(""), "command");
  if (isBusy(model)) items[items.length] = statusRow(12, utf8Bytes("Cancel"), asciiBytes("friday.cancel"), true, asciiBytes(""), "command");
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
    tooltip: workflowDetail(model),
    activationCommand: asciiBytes(""),
    alternateActivationCommand: asciiBytes(""),
    openCommand: asciiBytes(""),
    presentation: { title, width: 0, tone, iconOpacity, monospaced: true, fontSize: 13.0, fontWeight: "semibold" },
    items,
  };
}

export function commandMsg(name: string): Msg | null {
  if (name === "friday.start") return { kind: "start_recording" };
  if (name === "friday.stop") return { kind: "stop_recording" };
  if (name === "friday.cancel") return { kind: "cancel_active" };
  if (name === "friday.settings") return { kind: "show_settings" };
  if (name === "friday.models") return { kind: "show_models" };
  if (name === "friday.permissions") return { kind: "show_permissions" };
  if (name === "friday.login") return { kind: "toggle_launch_at_login" };
  if (name === "friday.quit") return { kind: "quit_app" };
  return null;
}



export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  if (msg.kind === "platform_failed") {
    const failedPlatform = updateAppState(model, msg);
    if (failedPlatform !== null) return [failedPlatform, Cmd.batch([Cmd.showWindow("main"), Cmd.setDockPresence(true)])];
  }
  const appState = updateAppState(model, msg);
  if (appState !== null) return appState;
  const modelState = updateModelState(model, msg);
  if (modelState !== null) return modelState;
  if (msg.kind === "audio_started" && model.workflow.kind === "starting" && model.workflow.releasePending) {
    const session = jsonInteger(msg.body, asciiBytes("\"sessionId\":"));
    const generation = jsonInteger(msg.body, asciiBytes("\"generation\":"));
    if (session !== model.sessionId || (generation !== 0 && generation !== model.generation)) return model;
    return [{ ...model, durationLimitReached: false, capturedFrames: 0 / 1, elapsedMilliseconds: 0 / 1, meterLevel: "quiet", workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_stopped", err: "audio_stop_failed" })];
  }
  if (msg.kind === "source_capture_failed" || msg.kind === "audio_start_failed" || msg.kind === "audio_stop_failed" || msg.kind === "transcription_failed" || msg.kind === "delivery_finished" || msg.kind === "delivery_failed") {
    const terminalState = updateWorkflowState(model, msg);
    if (terminalState !== null && terminalState !== model) return [terminalState, Cmd.host("friday.overlay.hide", asciiBytes(""))];
  }
  const workflowState = updateWorkflowState(model, msg);
  if (workflowState !== null) return workflowState;
  switch (msg.kind) {
    case "platform_loaded": {
      if (model.automationSceneActive) return model;
      const next = {
        ...model,
        platformLoaded: true,
        platformSupported: contains(msg.body, asciiBytes("\"supported\":true")),
        platformArchitecture: jsonString(msg.body, asciiBytes("\"architecture\":\"")),
        platformOSVersion: jsonString(msg.body, asciiBytes("\"osVersion\":\"")),
        platformMessage: jsonString(msg.body, asciiBytes("\"message\":\"")),
      };
      const readyNext = model.workflow.kind === "booting" || model.workflow.kind === "not_ready" || model.workflow.kind === "ready" ? { ...next, workflow: readiness(next) } : next;
      if (!next.platformSupported) return [readyNext, Cmd.batch([Cmd.showWindow("main"), Cmd.setDockPresence(true)])];
      if (next.hotkeyConfirmed && next.onboardingComplete) return [readyNext, Cmd.batch([
        Cmd.none,
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
        Cmd.request("friday.login.status", asciiBytes(""), { key: "login-status", ok: "login_status_loaded", err: "login_status_failed" }),
        Cmd.request("friday.audio.input_status", asciiBytes(""), { key: "microphone-status", ok: "microphone_loaded", err: "microphone_failed" }),
        Cmd.request("friday.hotkey.configure", next.hotkeyConfig, { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" }),
        Cmd.hideWindow("main"),
        Cmd.setDockPresence(false),
      ])];
      if (next.hotkeyConfirmed) return [readyNext, Cmd.batch([
        Cmd.none,
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
        Cmd.request("friday.login.status", asciiBytes(""), { key: "login-status", ok: "login_status_loaded", err: "login_status_failed" }),
        Cmd.request("friday.audio.input_status", asciiBytes(""), { key: "microphone-status", ok: "microphone_loaded", err: "microphone_failed" }),
        Cmd.request("friday.hotkey.configure", next.hotkeyConfig, { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" }),
        Cmd.showWindow("main"),
        Cmd.setDockPresence(true),
      ])];
      if (next.onboardingComplete) return [readyNext, Cmd.batch([
        Cmd.none,
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
        Cmd.request("friday.login.status", asciiBytes(""), { key: "login-status", ok: "login_status_loaded", err: "login_status_failed" }),
        Cmd.request("friday.audio.input_status", asciiBytes(""), { key: "microphone-status", ok: "microphone_loaded", err: "microphone_failed" }),
        Cmd.hideWindow("main"),
        Cmd.setDockPresence(false),
      ])];
      return [readyNext, Cmd.batch([
        Cmd.none,
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
        Cmd.request("friday.login.status", asciiBytes(""), { key: "login-status", ok: "login_status_loaded", err: "login_status_failed" }),
        Cmd.request("friday.audio.input_status", asciiBytes(""), { key: "microphone-status", ok: "microphone_loaded", err: "microphone_failed" }),
        Cmd.showWindow("main"),
        Cmd.setDockPresence(true),
      ])];
    }
    case "automation_scene_requested":
      return automationScene(model, msg.value);
    case "automation_login_requested":
      return [model, Cmd.request("friday.login.cycle_test", msg.value, { key: "automation-login", ok: "automation_login_finished", err: "automation_login_failed" })];
    case "show_settings":
      return [{ ...model, page: "settings" }, Cmd.batch([Cmd.showWindow("main"), Cmd.setDockPresence(true)])];
    case "show_models":
      return [{ ...model, page: "models" }, Cmd.batch([Cmd.showWindow("main"), Cmd.setDockPresence(true), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    case "show_permissions":
      return [{ ...model, page: "permissions" }, Cmd.batch([Cmd.showWindow("main"), Cmd.setDockPresence(true), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" })])];
    case "show_diagnostics":
      if (!model.platformSupported) return model;
      return [{ ...model, page: "diagnostics" }, Cmd.batch([Cmd.showWindow("main"), Cmd.setDockPresence(true), Cmd.request("friday.diagnostics", asciiBytes(""), { key: "diagnostics", ok: "diagnostics_loaded", err: "diagnostics_failed" })])];
    case "automation_contracts_requested":
      return [model, Cmd.request("friday.debug.contracts", msg.value, { key: "automation-contracts", ok: "automation_contracts_finished", err: "automation_contracts_failed" })];
    case "performance_fixture_requested":
      return [model, Cmd.request("friday.debug.performance", msg.value, { key: "automation-performance", ok: "performance_fixture_finished", err: "performance_fixture_failed" })];
    case "automation_hotkey_probe_requested":
      return [model, Cmd.request("friday.hotkey.probe", msg.value, { key: "automation-hotkey-probe", ok: "automation_hotkey_probe_finished", err: "automation_hotkey_probe_failed" })];
    case "automation_hotkey_probe_now": {
      if (model.workflow.kind !== "ready") return model;
      return [{ ...model, workflow: { kind: "starting", lockCandidate: true, committed: true, audioStarted: false, releasePending: false }, sessionId: 0 / 1, generation: 0 / 1, sessionSourceToken: asciiBytes("") }, Cmd.batch([
        Cmd.host("friday.performance.mark_hotkey", asciiBytes("")),
        Cmd.request("friday.source.capture", asciiBytes(""), { key: "source-capture", ok: "source_captured", err: "source_capture_failed" }),
      ])];
    }
    case "quit_app":
      return [model, Cmd.quitApp()];
    case "onboarding_next":
      if (!model.platformSupported) return model;
      if (model.onboardingStep === 0) return { ...model, onboardingStep: 1 / 1 };
      if (model.onboardingStep === 1 && model.microphonePermission && ((model.accessibilityPermission && model.inputMonitoringPermission) || model.limitedModeAccepted)) return { ...model, onboardingStep: 2 / 1 };
      if (model.onboardingStep === 2 && (model.hotkeyConfirmed || model.limitedModeAccepted)) {
        const next = { ...model, onboardingStep: 3 / 1 };
        if (!model.modelReady && model.modelDownloadState === "idle")
          return [{ ...next, modelDownloadState: "downloading", modelDownloadMessage: utf8Bytes("Downloading Parakeet for local transcription…") }, Cmd.request("friday.model.download", asciiBytes(""), { key: "model-download", ok: "model_downloaded", err: "model_download_failed" })];
        return next;
      }
      return model;
    case "onboarding_back":
      if (model.onboardingStep === 3 && modelDownloadActive(model)) return { ...model, modelDownloadMessage: utf8Bytes("Cancel the download before leaving model setup.") };
      return { ...model, onboardingStep: model.onboardingStep > 0 ? (model.onboardingStep - 1) / 1 : 0 / 1 };
    case "start_hotkey_capture":
      if (!model.platformSupported || !model.inputMonitoringPermission) return { ...model, hotkeyCandidateWarning: utf8Bytes("Input Monitoring permission is required to record a shortcut.") };
      return [{ ...model, hotkeyCaptureActive: true, hotkeyCandidateConfig: asciiBytes(""), hotkeyCandidateDisplay: asciiBytes(""), hotkeyCandidateWarning: utf8Bytes("Press and release Fn/Globe, an F-key, or any key combination."), hotkeyCandidateValid: false }, Cmd.request("friday.hotkey.capture", asciiBytes(""), { key: "hotkey-capture", ok: "hotkey_candidate", err: "hotkey_capture_failed" })];
    case "cancel_hotkey_capture":
      return [{ ...model, hotkeyCaptureActive: false, hotkeyChoice: byteEquals(model.hotkeyConfig, asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0")) ? "command_shift" : byteEquals(model.hotkeyConfig, asciiBytes("key=-1;command=0;shift=0;option=1;control=1;fn=0")) ? "control_option" : "custom", hotkeyCandidateConfig: asciiBytes(""), hotkeyCandidateDisplay: asciiBytes(""), hotkeyCandidateWarning: asciiBytes(""), hotkeyCandidateValid: false }, Cmd.cancel("hotkey-capture")];
    case "confirm_hotkey_candidate":
      if (!model.hotkeyCandidateValid || model.hotkeyCandidateConfig.length === 0) return model;
      return [model, Cmd.request("friday.hotkey.configure", model.hotkeyCandidateConfig, { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "choose_command_shift":
      return [{ ...model, hotkeyChoice: "command_shift", hotkeyCandidateConfig: asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0"), hotkeyCandidateDisplay: utf8Bytes("Command + Shift"), hotkeyCandidateWarning: asciiBytes(""), hotkeyCandidateValid: true }, Cmd.request("friday.hotkey.configure", asciiBytes("key=-1;command=1;shift=1;option=0;control=0;fn=0"), { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "choose_control_option":
      return [{ ...model, hotkeyChoice: "control_option", hotkeyCandidateConfig: asciiBytes("key=-1;command=0;shift=0;option=1;control=1;fn=0"), hotkeyCandidateDisplay: utf8Bytes("Control + Option"), hotkeyCandidateWarning: asciiBytes(""), hotkeyCandidateValid: true }, Cmd.request("friday.hotkey.configure", asciiBytes("key=-1;command=0;shift=0;option=1;control=1;fn=0"), { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "set_double_tap_fast":
      return [durableModel({ ...model, doubleTapWindowMs: 250 / 1 }), Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    case "set_double_tap_balanced":
      return [durableModel({ ...model, doubleTapWindowMs: 300 / 1 }), Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    case "set_double_tap_deliberate":
      return [durableModel({ ...model, doubleTapWindowMs: 400 / 1 }), Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })])];
    case "select_model": {
      if (isBusy(model)) return { ...model, modelDownloadMessage: utf8Bytes("Finish or cancel the active dictation before changing models.") };
      const key = parseUnsigned(msg.rowKey, 0, msg.rowKey.length);
      if (key !== 1 && key < 1000) return { ...model, modelDownloadMessage: utf8Bytes("That model is no longer available.") };
      return [model, Cmd.request("friday.model.select", utf8Bytes(`modelKey=${key};generation=0`), { key: "model-select", ok: "model_selected", err: "model_select_failed" })];
    }
    case "remove_model": {
      if (isBusy(model)) return { ...model, modelDownloadMessage: utf8Bytes("Finish or cancel the active dictation before removing models.") };
      const key = parseUnsigned(msg.rowKey, 0, msg.rowKey.length);
      if (key !== 1 && key < 1000) return { ...model, modelDownloadMessage: utf8Bytes("That model is no longer available.") };
      return [model, Cmd.request("friday.model.remove", utf8Bytes(`modelKey=${key};delete=0`), { key: "model-remove", ok: "model_removed", err: "model_remove_failed" })];
    }
    case "delete_model": {
      if (isBusy(model)) return { ...model, modelDownloadMessage: utf8Bytes("Finish or cancel the active dictation before deleting model files.") };
      const key = parseUnsigned(msg.rowKey, 0, msg.rowKey.length);
      if (key !== 1 && key < 1000) return { ...model, modelDownloadMessage: utf8Bytes("That model is no longer available.") };
      return [model, Cmd.request("friday.model.remove", utf8Bytes(`modelKey=${key};delete=1`), { key: "model-remove", ok: "model_removed", err: "model_remove_failed" })];
    }
    case "cancel_model_download":
      return [{ ...model, modelDownloadState: "cancelled", modelDownloadUserCancelled: true, modelDownloadMessage: utf8Bytes("Download cancelled. Retry when you are ready.") }, Cmd.cancel("model-download")];
    case "retry_model_download":
      if (!model.platformSupported) return model;
      if (model.modelDownloadState === "paused") return [{ ...model, modelDownloadState: "downloading", modelDownloadUserCancelled: false, modelDownloadMessage: utf8Bytes("Resuming the visible model download…") }, Cmd.request("friday.model.resume", asciiBytes(""), { key: "model-download", ok: "model_downloaded", err: "model_download_failed" })];
      return [{ ...model, modelDownloadState: "downloading", modelDownloadUserCancelled: false, modelDownloadMessage: utf8Bytes("Downloading Parakeet for local transcription…") }, Cmd.request("friday.model.download", asciiBytes(""), { key: "model-download", ok: "model_downloaded", err: "model_download_failed" })];
    case "choose_local_model":
      if (!model.platformSupported) return model;
      return [model, Cmd.request("friday.model.pick_local", asciiBytes(""), { key: "model-local-picker", ok: "local_model_added", err: "local_model_failed" })];
    case "local_model_added":
      return [{ ...model, modelDownloadState: "installed", modelDownloadMessage: utf8Bytes("Local model added and selected.") }, Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })];
    case "download_resolved_hf":
      if (!model.hfResolved || !model.hfResolvedConfirmed) return { ...model, modelDownloadMessage: utf8Bytes("Resolve the candidate and authorize its exact download for local verification.") };
      return [{ ...model, modelDownloadState: "downloading", modelDownloadMessage: utf8Bytes("Downloading the immutable candidate for exact local verification…") }, Cmd.request("friday.model.download_hf", model.hfResolvedIdentifier, { key: "model-hf-download", ok: "hf_model_added", err: "hf_model_failed" })];
    case "hf_model_added":
      return [{ ...model, hfSourceConfirmed: false, hfResolved: false, hfResolvedConfirmed: false, modelDownloadState: "installed", modelDownloadMessage: utf8Bytes("Verified Hugging Face model downloaded and selected.") }, Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })];
    case "model_selected":
      return [{ ...model, modelDownloadMessage: utf8Bytes("Active model changed.") }, Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })];
    case "model_removed":
      return [{ ...model, modelDownloadMessage: utf8Bytes("Model removed from Friday.") }, Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })];
    case "add_hugging_face_model":
      if (model.hfDraft.length === 0) return { ...model, modelDownloadMessage: utf8Bytes("Enter a public Hugging Face identifier first.") };
      if (!model.hfSourceConfirmed) return { ...model, modelDownloadMessage: utf8Bytes("Confirm that Friday may contact Hugging Face to resolve public metadata.") };
      if (!model.platformSupported) return model;
      return [{ ...model, hfResolved: false, hfResolvedConfirmed: false, modelDownloadMessage: utf8Bytes("Resolving immutable download-candidate metadata from Hugging Face…") }, Cmd.request("friday.model.resolve_hf", model.hfDraft, { key: "model-hf-resolve", ok: "hf_model_resolved", err: "hf_resolve_failed" })];
    case "remove_model_reference":
      if (isBusy(model)) return { ...model, modelDownloadMessage: utf8Bytes("Finish or cancel the active dictation before removing the active model.") };
      if (model.selectedModelKey === 0) return { ...model, modelDownloadMessage: utf8Bytes("No active model is available to remove.") };
      return [model, Cmd.request("friday.model.remove", utf8Bytes(`modelKey=${model.selectedModelKey};delete=0`), { key: "model-remove", ok: "model_removed", err: "model_remove_failed" })];
    case "delete_managed_model":
      if (isBusy(model)) return { ...model, modelDownloadMessage: utf8Bytes("Finish or cancel the active dictation before deleting the active model.") };
      if (model.selectedModelKey === 0) return { ...model, modelDownloadMessage: utf8Bytes("No active managed model is available to delete.") };
      return [model, Cmd.request("friday.model.remove", utf8Bytes(`modelKey=${model.selectedModelKey};delete=1`), { key: "model-remove", ok: "model_removed", err: "model_remove_failed" })];
    case "cleanup_model_downloads":
      if (modelDownloadActive(model)) return { ...model, modelDownloadMessage: utf8Bytes("Cancel the active download before cleaning partial files.") };
      return [model, Cmd.request("friday.model.cleanup", asciiBytes(""), { key: "model-cleanup", ok: "model_cleanup_finished", err: "model_cleanup_failed" })];
    case "refresh_microphone":
      return [model, Cmd.request("friday.audio.input_status", asciiBytes(""), { key: "microphone-status", ok: "microphone_loaded", err: "microphone_failed" })];
    case "copy_diagnostics_fresh":
      return [model, Cmd.request("friday.diagnostics", asciiBytes(""), { key: "diagnostics-copy", ok: "diagnostics_copy_loaded", err: "diagnostics_copy_failed" })];
    case "diagnostics_copy_loaded":
      return [{ ...model, diagnostics: msg.body }, Cmd.clipboardWrite(msg.body)];
    case "refresh_diagnostics":
      return [model, Cmd.request("friday.diagnostics", asciiBytes(""), { key: "diagnostics", ok: "diagnostics_loaded", err: "diagnostics_failed" })];
    case "copy_diagnostics":
      return [model, Cmd.clipboardWrite(model.diagnostics)];
    case "export_diagnostics":
      return [model, Cmd.request("friday.diagnostics.export", asciiBytes(""), { key: "diagnostics-export", ok: "diagnostics_exported", err: "diagnostics_export_failed" })];
    case "diagnostics_exported":
      return [{ ...model, diagnosticsExported: true }, Cmd.host("friday.diagnostics.reveal", asciiBytes(""))];
    case "reveal_diagnostics":
      if (model.diagnosticsExported) return [model, Cmd.host("friday.diagnostics.reveal", asciiBytes(""))];
      return model;
    case "login_setting_saved": {
      const enabled = contains(msg.body, asciiBytes("\"enabled\":true"));
      const approval = contains(msg.body, asciiBytes("\"requiresApproval\":true"));
      const durable = durableModel({ ...model, launchAtLogin: enabled, loginStatus: approval ? "requires_approval" : enabled ? "enabled" : "disabled" });
      return [durable, Cmd.batch([Cmd.persist(), Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }), Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }), Cmd.request("friday.login.status", asciiBytes(""), { key: "login-status", ok: "login_status_loaded", err: "login_status_failed" })])];
    }
    case "debug_fixture_requested":
      return [model, Cmd.request("friday.debug.fixture_delivery", msg.value, { key: "debug-fixture", ok: "debug_fixture_finished", err: "debug_fixture_failed" })];
    case "restored": {
      const restored = {
        ...durableModel(model),
        platformLoaded: false,
        platformSupported: false,
        platformMessage: utf8Bytes("Checking Mac compatibility…"),
      };
      return [restored, Cmd.request("friday.platform", asciiBytes(""), { key: "platform-status", ok: "platform_loaded", err: "platform_failed" })];
    }
    case "fresh_boot":
      return [durableModel(model), Cmd.request("friday.platform", asciiBytes(""), { key: "platform-status", ok: "platform_loaded", err: "platform_failed" })];
    case "restore_failed":
      return [durableModel(model), Cmd.request("friday.platform", asciiBytes(""), { key: "platform-status", ok: "platform_loaded", err: "platform_failed" })];
    case "model_downloaded": {
      const next = { ...model, modelsLoaded: true, modelReady: true, selectedModelKey: 1 / 1, modelDownloadState: "installed" as ModelDownloadState, modelDownloadMessage: utf8Bytes("Parakeet is ready for local transcription."), ambientDetail: utf8Bytes("Parakeet is ready for local transcription.") };
      return [next, Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" })];
    }
    case "confirm_hotkey":
      return [model, Cmd.request("friday.hotkey.configure", model.hotkeyConfig, { key: "hotkey-configure", ok: "hotkey_configured", err: "hotkey_failed" })];
    case "hotkey_configured": {
      const next = {
        ...model,
        hotkeyConfirmed: true,
        hotkeyConfig: model.hotkeyCandidateValid ? model.hotkeyCandidateConfig : model.hotkeyConfig,
        hotkeyDisplay: model.hotkeyCandidateValid ? model.hotkeyCandidateDisplay : model.hotkeyDisplay,
        hotkeyCandidateConfig: asciiBytes(""),
        hotkeyCandidateDisplay: asciiBytes(""),
        hotkeyCandidateWarning: asciiBytes(""),
        hotkeyCandidateValid: false,
        ambientDetail: utf8Bytes("Global shortcut active."),
      };
      const durable = durableModel(next);
      return [durable, Cmd.batch([
        Cmd.persist(),
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
    }
    case "request_microphone": return [model, Cmd.request("friday.permissions.request", asciiBytes("microphone"), { key: "permission-request", ok: "permissions_loaded", err: "permissions_failed" })];
    case "request_accessibility": return [model, Cmd.request("friday.permissions.request", asciiBytes("accessibility"), { key: "permission-request", ok: "permissions_loaded", err: "permissions_failed" })];
    case "request_input_monitoring": return [model, Cmd.request("friday.permissions.request", asciiBytes("input"), { key: "permission-request", ok: "permissions_loaded", err: "permissions_failed" })];
    case "complete_onboarding": {
      if (!canCompleteOnboarding(model)) return model;
      const durable = durableModel({ ...model, onboardingComplete: true, page: "settings" });
      return [durable, Cmd.batch([
        Cmd.persist(),
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
        Cmd.request("friday.login.status", asciiBytes(""), { key: "login-status", ok: "login_status_loaded", err: "login_status_failed" }),
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
    case "toggle_launch_at_login":
      if (isBusy(model)) return model;
      return [{ ...model, loginStatus: "checking" }, Cmd.request("friday.login.set", model.launchAtLogin ? asciiBytes("disabled") : asciiBytes("enabled"), { key: "login-setting", ok: "login_setting_saved", err: "login_setting_failed" })];
    case "start_recording": {
      if (!model.platformSupported) return model;
      if (model.workflow.kind !== "ready") return model;
      return [{ ...model, durationLimitReached: false, workflow: { kind: "starting", lockCandidate: false, committed: true, audioStarted: false, releasePending: false }, sessionId: 0 / 1, generation: 0 / 1, pressedAtMs: 0 / 1 }, Cmd.request("friday.source.capture", asciiBytes(""), { key: "source-capture", ok: "source_captured", err: "source_capture_failed" })];
    }
    case "source_captured": {
      if (model.workflow.kind !== "starting" || model.generation !== 0) return model;
      const generation = jsonInteger(msg.body, asciiBytes("\"generation\":"));
      if (generation === 0) return model;
      const current = model.workflow;
      const safeGeneration = generation / 1;
      return [{ ...model, workflow: current, sessionId: safeGeneration, generation: safeGeneration }, Cmd.request("friday.audio.start", utf8Bytes(`session=${safeGeneration};generation=${safeGeneration}`), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" })];
    }
    case "stop_recording": {
      if (model.workflow.kind !== "recording") return model;
      const current = model.workflow;
      return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" }, meterLevel: "quiet" }, Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_stopped", err: "audio_stop_failed" })];
    }
    case "cancel_active": {
      if (!isBusy(model) && model.workflow.kind !== "failed") return model;
      const source = model.workflow.kind === "ready" || model.workflow.kind === "not_ready" || model.workflow.kind === "booting" ? asciiBytes("") : model.sessionSourceToken;
      return [{ ...model, durationLimitReached: false, workflow: readiness(model), meterLevel: "quiet", elapsedMilliseconds: 0 / 1 }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.cancel("audio-session"), Cmd.host("friday.source.discard", source), Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
    }
    case "hold_elapsed": {
      if (model.workflow.kind !== "starting" || model.workflow.lockCandidate || model.workflow.committed) return model;
      const threshold = Math.max(300, model.minimumHoldMs);
      if (msg.at < model.pressedAtMs + threshold) return model;
      if (model.workflow.audioStarted)
        return { ...model, workflow: { kind: "recording", control: "held", warnedDurationLimit: false } };
      return { ...model, workflow: { ...model.workflow, committed: true } };
    }
    case "audio_stopped": {
      if (model.workflow.kind !== "stopping") return model;
      const session = jsonInteger(msg.body, asciiBytes("\"sessionId\":"));
      const generation = jsonInteger(msg.body, asciiBytes("\"generation\":"));
      if (session !== model.sessionId || generation !== model.generation) return model;
      const disposition = model.workflow.disposition;
      const capturedFrames = jsonInteger(msg.body, asciiBytes("\"capturedFrames\":"));
      if (disposition === "discard") return [{ ...model, capturedFrames: capturedFrames / 1, durationLimitReached: false, sessionSourceToken: asciiBytes(""), elapsedMilliseconds: 0 / 1, meterLevel: "quiet", workflow: { kind: "ready", modelKey: model.selectedModelKey } }, Cmd.batch([
        Cmd.host("friday.audio.discard", asciiBytes("")),
        Cmd.host("friday.source.discard", model.sessionSourceToken),
        Cmd.host("friday.overlay.hide", asciiBytes("")),
      ])];
      return [{ ...model, capturedFrames: capturedFrames / 1, durationLimitReached: disposition === "duration_limit", workflow: { kind: "transcribing", retryAudioAvailable: true, disposition } }, Cmd.batch([
        Cmd.delay("transcription-start", 250, "begin_transcription"),
        Cmd.host("friday.overlay.transcribing", asciiBytes("")),
      ])];
    }
    case "begin_transcription":
      if (model.workflow.kind !== "transcribing") return model;
      {
        const payload = encodeTranscriptionRequest(model.sessionId, model.generation);
        if (payload === null) return model;
        return [model, Cmd.request("friday.nemo.transcribe_capture", payload, { key: "audio-session", ok: "transcript_ready", err: "transcription_failed" })];
      }
    case "transcript_ready": {
      if (model.workflow.kind !== "transcribing") return model;
      const transcript = decodeTranscriptReady(msg.body);
      if (transcript === null || transcript.sessionId !== model.sessionId || transcript.generation !== model.generation) return model;
      const disposition = model.workflow.disposition;
      if (transcript.silence) return [{ ...model, hasImmediateResult: true, immediateResultKind: "shown", sessionSourceToken: asciiBytes(""), immediateResultMessage: disposition === "duration_limit" ? utf8Bytes("10-minute limit reached. No speech was detected, so nothing was pasted or copied.") : utf8Bytes("No speech detected. Nothing was pasted or copied."), lastQuickReleaseAtMs: 0 / 1, elapsedMilliseconds: 0 / 1, meterLevel: "quiet", workflow: { kind: "ready", modelKey: model.selectedModelKey } }, Cmd.batch([Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.source.discard", model.sessionSourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      const payload = encodeDeliveryRequest(transcript.sessionId, transcript.generation, model.pasteAutomatically);
      if (payload === null) return model;
      return [{ ...model, workflow: { kind: "delivering", disposition } }, Cmd.request("friday.deliver_session", payload, { key: "delivery", ok: "delivery_finished", err: "delivery_failed" })];
    }
    case "retry_transcription": {
      if (model.workflow.kind !== "failed" || model.workflow.stage !== "transcription" || !model.workflow.retryAudioAvailable) return model;
      const disposition: StopDisposition = model.durationLimitReached ? "duration_limit" : "transcribe";
      return [{ ...model, workflow: { kind: "transcribing", retryAudioAvailable: true, disposition } }, Cmd.request("friday.audio.retry", asciiBytes(""), { key: "audio-session", ok: "transcript_ready", err: "transcription_failed" })];
    }
    case "dismiss_failure":
      if (model.workflow.kind !== "failed") return model;
      return [{ ...model, durationLimitReached: false, workflow: readiness(model) }, Cmd.batch([Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.source.discard", model.sessionSourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
    case "copy_immediate_result":
      if (model.hasImmediateResult && model.immediateResultKind === "shown") return [model, Cmd.clipboardWrite(model.immediateResultMessage)];
      return model;
    case "host_event": {
      if (msg.state !== "data" || msg.key !== HOST_CHANNEL_KEY) return model;
      if (msg.droppedPending > 0 || msg.droppedTotal > 0) return [{ ...model, workflow: { kind: "not_ready" }, workflowMessage: asciiBytes("FridayHost event back-pressure invalidated the active session.") }, Cmd.batch([Cmd.cancel("audio-session"), Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
      if (hasPrefix(msg.bytes, asciiBytes("permissions|"))) return [model, Cmd.batch([
        Cmd.request("friday.permissions", asciiBytes(""), { key: "permissions", ok: "permissions_loaded", err: "permissions_failed" }),
        Cmd.request("friday.model.status", asciiBytes(""), { key: "model-status", ok: "model_status_loaded", err: "model_status_failed" }),
      ])];
      if (hasPrefix(msg.bytes, asciiBytes("model_progress|"))) {
        const operationEnd = findPipe(msg.bytes, 15);
        const stateEnd = findPipe(msg.bytes, operationEnd + 1);
        const downloadedEnd = findPipe(msg.bytes, stateEnd + 1);
        const state = msg.bytes.slice(operationEnd + 1, stateEnd);
        const downloaded = parseUnsigned(msg.bytes, stateEnd + 1, downloadedEnd);
        const total = parseUnsigned(msg.bytes, downloadedEnd + 1, msg.bytes.length);
        const downloadState: ModelDownloadState =
          byteEquals(state, asciiBytes("downloading")) ? "downloading" :
          byteEquals(state, asciiBytes("verifying")) ? "verifying" :
          byteEquals(state, asciiBytes("installed")) ? "installed" :
          byteEquals(state, asciiBytes("cancelled")) ? "cancelled" :
          byteEquals(state, asciiBytes("failed")) ? "failed" : model.modelDownloadState;
        return { ...model, modelDownloadState: downloadState, modelDownloadedBytes: downloaded / 1, modelTotalBytes: total / 1, modelDownloadedBytesLabel: groupedDigits(msg.bytes.slice(stateEnd + 1, downloadedEnd)), modelTotalBytesLabel: groupedDigits(msg.bytes.slice(downloadedEnd + 1, msg.bytes.length)) };
      }
      if (eventMatches(msg.bytes, asciiBytes("audio_meter|"), model) &&
          (model.workflow.kind === "recording" || (model.workflow.kind === "starting" && model.workflow.audioStarted))) {
        const generationEnd = findPipe(msg.bytes, 12);
        const sessionEnd = findPipe(msg.bytes, generationEnd + 1);
        const elapsedEnd = findPipe(msg.bytes, sessionEnd + 1);
        const levelEnd = findPipe(msg.bytes, elapsedEnd + 1);
        const elapsed = parseUnsigned(msg.bytes, sessionEnd + 1, elapsedEnd);
        const level = parseUnsigned(msg.bytes, elapsedEnd + 1, levelEnd);
        const frames = parseUnsigned(msg.bytes, levelEnd + 1, msg.bytes.length);
        return { ...model, elapsedMilliseconds: elapsed / 1, meterLevel: level >= 3 ? "high" : level === 2 ? "medium" : level === 1 ? "low" : "quiet", capturedFrames: frames / 1 };
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_down|"))) {
        const generationEnd = findPipe(msg.bytes, 12);
        const atEnd = findPipe(msg.bytes, generationEnd + 1);
        const tokenEnd = findPipe(msg.bytes, atEnd + 1);
        const generation = parseUnsigned(msg.bytes, 12, generationEnd);
        const at = parseUnsigned(msg.bytes, generationEnd + 1, atEnd);
        const token = msg.bytes.slice(atEnd + 1, tokenEnd);
        if (generation === 0 || at === 0) return model;
        if (!model.onboardingComplete && model.hotkeyConfirmed)
          return [{ ...model, hotkeyPracticed: true }, Cmd.host("friday.source.discard", token)];
        if (model.workflow.kind === "transcribing" || model.workflow.kind === "delivering" || model.workflow.kind === "stopping") {
          const session = generation;
          const delta = at >= model.lastQuickReleaseAtMs ? at - model.lastQuickReleaseAtMs : model.doubleTapWindowMs + 1;
          const lockCandidate = model.workflow.kind === "stopping" && model.workflow.disposition === "discard" && model.doubleTapEnabled && model.lastQuickReleaseAtMs > 0 && delta <= model.doubleTapWindowMs;
          const workflow: DictationWorkflow = { kind: "starting", lockCandidate, committed: lockCandidate, audioStarted: false, releasePending: false };
          return [{ ...model, workflow, sessionId: session / 1, generation: generation / 1, pressedAtMs: at / 1, sessionSourceToken: token }, Cmd.batch([
            Cmd.cancel("audio-session"), Cmd.cancel("delivery"),
            Cmd.host("friday.audio.discard", asciiBytes("")),
            Cmd.host("friday.source.discard", model.sessionSourceToken),
            Cmd.request("friday.audio.start", utf8Bytes(`session=${session};generation=${generation}`), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" }),
            lockCandidate ? Cmd.none : Cmd.delay("hold-start", Math.max(300, model.minimumHoldMs), "hold_elapsed"),
            model.overlayEnabled ? Cmd.host("friday.overlay.show", asciiBytes(lockCandidate ? "locked" : "held")) : Cmd.none,
          ])];
        }
        if (model.workflow.kind === "recording" && model.workflow.control === "locked") {
          const current = model.workflow;
          return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.batch([Cmd.host("friday.source.discard", token), Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_stopped", err: "audio_stop_failed" })])];
        }
        if (model.workflow.kind !== "ready") return model;
        const session = generation;
        const delta = at >= model.lastQuickReleaseAtMs ? at - model.lastQuickReleaseAtMs : model.doubleTapWindowMs + 1;
        const lockCandidate = model.doubleTapEnabled && model.lastQuickReleaseAtMs > 0 && delta <= model.doubleTapWindowMs;
        const workflow: DictationWorkflow = { kind: "starting", lockCandidate, committed: lockCandidate, audioStarted: false, releasePending: false };
        if (lockCandidate) return [{ ...model, workflow, sessionId: session / 1, generation: generation / 1, pressedAtMs: at / 1, sessionSourceToken: token }, Cmd.batch([
          Cmd.request("friday.audio.start", utf8Bytes(`session=${session};generation=${generation}`), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" }),
          model.overlayEnabled ? Cmd.host("friday.overlay.show", asciiBytes("locked")) : Cmd.none,
        ])];
        return [{ ...model, workflow, sessionId: session / 1, generation: generation / 1, pressedAtMs: at / 1, sessionSourceToken: token }, Cmd.batch([
          Cmd.request("friday.audio.start", utf8Bytes(`session=${session};generation=${generation}`), { key: "audio-session", ok: "audio_started", err: "audio_start_failed" }),
          Cmd.delay("hold-start", Math.max(300, model.minimumHoldMs), "hold_elapsed"),
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
          return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_stopped", err: "audio_stop_failed" })];
        }
        if (model.workflow.kind === "starting") {
          if (generation !== model.generation || at < model.pressedAtMs) return model;
          // A double-tap lock is armed the moment the second press lands, so
          // releasing that tap must not tear the session down: audio_started
          // promotes it to a locked recording. Tearing down here raced the
          // in-flight audio start and orphaned a live capture.
          if (model.workflow.lockCandidate) return model;
          const duration = at - model.pressedAtMs;
          const threshold = Math.max(300, model.minimumHoldMs);
          if (duration >= threshold) {
            if (model.workflow.audioStarted)
              return [{ ...model, workflow: { kind: "stopping", disposition: "transcribe" } }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_stopped", err: "audio_stop_failed" })])];
            return [{ ...model, workflow: { ...model.workflow, committed: true, releasePending: true } }, Cmd.cancel("hold-start")];
          }
          const quick = duration <= model.doubleTapWindowMs ? at / 1 : 0 / 1;
          if (model.workflow.audioStarted)
            return [{ ...model, hasImmediateResult: false, immediateResultMessage: asciiBytes(""), lastQuickReleaseAtMs: quick, workflow: { kind: "stopping", disposition: "discard" } }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`), { key: "audio-session", ok: "audio_stopped", err: "audio_stop_failed" })])];
          // Cancelling an in-flight start invokes the host's generation-scoped
          // cleanup. The explicit discards cover a completion already queued.
          return [{ ...model, hasImmediateResult: false, sessionSourceToken: asciiBytes(""), immediateResultMessage: asciiBytes(""), lastQuickReleaseAtMs: quick, workflow: { kind: "ready", modelKey: model.selectedModelKey } }, Cmd.batch([Cmd.cancel("hold-start"), Cmd.cancel("audio-session"), Cmd.host("friday.audio.discard", asciiBytes("")), Cmd.host("friday.source.discard", model.sessionSourceToken), Cmd.host("friday.overlay.hide", asciiBytes(""))])];
        }
        return model;
      }
      if (hasPrefix(msg.bytes, asciiBytes("hotkey_cancel|")) || hasPrefix(msg.bytes, asciiBytes("overlay_cancel|"))) return update(model, { kind: "cancel_active" });
      if (hasPrefix(msg.bytes, asciiBytes("overlay_stop|"))) return update(model, { kind: "stop_recording" });
      if (hasPrefix(msg.bytes, asciiBytes("overlay_dismiss|"))) return model;
      if (eventMatches(msg.bytes, asciiBytes("duration_warning|"), model) &&
          model.workflow.kind === "recording")
        return { ...model, workflow: { ...model.workflow, warnedDurationLimit: true } };
      if (eventMatches(msg.bytes, asciiBytes("duration_limit|"), model) &&
          model.workflow.kind === "recording")
        return [{ ...model, workflow: { kind: "stopping", disposition: "duration_limit" }, durationLimitReached: true },
                Cmd.request("friday.audio.stop", utf8Bytes(`session=${model.sessionId};generation=${model.generation}`),
                            { key: "audio-session", ok: "audio_stopped",
                              err: "audio_stop_failed" })];
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
  return model;
}
