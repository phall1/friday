import test from "node:test";
import assert from "node:assert/strict";
import { blockerText, commandMsg, failureDetail, failureModelName, initialModel, migrate, showUnsupported, statusItem, themeState, update, workflowDetail, type Model, type Msg } from "../src/core.ts";
import type { Cmd } from "@native-sdk/core";

type UpdateResult = Model | [Model, Cmd<Msg>];

const bytes = (value: string) => new TextEncoder().encode(value);
const modelOf = (result: UpdateResult): Model => Array.isArray(result) ? result[0] : result;
const commandOf = (result: UpdateResult) => Array.isArray(result) ? result[1] : null;
const dispatch = (model: Model, msg: Msg): Model => modelOf(update(model, msg));

function readyModel(): Model {
  const [initial] = initialModel();
  let model = dispatch(initial, { kind: "platform_loaded", body: bytes('{"ok":true,"supported":true,"architecture":"arm64","osVersion":"14.0","message":"Apple Silicon and macOS 14 or later detected."}') });
  model = dispatch(model, { kind: "permissions_loaded", body: bytes('{"microphone":true,"accessibility":true,"inputMonitoring":true}') });
  model = dispatch(model, { kind: "model_status_loaded", body: bytes('{"activeModelKey":1,"activeModelReady":true,"compatibility":"compatible"}') });
  model = dispatch(model, { kind: "hotkey_configured", body: bytes('{"ok":true}') });
  model = dispatch(model, { kind: "permissions_loaded", body: bytes('{"microphone":true,"accessibility":true,"inputMonitoring":true}') });
  model = dispatch(model, { kind: "model_status_loaded", body: bytes('{"activeModelKey":1,"activeModelReady":true,"compatibility":"compatible"}') });
  model = dispatch(model, { kind: "complete_onboarding" });
  model = dispatch(model, { kind: "permissions_loaded", body: bytes('{"microphone":true,"accessibility":true,"inputMonitoring":true}') });
  model = dispatch(model, { kind: "model_status_loaded", body: bytes('{"activeModelKey":1,"activeModelReady":true,"compatibility":"compatible"}') });
  assert.equal(model.workflow.kind, "ready");
  return model;
}

function hostEvent(value: string): Msg {
  return { kind: "host_event", key: 7001, state: "data", bytes: bytes(value), droppedPending: 0, droppedTotal: 0 };
}

test("boot readiness requires ambient permissions, hotkey, model, and onboarding", () => {
  const [initial, command] = initialModel();
  assert.equal(initial.workflow.kind, "booting");
  assert.equal(command.op, "batch");
  const ready = readyModel();
  assert.equal(ready.selectedModelKey, 1);
  assert.equal(ready.onboardingComplete, true);
});

test("short modifier tap seeds lock and second tap locks without long-hold seeding", () => {
  let model = readyModel();
  const firstDown = update(model, hostEvent("hotkey_down|1|1000|dG9rZW4=|1||"));
  model = modelOf(firstDown);
  assert.equal(model.workflow.kind, "starting");
  assert.equal(commandOf(firstDown)?.op, "batch");
  model = dispatch(model, hostEvent("hotkey_up|1|1100"));
  assert.equal(model.workflow.kind, "ready");
  assert.equal(model.lastQuickReleaseAtMs, 1100);
  model = dispatch(model, hostEvent("hotkey_down|2|1200|dG9rZW4y|1||"));
  assert.equal(model.workflow.kind, "starting");
  assert.equal(model.workflow.kind === "starting" && model.workflow.lockCandidate, true);
  model = dispatch(model, { kind: "audio_started", body: bytes('{"ok":true,"sessionId":2,"generation":2}') });
  assert.equal(model.workflow.kind, "recording");
  assert.equal(model.workflow.kind === "recording" && model.workflow.control, "locked");
  model = dispatch(model, hostEvent("hotkey_down|3|1300|bmV3|1||"));
  assert.equal(model.workflow.kind, "stopping");

  model = readyModel();
  model = dispatch(model, hostEvent("hotkey_down|4|2000|bG9uZw==|1||"));
  model = dispatch(model, { kind: "hold_elapsed", at: 2300 });
  model = dispatch(model, { kind: "audio_started", body: bytes('{"ok":true,"sessionId":4,"generation":4}') });
  model = dispatch(model, hostEvent("hotkey_up|4|2600"));
  assert.equal(model.workflow.kind, "stopping");
  assert.equal(model.lastQuickReleaseAtMs, 0);
});

test("new hotkey cancels transcribing generation and stale results are ignored", () => {
  let model = readyModel();
  model = { ...model, workflow: { kind: "transcribing", retryAudioAvailable: true, disposition: "transcribe" }, sessionId: 10, generation: 10, sessionSourceToken: bytes("old") };
  const restarted = update(model, hostEvent("hotkey_down|11|5000|bmV3|1||"));
  const next = modelOf(restarted);
  assert.equal(next.workflow.kind, "starting");
  assert.equal(next.generation, 11);
  assert.equal(commandOf(restarted)?.op, "batch");
  const stale = dispatch(next, { kind: "transcript_ready", body: bytes('{"ok":true,"sessionId":10,"generation":10,"silence":false}') });
  assert.deepEqual(stale, next);
});

