import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { DeliveryKind, Model, Msg } from "./core.ts";
import { contains, jsonInteger, jsonString } from "./protocol.ts";

export function updateWorkflowState(model: Model, msg: Msg): Model | null {
  switch (msg.kind) {
    case "source_capture_failed":
      if (model.workflow.kind !== "starting") return model;
      return { ...model, workflow: { kind: "failed", stage: "capture", retryAudioAvailable: false }, workflowMessage: msg.error };
    case "audio_started": {
      if (model.workflow.kind !== "starting") return model;
      const session = jsonInteger(msg.body, asciiBytes("\"sessionId\":"));
      if (session !== model.sessionId) return model;
      return { ...model, durationLimitReached: false, capturedFrames: 0 / 1, elapsedMilliseconds: 0 / 1, meterLevel: "quiet", workflow: { kind: "recording", control: model.workflow.lockCandidate ? "locked" : "held", warnedDurationLimit: false } };
    }
    case "audio_start_failed":
      if (model.workflow.kind !== "starting") return model;
      return { ...model, workflow: { kind: "failed", stage: "capture", retryAudioAvailable: false }, workflowMessage: msg.error };
    case "audio_stop_failed":
      if (model.workflow.kind !== "stopping") return model;
      return { ...model, workflow: { kind: "failed", stage: "capture", retryAudioAvailable: false }, workflowMessage: msg.error };
    case "transcription_failed": {
      if (model.workflow.kind !== "transcribing") return model;
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
      const disposition = model.workflow.disposition;
      const kind: DeliveryKind = contains(msg.body, asciiBytes("\"kind\":\"pasted\"")) ? "pasted" : contains(msg.body, asciiBytes("\"kind\":\"clipboard\"")) ? "clipboard" : "shown";
      const message = disposition === "duration_limit"
        ? kind === "pasted" ? utf8Bytes("10-minute limit reached. Final text was pasted into the app where recording started.") : kind === "clipboard" ? utf8Bytes("10-minute limit reached. Final text was copied to the clipboard.") : jsonString(msg.body, asciiBytes("\"text\":\""))
        : kind === "pasted" ? utf8Bytes("Pasted into the app where recording started.") : kind === "clipboard" ? utf8Bytes("Copied to the clipboard because the exact source could not accept paste.") : jsonString(msg.body, asciiBytes("\"text\":\""));
      return { ...model, hasImmediateResult: true, immediateResultKind: kind, sessionSourceToken: asciiBytes(""), immediateResultMessage: message, elapsedMilliseconds: 0 / 1, meterLevel: "quiet", workflow: { kind: "ready", modelKey: model.selectedModelKey } };
    }
    case "delivery_failed": {
      if (model.workflow.kind !== "delivering") return model;
      const text = jsonString(msg.error, asciiBytes("\"text\":\""));
      return { ...model, hasImmediateResult: text.length > 0, immediateResultKind: "shown", immediateResultMessage: text, workflow: { kind: "failed", stage: "delivery", retryAudioAvailable: false }, workflowMessage: msg.error };
    }
    case "dismiss_result":
      if (model.workflow.kind !== "ready") return model;
      return { ...model, durationLimitReached: false, hasImmediateResult: false, immediateResultMessage: asciiBytes("") };
    default:
      return null;
  }
}
