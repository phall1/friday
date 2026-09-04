import type { TextInputEvent } from "@native-sdk/core/text";

export type HostChannelState = "data" | "closed" | "rejected";
export type HostChannelKey = 7001;
export type DeliveryKind = "pasted" | "clipboard" | "shown";
export type FailureStage = "capture" | "model" | "transcription" | "delivery";
export type RecordingControl = "held" | "locked";
export type StopDisposition = "transcribe" | "discard" | "cancel" | "duration_limit";
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
  readonly hfResolvedAllowlisted: boolean;
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