test("silence, duration warning, duration limit, retry, and dismiss are exhaustive", () => {
  let model = readyModel();
  model = { ...model, workflow: { kind: "recording", control: "held", warnedDurationLimit: false }, sessionId: 7, generation: 7 };
  model = dispatch(model, hostEvent("duration_warning|7|7|e30="));
  assert.equal(model.workflow.kind === "recording" && model.workflow.warnedDurationLimit, true);
  model = dispatch(model, hostEvent("duration_limit|7|7|e30="));
  assert.equal(model.workflow.kind, "stopping");
  const drained = update(model, { kind: "audio_stopped", body: bytes('{"ok":true,"sessionId":7,"generation":7,"audioDurationMs":600000}') });
  model = modelOf(drained);
  assert.equal(model.workflow.kind, "transcribing");
  assert.equal(model.workflow.kind === "transcribing" && model.workflow.disposition, "duration_limit");
  assert.equal(new TextDecoder().decode(workflowDetail(model)), "10-minute limit reached. Transcribing captured audio locally.");
  assert.equal(commandOf(drained)?.op, "batch");
  model = dispatch(model, { kind: "transcript_ready", body: bytes('{"ok":true,"sessionId":7,"generation":7,"silence":true}') });
  assert.equal(model.workflow.kind, "ready");
  assert.equal(model.hasImmediateResult, true);
  assert.equal(new TextDecoder().decode(model.immediateResultMessage).startsWith("10-minute limit reached."), true);

  model = { ...model, workflow: { kind: "failed", stage: "transcription", retryAudioAvailable: true }, sessionId: 8, generation: 8 };
  model = dispatch(model, { kind: "retry_transcription" });
  assert.equal(model.workflow.kind, "transcribing");
  model = { ...model, workflow: { kind: "failed", stage: "transcription", retryAudioAvailable: true } };
  model = dispatch(model, { kind: "dismiss_failure" });
  assert.equal(model.workflow.kind, "ready");
});

test("v1 migration resets unreleased spike snapshots without transcript history", () => {
  const migrated = migrate(bytes("unreleased-v1"), 1);
  assert.equal(migrated.workflow.kind, "booting");
  assert.equal(migrated.hasImmediateResult, false);
  assert.equal(migrated.immediateResultMessage.length, 0);
});

test("non-silence transcript carries exact delivery identity and paste preference", () => {
  let model = readyModel();
  model = {
    ...model,
    workflow: { kind: "transcribing", retryAudioAvailable: true, disposition: "transcribe" },
    sessionId: 42,
    generation: 77,
    sessionSourceToken: bytes("opaque"),
    pasteAutomatically: false,
  };
  const result = update(model, {
    kind: "transcript_ready",
    body: bytes('{"ok":true,"sessionId":42,"generation":77,"silence":false}'),
  });
  const delivering = modelOf(result);
  assert.equal(delivering.workflow.kind, "delivering");
  const command = commandOf(result) as unknown as { op: string; payload: Uint8Array };
  assert.equal(command.op, "request");
  assert.equal(
    new TextDecoder().decode(command.payload),
    "session=42;generation=77;paste=0",
  );
  const delivered = dispatch(delivering, {
    kind: "delivery_finished",
    body: bytes('{"ok":true,"sessionId":42,"generation":77,"kind":"clipboard"}'),
  });
  assert.equal(delivered.workflow.kind, "ready");
  assert.equal(delivered.immediateResultKind, "clipboard");
});

test("stale duration and interruption facts cannot mutate the current session", () => {
  const base = readyModel();
  const recording: Model = {
    ...base,
    workflow: { kind: "recording", control: "held", warnedDurationLimit: false },
    sessionId: 9,
    generation: 11,
  };
  assert.deepEqual(
    dispatch(recording, hostEvent("duration_warning|10|9|e30=")),
    recording,
  );
  assert.deepEqual(
    dispatch(recording, hostEvent("duration_limit|11|8|e30=")),
    recording,
  );
  assert.deepEqual(
    dispatch(recording, hostEvent("audio_interrupted|10|9|e30=")),
    recording,
  );
  const interrupted = update(
    recording,
    hostEvent("audio_interrupted|11|9|e30="),
  );
  assert.equal(modelOf(interrupted).workflow.kind, "failed");
  assert.equal(commandOf(interrupted)?.op, "batch");
});

