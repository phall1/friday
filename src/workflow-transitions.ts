import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { DeliveryKind, Model, Msg } from "./core.ts";
import { concatBytes, decodeDeliveryFailure, decodeDeliveryResult, decodeTranscriptionFailure, jsonInteger } from "./protocol.ts";

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
      const failure = decodeTranscriptionFailure(msg.error);
      if (failure === null || failure.sessionId !== model.sessionId || failure.generation !== model.generation) return model;
      return { ...model, workflow: { kind: "failed", stage: "transcription", retryAudioAvailable: failure.retryAudioAvailable }, workflowMessage: msg.error };
    }
    case "delivery_finished": {
      if (model.workflow.kind !== "delivering") return model;
      const delivery = decodeDeliveryResult(msg.body);
      if (delivery === null || delivery.sessionId !== model.sessionId || delivery.generation !== model.generation) return model;
      const disposition = model.workflow.disposition;
      const kind: DeliveryKind = delivery.kind;
      const message = kind === "shown" ? delivery.text : disposition === "duration_limit" ? concatBytes(utf8Bytes("10-minute limit reached. "), delivery.message) : delivery.message;
      return { ...model, hasImmediateResult: true, immediateResultKind: kind, sessionSourceToken: asciiBytes(""), immediateResultMessage: message, elapsedMilliseconds: 0 / 1, meterLevel: "quiet", workflow: { kind: "ready", modelKey: model.selectedModelKey } };
    }
    case "delivery_failed": {
      if (model.workflow.kind !== "delivering") return model;
      const failure = decodeDeliveryFailure(msg.error);
      if (failure === null || (failure.hasIdentity && (failure.sessionId !== model.sessionId || failure.generation !== model.generation))) return model;
      return { ...model, hasImmediateResult: failure.text.length > 0, immediateResultKind: "shown", immediateResultMessage: failure.text, workflow: { kind: "failed", stage: "delivery", retryAudioAvailable: false }, workflowMessage: msg.error };
    }
    case "dismiss_result":
      if (model.workflow.kind !== "ready") return model;
      return { ...model, durationLimitReached: false, hasImmediateResult: false, immediateResultMessage: asciiBytes("") };
    default:
      return null;
  }
}
