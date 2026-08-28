import test from "node:test";
import assert from "node:assert/strict";
import { blockerText, commandMsg, initialModel, migrate, statusItem, update, type Model, type Msg } from "../src/core.ts";
import type { Cmd } from "@native-sdk/core";

type UpdateResult = Model | [Model, Cmd<Msg>];

const bytes = (value: string) => new TextEncoder().encode(value);
const modelOf = (result: UpdateResult): Model => Array.isArray(result) ? result[0] : result;
const commandOf = (result: UpdateResult) => Array.isArray(result) ? result[1] : null;
const dispatch = (model: Model, msg: Msg): Model => modelOf(update(model, msg));

function readyModel(): Model {
  const [initial] = initialModel();
  let model = dispatch(initial, { kind: "permissions_loaded", body: bytes('{"microphone":true,"accessibility":true,"inputMonitoring":true}') });
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
  model = { ...model, workflow: { kind: "transcribing", retryAudioAvailable: true }, sessionId: 10, generation: 10, sessionSourceToken: bytes("old") };
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
  model = dispatch(model, { kind: "transcript_ready", body: bytes('{"ok":true,"sessionId":7,"generation":7,"silence":true}') });
  assert.equal(model.workflow.kind, "ready");
  assert.equal(model.hasImmediateResult, true);

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
    workflow: { kind: "stopping", disposition: "transcribe" },
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
  assert.equal(labels.includes("Settings…"), true);
  assert.equal(labels.includes("Model Manager…"), true);
  assert.equal(labels.includes("Permission Status…"), true);
  assert.equal(labels.includes("Quit Friday"), true);

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
    workflow: { kind: "transcribing", retryAudioAvailable: false },
  };
  const transcribingLabels = statusItem(transcribing).items.map((item) => new TextDecoder().decode(item.label));
  assert.equal(transcribingLabels.includes("Stop Recording"), false);
  assert.equal(transcribingLabels.includes("Cancel"), true);
  assert.deepEqual(commandMsg("friday.models"), { kind: "show_models" });
  assert.equal(commandMsg("unknown"), null);
});

test("UI scene automation remains env-shaped and covers production surfaces", () => {
  const [initial] = initialModel();
  const onboarding = dispatch(initial, {
    kind: "automation_scene_requested",
    value: bytes("onboarding-light"),
  });
  assert.equal(onboarding.onboardingComplete, false);
  assert.equal(onboarding.onboardingStep, 1);
  assert.equal(onboarding.modelDownloadState, "downloading");
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
  const body = bytes('{"ok":true,"activeModelKey":1,"activeModelReady":true,"models":[{"displayName":"Local Parakeet","sourceLabel":"Local file · reference only","modelKey":2,"license":"CC-BY-4.0","languageSummary":"1 language","sizeText":"700 MB","managed":false,"active":false}],"modelCount":2,"managedBytes":713975456,"activeModelName":"Parakeet TDT 0.6B v3","activeModelSource":"Hugging Face · managed by Friday","activeModelLicense":"CC-BY-4.0","activeModelLanguages":"25 languages","activeModelSizeText":"714 MB","managedModelSizeText":"714 MB","activeModelBytes":713975456,"downloadedBytes":713975456,"totalBytes":713975456}');
  const loaded = dispatch(ready, { kind: "model_status_loaded", body });
  assert.equal(loaded.modelRows.length, 1);
  assert.equal(loaded.modelRows[0].modelKey, 2);
  assert.equal(new TextDecoder().decode(loaded.modelRows[0].name), "Local Parakeet");
  assert.equal(loaded.modelRows[0].managed, false);
  const selecting = update(loaded, { kind: "select_model", rowKey: 2 });
  const command = commandOf(selecting) as unknown as { op: string; payload: Uint8Array };
  assert.equal(command.op, "request");
  assert.equal(new TextDecoder().decode(command.payload), "modelKey=2;generation=0");
});