test("persistence projection scrubs every transient and ambient field", () => {
  let model = readyModel();
  model = {
    ...model,
    workflow: { kind: "ready", modelKey: 1 },
    sessionId: 91,
    generation: 92,
    pressedAtMs: 93,
    lastQuickReleaseAtMs: 94,
    capturedFrames: 95,
    sessionSourceToken: bytes("secret-source"),
    workflowMessage: bytes("secret-error"),
    hasImmediateResult: true,
    immediateResultMessage: bytes("secret-transcript"),
    ambientDetail: bytes("ambient"),
    hfSourceConfirmed: true,
    automationSceneActive: true,
    automationOverlayPreview: true,
  };
  const persisted = modelOf(update(model, { kind: "toggle_overlay" }));
  assert.equal(persisted.workflow.kind, "booting");
  assert.equal(persisted.sessionId, 0);
  assert.equal(persisted.generation, 0);
  assert.equal(persisted.sessionSourceToken.length, 0);
  assert.equal(persisted.workflowMessage.length, 0);
  assert.equal(persisted.hasImmediateResult, false);
  assert.equal(persisted.immediateResultMessage.length, 0);
  assert.equal(persisted.permissionsLoaded, false);
  assert.equal(persisted.modelsLoaded, false);
  assert.equal(persisted.modelReady, false);
  assert.equal(persisted.ambientDetail.length, 0);
  assert.equal(persisted.hfSourceConfirmed, false);
  assert.equal(persisted.automationSceneActive, false);
  assert.equal(persisted.automationOverlayPreview, false);
  const serialized = JSON.stringify(persisted);
  assert.equal(serialized.includes("secret-source"), false);
  assert.equal(serialized.includes("secret-transcript"), false);

  const restored = modelOf(update(model, { kind: "restored" }));
  assert.equal(restored.workflow.kind, "booting");
  assert.equal(restored.sessionSourceToken.length, 0);
  assert.equal(restored.hasImmediateResult, false);
  assert.equal(restored.microphonePermission, false);
  assert.equal(restored.modelReady, false);
});

test("menu-bar status exposes only legal workflow actions and exact destinations", () => {
  const ready = readyModel();
  const readyMenu = statusItem(ready);
  const labels = readyMenu.items.map((item) => new TextDecoder().decode(item.label));
  assert.equal(labels.includes("Start Recording"), true);
  assert.equal(labels.includes("Stop Recording"), false);
  assert.equal(labels.includes("Cancel"), false);
  assert.equal(labels.includes("Open Friday…"), true);
  assert.equal(labels.includes("Models…"), true);
  assert.equal(labels.includes("Access…"), true);
  assert.equal(labels.includes("Quit Friday"), true);
  assert.equal(readyMenu.iconPath.length, 0);
  assert.equal(new TextDecoder().decode(readyMenu.presentation.title), "F");
  assert.equal(readyMenu.activationCommand.length, 0);
  assert.equal(readyMenu.alternateActivationCommand.length, 0);
  assert.equal(readyMenu.openCommand.length, 0);

  const recording: Model = {
    ...ready,
    workflow: { kind: "recording", control: "held", warnedDurationLimit: false },
  };
  const recordingLabels = statusItem(recording).items.map((item) => new TextDecoder().decode(item.label));
  assert.equal(recordingLabels.includes("Start Recording"), false);
  assert.equal(recordingLabels.includes("Stop Recording"), true);
  assert.equal(recordingLabels.includes("Cancel"), true);

  const transcribing: Model = {
    ...ready,
    workflow: { kind: "transcribing", retryAudioAvailable: false, disposition: "transcribe" },
  };
  const transcribingLabels = statusItem(transcribing).items.map((item) => new TextDecoder().decode(item.label));
  assert.equal(transcribingLabels.includes("Stop Recording"), false);
  assert.equal(transcribingLabels.includes("Cancel"), true);
  assert.deepEqual(commandMsg("friday.models"), { kind: "show_models" });
  assert.equal(commandMsg("unknown"), null);
});

test("terminal dictation outcomes always dismiss the recording capsule", () => {
  const ready = readyModel();
  const delivering: Model = { ...ready, workflow: { kind: "delivering", disposition: "transcribe" }, sessionId: 9, generation: 9 };
  const delivered = update(delivering, { kind: "delivery_finished", body: bytes('{"sessionId":9,"generation":9,"kind":"pasted"}') });
  assert.equal(modelOf(delivered).workflow.kind, "ready");
  const command = commandOf(delivered) as unknown as { op: string; name: string };
  assert.equal(command.op, "host_bytes");
  assert.equal(command.name, "friday.overlay.hide");

  const transcribing: Model = { ...ready, workflow: { kind: "transcribing", retryAudioAvailable: true, disposition: "transcribe" }, sessionId: 10, generation: 10 };
  const failed = update(transcribing, { kind: "transcription_failed", error: bytes('{"sessionId":10,"generation":10,"message":"failed"}') });
  assert.equal(modelOf(failed).workflow.kind, "failed");
  assert.equal((commandOf(failed) as unknown as { name: string }).name, "friday.overlay.hide");

  const stale = update(transcribing, { kind: "transcription_failed", error: bytes('{"sessionId":8,"generation":8,"message":"stale"}') });
  assert.deepEqual(modelOf(stale), transcribing);
  assert.equal(commandOf(stale), null);
});

test("UI scene automation remains env-shaped and covers production surfaces", () => {
  const [initial] = initialModel();
  const onboarding = dispatch(initial, {
    kind: "automation_scene_requested",
    value: bytes("onboarding-light"),
  });
  assert.equal(onboarding.onboardingComplete, false);
  assert.equal(onboarding.onboardingStep, 1);
  assert.equal(onboarding.modelDownloadState, "idle");
  assert.equal(onboarding.accessibilityPermission, false);

  const settings = dispatch(initial, {
    kind: "automation_scene_requested",
    value: bytes("settings-dark"),
  });
  assert.equal(settings.onboardingComplete, true);
  assert.equal(settings.page, "settings");
  assert.equal(settings.appearanceOverride, "dark");
  assert.equal(settings.workflow.kind, "ready");

  const error = dispatch(initial, {
    kind: "automation_scene_requested",
    value: bytes("error-light"),
  });
  assert.equal(error.workflow.kind, "failed");
  assert.equal(new TextDecoder().decode(blockerText(onboarding)), "Input Monitoring is required for the global shortcut. Manual Start remains available in limited mode.");
});

test("packaged contract and performance routes remain automation-only effects", () => {
  const ready = readyModel();
  const contracts = update(ready, { kind: "automation_contracts_requested", value: bytes("1") });
  const contractsCommand = commandOf(contracts) as unknown as { name: string };
  assert.equal(contractsCommand.name, "friday.debug.contracts");
  const contractResult = dispatch(modelOf(contracts), {
    kind: "automation_contracts_finished",
    body: bytes('{"ok":true,"shaFailed":true,"routeChange":{"reasonMatched":true}}'),
  });
  assert.equal(contractResult.hasImmediateResult, true);
  assert.equal(new TextDecoder().decode(contractResult.immediateResultMessage).includes("reasonMatched"), true);

  const performance = update(ready, {
    kind: "performance_fixture_requested",
    value: bytes("20|fixture.f32|performance.json"),
  });
  const performanceCommand = commandOf(performance) as unknown as { name: string };
  assert.equal(performanceCommand.name, "friday.debug.performance");
  const result = dispatch(modelOf(performance), {
    kind: "performance_fixture_finished",
    body: bytes('{"ok":true,"iterations":20,"transcriptIncluded":false,"fixturePathIncluded":false}'),
  });
  assert.equal(new TextDecoder().decode(result.ambientDetail).includes("fixturePathIncluded"), true);
  assert.equal(result.hasImmediateResult, false);

  const hotkeyProbe = update(ready, {
    kind: "automation_hotkey_probe_requested",
    value: bytes("1"),
  });
  const hotkeyCommand = commandOf(hotkeyProbe) as unknown as { name: string };
  assert.equal(hotkeyCommand.name, "friday.hotkey.probe");
  const hotkeyNow = update(ready, { kind: "automation_hotkey_probe_now" });
  assert.equal(modelOf(hotkeyNow).workflow.kind, "starting");
  assert.equal(commandOf(hotkeyNow)?.op, "batch");
});

test("launch-at-login result is authoritative and persisted only after host success", () => {
  const ready = readyModel();
  const requested = update(ready, { kind: "toggle_launch_at_login" });
  assert.equal(modelOf(requested).loginStatus, "checking");
  const command = commandOf(requested) as unknown as { op: string; name: string; payload: Uint8Array };
  assert.equal(command.op, "request");
  assert.equal(command.name, "friday.login.set");
  assert.equal(new TextDecoder().decode(command.payload), "enabled");

  const saved = modelOf(update(ready, {
    kind: "login_setting_saved",
    body: bytes('{"ok":true,"enabled":true,"requiresApproval":false}'),
  }));
  assert.equal(saved.launchAtLogin, true);
  assert.equal(saved.workflow.kind, "booting");
  const hydrated = dispatch(saved, {
    kind: "login_status_loaded",
    body: bytes('{"ok":true,"enabled":true,"requiresApproval":false}'),
  });
  assert.equal(hydrated.loginStatus, "enabled");
});

test("model manager parses and acts on every available model row", () => {
  const ready = readyModel();
  const body = bytes('{"ok":true,"activeModelKey":1,"activeModelReady":true,"models":[{"displayName":"Local Parakeet","sourceLabel":"Local file · reference only","modelKey":1002,"license":"CC-BY-4.0","languageSummary":"1 language","sizeText":"700 MB","managed":false,"active":false}],"modelCount":2,"managedBytes":713975456,"activeModelName":"Parakeet TDT 0.6B v3","activeModelSource":"Hugging Face · managed by Friday","activeModelLicense":"CC-BY-4.0","activeModelLanguages":"25 languages","activeModelSizeText":"714 MB","managedModelSizeText":"714 MB","activeModelBytes":713975456,"downloadedBytes":713975456,"totalBytes":713975456}');
  const loaded = dispatch(ready, { kind: "model_status_loaded", body });
  assert.equal(loaded.modelRows.length, 1);
  assert.equal(new TextDecoder().decode(loaded.modelRows[0].modelKey), "1002");
  assert.equal(new TextDecoder().decode(loaded.modelRows[0].name), "Local Parakeet");
  assert.equal(loaded.modelRows[0].managed, false);
  const selecting = update(loaded, { kind: "select_model", rowKey: bytes("1002") });
  const command = commandOf(selecting) as unknown as { op: string; payload: Uint8Array };
  assert.equal(command.op, "request");
  assert.equal(new TextDecoder().decode(command.payload), "modelKey=1002;generation=0");
});

test("default model download starts only on visible model step", () => {
  const [initial] = initialModel();
  const status = update(initial, {
    kind: "model_status_loaded",
    body: bytes('{"ok":true,"activeModelKey":0,"activeModelReady":false,"downloadActive":false,"models":[]}'),
  });
  assert.equal(commandOf(status), null);
  const stepThree: Model = {
    ...modelOf(status),
    platformLoaded: true,
    platformSupported: true,
    workflow: { kind: "not_ready" },
    onboardingStep: 2,
    permissionsLoaded: true,
    modelsLoaded: true,
    microphonePermission: true,
    accessibilityPermission: true,
    inputMonitoringPermission: true,
    hotkeyConfirmed: true,
    modelReady: false,
    modelDownloadState: "idle",
  };
  const entered = update(stepThree, { kind: "onboarding_next" });
  assert.equal(modelOf(entered).onboardingStep, 3);
  assert.equal(modelOf(entered).modelDownloadState, "downloading");
  assert.equal(commandOf(entered)?.op, "request");
});

test("every missing degraded permission requires limited-mode acknowledgement", () => {
  const [initial] = initialModel();
  const permissionsStep: Model = {
    ...initial,
    platformLoaded: true,
    platformSupported: true,
    onboardingStep: 1,
    microphonePermission: true,
    accessibilityPermission: false,
    inputMonitoringPermission: true,
    limitedModeAccepted: false,
  };
  assert.equal(dispatch(permissionsStep, { kind: "onboarding_next" }).onboardingStep, 1);
  const acknowledged = dispatch(permissionsStep, { kind: "accept_limited_mode" });
  assert.equal(dispatch(acknowledged, { kind: "onboarding_next" }).onboardingStep, 2);
});

test("model cleanup is keyed, truthful, and blocked by an active download", () => {
  const ready = readyModel();
  const active: Model = { ...ready, modelDownloadState: "downloading" };
  const blocked = update(active, { kind: "cleanup_model_downloads" });
  assert.equal(commandOf(blocked), null);
  assert.equal(new TextDecoder().decode(modelOf(blocked).modelDownloadMessage), "Cancel the active download before cleaning partial files.");

  const request = update({ ...ready, modelDownloadState: "failed" }, { kind: "cleanup_model_downloads" });
  const command = commandOf(request) as unknown as { op: string; name: string };
  assert.equal(command.op, "request");
  assert.equal(command.name, "friday.model.cleanup");
  const failed = dispatch(ready, { kind: "model_cleanup_failed", error: bytes('{"ok":false,"message":"Cancel the active download before cleaning partial files."}') });
  assert.equal(new TextDecoder().decode(failed.modelDownloadMessage), "Cancel the active download before cleaning partial files.");
  const finished = dispatch(ready, { kind: "model_cleanup_finished", body: bytes('{"ok":true,"removed":true}') });
  assert.equal(new TextDecoder().decode(finished.modelDownloadMessage), "Failed and partial downloads removed.");
  const empty = dispatch(ready, { kind: "model_cleanup_finished", body: bytes('{"ok":true,"removed":false}') });
  assert.equal(new TextDecoder().decode(empty.modelDownloadMessage), "No failed or partial downloads were present.");
});

test("model operations produce plain user copy and picker cancellation is neutral", () => {
  const ready = readyModel();
  const selected = dispatch(ready, { kind: "model_selected", body: bytes('{"ok":true,"probe":{"residentBytes":99}}') });
  assert.equal(new TextDecoder().decode(selected.modelDownloadMessage), "Active model changed.");
  const cancelled = dispatch({ ...ready, modelDownloadState: "idle" }, {
    kind: "local_model_failed",
    error: bytes('{"ok":false,"code":"user_cancelled","message":"No local model was selected."}'),
  });
  assert.equal(cancelled.modelDownloadState, "idle");
  assert.equal(new TextDecoder().decode(cancelled.modelDownloadMessage), "No local model selected.");
  assert.equal(JSON.stringify(cancelled).includes('"probe"'), false);
});

test("Hugging Face add requires explicit source confirmation", () => {
  const ready = readyModel();
  const drafted = dispatch(ready, { kind: "hf_draft_edit", edit: { kind: "insert_text", text: bytes("nvidia/parakeet-tdt-0.6b-v3") } });
  const blocked = update(drafted, { kind: "add_hugging_face_model" });
  assert.equal(commandOf(blocked), null);
  assert.equal(new TextDecoder().decode(modelOf(blocked).modelDownloadMessage).includes("contact Hugging Face"), true);
  const confirmed = dispatch(drafted, { kind: "toggle_hf_source_confirmation" });
  const requested = update(confirmed, { kind: "add_hugging_face_model" });
  assert.equal(commandOf(requested)?.op, "request");
});

test("known Parakeet alternatives seed a safe unconfirmed repository", () => {
  const ready = readyModel();
  const chosen = dispatch({ ...ready, hfSourceConfirmed: true, hfResolved: true, hfResolvedConfirmed: true }, { kind: "choose_parakeet_ctc" });
  assert.equal(new TextDecoder().decode(chosen.hfDraft), "nvidia/parakeet-ctc-1.1b");
  assert.equal(chosen.hfSourceConfirmed, false);
  assert.equal(chosen.hfResolved, false);
  assert.equal(chosen.hfResolvedConfirmed, false);
  assert.equal(new TextDecoder().decode(chosen.modelDownloadMessage).includes("Authorize one metadata request"), true);
});

test("busy model actions explain why they cannot run", () => {
  const ready = readyModel();
  const busy: Model = { ...ready, workflow: { kind: "transcribing", retryAudioAvailable: false, disposition: "transcribe" } };
  const result = update(busy, { kind: "remove_model_reference" });
  assert.equal(commandOf(result), null);
  assert.equal(new TextDecoder().decode(modelOf(result).modelDownloadMessage).includes("Finish or cancel"), true);
});

test("failure copy includes native reason and active model identity", () => {
  const failed: Model = {
    ...readyModel(),
    activeModelName: bytes("Parakeet TDT 0.6B v3"),
    workflow: { kind: "failed", stage: "transcription", retryAudioAvailable: true },
    workflowMessage: bytes('{"ok":false,"message":"The model ran out of memory."}'),
  };
  assert.equal(new TextDecoder().decode(failureModelName(failed)), "Parakeet TDT 0.6B v3");
  assert.equal(new TextDecoder().decode(failureDetail(failed)), "The model ran out of memory.");
});

test("appearance and overlay-preview contracts retain accessibility state", () => {
  const [initial] = initialModel();
  const appearance = dispatch(initial, {
    kind: "appearance_changed",
    colorScheme: "dark",
    reduceMotion: true,
    highContrast: true,
  });
  assert.equal(appearance.reduceMotion, true);
  assert.equal(appearance.highContrast, true);
  assert.equal(appearance.systemColorScheme, "dark");
  assert.equal(themeState(appearance).pack, "geist");
  assert.equal(themeState(appearance).accent, undefined);
  const preview = dispatch(initial, { kind: "automation_scene_requested", value: bytes("overlay-preview-light") });
  assert.equal(preview.automationOverlayPreview, true);
  const dismissed = dispatch(preview, { kind: "dismiss_overlay_preview" });
  assert.equal(dismissed.automationOverlayPreview, false);
  assert.equal(dismissed.workflow.kind, "recording");
});

test("platform gate blocks Intel and old macOS without onboarding or network", () => {
  const [initial] = initialModel();
  const intel = dispatch(initial, {
    kind: "platform_loaded",
    body: bytes('{"ok":true,"supported":false,"architecture":"x86_64","osVersion":"14.6","message":"Friday requires an Apple Silicon Mac."}'),
  });
  assert.equal(showUnsupported(intel), true);
  assert.equal(new TextDecoder().decode(blockerText(intel)), "Friday requires an Apple Silicon Mac.");
  const intelItems = statusItem(intel).items.map((item) => new TextDecoder().decode(item.label));
  assert.deepEqual(intelItems.filter(Boolean), ["unsupported", "Open Friday…", "Quit Friday"]);
  assert.equal(commandOf(update(intel, { kind: "onboarding_next" })), null);
  assert.equal(commandOf(update(intel, { kind: "retry_model_download" })), null);
  assert.equal(commandOf(update(intel, { kind: "start_recording" })), null);

  const old = dispatch(initial, {
    kind: "platform_loaded",
    body: bytes('{"ok":true,"supported":false,"architecture":"arm64","osVersion":"13.6","message":"Friday requires macOS 14 or later."}'),
  });
  assert.equal(showUnsupported(old), true);
  assert.equal(new TextDecoder().decode(blockerText(old)), "Friday requires macOS 14 or later.");
  const translated = dispatch(initial, {
    kind: "platform_loaded",
    body: bytes('{"ok":true,"supported":false,"architecture":"x86_64 (Rosetta)","processTranslated":true,"osVersion":"14.6","message":"Friday cannot run through Rosetta."}'),
  });
  assert.equal(showUnsupported(translated), true);
  assert.equal(new TextDecoder().decode(blockerText(translated)), "Friday cannot run through Rosetta.");
  const current = dispatch(initial, {
    kind: "platform_loaded",
    body: bytes('{"ok":true,"supported":true,"architecture":"arm64","osVersion":"14.0","message":"Apple Silicon and macOS 14 or later detected."}'),
  });
  assert.equal(showUnsupported(current), false);
});

test("captured shortcuts preserve the active shortcut until a reviewed replacement is used", () => {
  const ready = readyModel();
  const reserved = dispatch(ready, {
    kind: "hotkey_candidate",
    body: bytes('{"ok":true,"valid":false,"config":"key=49;command=1;shift=0;option=0;control=0;fn=0","display":"Command + Space","warning":"That shortcut is reserved by macOS."}'),
  });
  assert.equal(reserved.hotkeyCandidateValid, false);
  assert.equal(reserved.hotkeyConfirmed, true);
  assert.equal(commandOf(update(reserved, { kind: "confirm_hotkey_candidate" })), null);
  const discarded = modelOf(update(reserved, { kind: "cancel_hotkey_capture" }));
  assert.equal(discarded.hotkeyConfirmed, true);
  assert.equal(new TextDecoder().decode(discarded.hotkeyDisplay), "Command + Shift");

  const keyCandidate = dispatch(ready, {
    kind: "hotkey_candidate",
    body: bytes('{"ok":true,"valid":true,"config":"key=0;command=1;shift=1;option=0;control=0;fn=0","display":"Shift + Command + A","warning":""}'),
  });
  const keySave = update(keyCandidate, { kind: "confirm_hotkey_candidate" });
  const keyCommand = commandOf(keySave) as unknown as { op: string; payload: Uint8Array };
  assert.equal(keyCommand.op, "request");
  assert.equal(new TextDecoder().decode(keyCommand.payload), "key=0;command=1;shift=1;option=0;control=0;fn=0");
  const promoted = modelOf(update(keyCandidate, { kind: "hotkey_configured", body: bytes('{"ok":true}') }));
  assert.equal(new TextDecoder().decode(promoted.hotkeyConfig), "key=0;command=1;shift=1;option=0;control=0;fn=0");
  assert.equal(new TextDecoder().decode(promoted.hotkeyDisplay), "Shift + Command + A");

  const functionCandidate = dispatch(ready, {
    kind: "hotkey_candidate",
    body: bytes('{"ok":true,"valid":true,"config":"key=96;command=0;shift=0;option=0;control=0;fn=0","display":"F5","warning":""}'),
  });
  assert.equal(functionCandidate.hotkeyCandidateValid, true);
  const fnCandidate = dispatch(ready, {
    kind: "hotkey_candidate",
    body: bytes('{"ok":true,"valid":true,"config":"key=-1;command=0;shift=0;option=0;control=0;fn=1","display":"Fn","warning":""}'),
  });
  assert.equal(fnCandidate.hotkeyCandidateValid, true);
  const preset = update(ready, { kind: "choose_control_option" });
  assert.equal(commandOf(preset)?.op, "request");
  assert.equal(modelOf(preset).hotkeyCandidateValid, true);
});

test("microphone onboarding action invokes the permission-request host path", () => {
  const [initial] = initialModel();
  const result = update(initial, { kind: "request_microphone" });
  const command = commandOf(result) as unknown as { op: string; name: string; payload: Uint8Array };
  assert.equal(command.op, "request");
  assert.equal(command.name, "friday.permissions.request");
  assert.equal(new TextDecoder().decode(command.payload), "microphone");
});

test("schema migration seeds a safe confirmed-shortcut candidate model", () => {
  const migrated = migrate(bytes("unreleased-v10"), 10);
  assert.equal(new TextDecoder().decode(migrated.hotkeyConfig), "key=-1;command=1;shift=1;option=0;control=0;fn=0");
  assert.equal(new TextDecoder().decode(migrated.hotkeyDisplay), "Command + Shift");
  assert.equal(migrated.hotkeyCandidateValid, false);
});

test("normal stop drains before entering real transcribing state", () => {
  const recording: Model = {
    ...readyModel(),
    workflow: { kind: "recording", control: "held", warnedDurationLimit: false },
    sessionId: 51,
    generation: 51,
  };
  const stopping = update(recording, { kind: "stop_recording" });
  assert.equal(modelOf(stopping).workflow.kind, "stopping");
  const stopCommand = commandOf(stopping) as unknown as { op: string; name: string };
  assert.equal(stopCommand.name, "friday.audio.stop");
  const transcribing = update(modelOf(stopping), {
    kind: "audio_stopped",
    body: bytes('{"ok":true,"sessionId":51,"generation":51,"audioDurationMs":1200}'),
  });
  assert.equal(modelOf(transcribing).workflow.kind, "transcribing");
  assert.equal(new TextDecoder().decode(workflowDetail(modelOf(transcribing))), "Transcribing locally with the active Parakeet model.");
  assert.equal(commandOf(transcribing)?.op, "batch");
  const inference = update(modelOf(transcribing), { kind: "begin_transcription", at: 250 });
  const inferenceCommand = commandOf(inference) as unknown as { op: string; name: string };
  assert.equal(inferenceCommand.name, "friday.nemo.transcribe_capture");
  const labels = statusItem(modelOf(transcribing)).items.map((item) => new TextDecoder().decode(item.label));
  assert.equal(labels.includes("Cancel"), true);
});

test("duration-limit disposition survives delivery until acknowledgement", () => {
  let model: Model = {
    ...readyModel(),
    workflow: { kind: "transcribing", retryAudioAvailable: true, disposition: "duration_limit" },
    durationLimitReached: true,
    sessionId: 61,
    generation: 61,
  };
  model = modelOf(update(model, {
    kind: "transcript_ready",
    body: bytes('{"ok":true,"sessionId":61,"generation":61,"silence":false}'),
  }));
  assert.equal(model.workflow.kind === "delivering" && model.workflow.disposition, "duration_limit");
  model = dispatch(model, {
    kind: "delivery_finished",
    body: bytes('{"ok":true,"sessionId":61,"generation":61,"kind":"clipboard"}'),
  });
  assert.equal(new TextDecoder().decode(model.immediateResultMessage), "10-minute limit reached. Final text was copied to the clipboard.");
  assert.equal(model.durationLimitReached, true);
  model = dispatch(model, { kind: "dismiss_result" });
  assert.equal(model.durationLimitReached, false);
});

test("pending partial status hydrates paused bytes and Resume command", () => {
  const ready = readyModel();
  const paused = dispatch(ready, {
    kind: "model_status_loaded",
    body: bytes('{"ok":true,"activeModelKey":0,"activeModelReady":false,"downloadActive":false,"pendingResumeAvailable":true,"pendingDownloadedBytes":321000000,"pendingTotalBytes":713975456,"models":[]}'),
  });
  assert.equal(paused.modelDownloadState, "paused");
  assert.equal(paused.modelDownloadedBytes, 321000000);
  assert.equal(paused.modelTotalBytes, 713975456);
  assert.equal(new TextDecoder().decode(paused.modelDownloadedBytesLabel), "321,000,000");
  assert.equal(new TextDecoder().decode(paused.modelTotalBytesLabel), "713,975,456");
  const resume = update(paused, { kind: "retry_model_download" });
  const command = commandOf(resume) as unknown as { op: string; name: string };
  assert.equal(command.name, "friday.model.resume");
});

test("HF identifier flow resolves an unverified immutable candidate before local verification", () => {
  let model = readyModel();
  model = dispatch(model, { kind: "hf_draft_edit", edit: { kind: "insert_text", text: bytes("community/parakeet-tdt-gguf") } });
  model = dispatch(model, { kind: "toggle_hf_source_confirmation" });
  const resolve = update(model, { kind: "add_hugging_face_model" });
  const resolveCommand = commandOf(resolve) as unknown as { name: string };
  assert.equal(resolveCommand.name, "friday.model.resolve_hf");
  model = dispatch(modelOf(resolve), {
    kind: "hf_model_resolved",
    body: bytes('{"ok":true,"identifier":"community/parakeet-tdt-gguf","revision":"0123456789abcdef0123456789abcdef01234567","artifact":"parakeet-q8.gguf","sizeText":"702 MB","license":"cc-by-4.0","provider":"Hugging Face","attribution":"community"}'),
  });
  assert.equal(model.hfResolved, true);
  const candidateMessage = new TextDecoder().decode(model.modelDownloadMessage);
  assert.equal(candidateMessage.includes("Unverified"), true);
  assert.equal(candidateMessage.includes("before it can become compatible or active"), true);
  assert.equal(commandOf(update(model, { kind: "download_resolved_hf" })), null);
  model = dispatch(model, { kind: "toggle_hf_download_confirmation" });
  const download = update(model, { kind: "download_resolved_hf" });
  const downloadCommand = commandOf(download) as unknown as { name: string; payload: Uint8Array };
  assert.equal(downloadCommand.name, "friday.model.download_hf");
  assert.equal(new TextDecoder().decode(downloadCommand.payload), "community/parakeet-tdt-gguf");
  const cleared = dispatch(model, { kind: "clear_hf_candidate" });
  assert.equal(cleared.hfResolved, false);
});
