import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { Model, ModelDownloadState, Msg } from "./core.ts";
import { contains, decodeNativeMessage, jsonInteger, jsonIntegerLabel, jsonString, parseModelRows } from "./protocol.ts";
import { readiness } from "./state.ts";

function nativeReason(bytes: Uint8Array, fallback: Uint8Array): Uint8Array {
  const reason = decodeNativeMessage(bytes);
  return reason !== null && reason.length > 0 ? reason : fallback;
}

export function updateModelState(model: Model, msg: Msg): Model | null {
  switch (msg.kind) {
    case "hf_model_resolved":
      const allowlisted = contains(msg.body, asciiBytes("\"runtimeEligible\":true"));
      return {
        ...model,
        hfResolved: true,
        hfResolvedAllowlisted: allowlisted,
        hfResolvedIdentifier: jsonString(msg.body, asciiBytes("\"identifier\":\"")),
        hfResolvedRevision: jsonString(msg.body, asciiBytes("\"revision\":\"")),
        hfResolvedArtifact: jsonString(msg.body, asciiBytes("\"artifact\":\"")),
        hfResolvedSize: jsonString(msg.body, asciiBytes("\"sizeText\":\"")),
        hfResolvedLicense: jsonString(msg.body, asciiBytes("\"license\":\"")),
        hfResolvedProvider: jsonString(msg.body, asciiBytes("\"provider\":\"")),
        hfResolvedAttribution: jsonString(msg.body, asciiBytes("\"attribution\":\"")),
        hfResolvedConfirmed: false,
        modelDownloadState: "idle",
        modelDownloadMessage: allowlisted
          ? utf8Bytes("Immutable candidate matches Friday’s production allowlist. Confirm the exact download to verify and activate it.")
          : utf8Bytes("Metadata candidate resolved. It is not on Friday’s production allowlist, so its GGUF bytes will not be downloaded, parsed, probed, or activated."),
      };
    case "hf_resolve_failed":
      return { ...model, hfResolved: false, hfResolvedAllowlisted: false, hfResolvedConfirmed: false, modelDownloadMessage: nativeReason(msg.error, utf8Bytes("Friday could not resolve bounded public Hugging Face metadata.")) };
    case "toggle_hf_download_confirmation":
      return model.hfResolved && model.hfResolvedAllowlisted ? { ...model, hfResolvedConfirmed: !model.hfResolvedConfirmed } : model;
    case "clear_hf_candidate":
      return { ...model, hfDraft: asciiBytes(""), hfSourceConfirmed: false, hfResolved: false, hfResolvedAllowlisted: false, hfResolvedConfirmed: false, modelDownloadMessage: asciiBytes("") };
    case "local_model_failed":
      if (contains(msg.error, asciiBytes("\"code\":\"user_cancelled\""))) return { ...model, modelDownloadMessage: utf8Bytes("No local model selected.") };
      return { ...model, modelDownloadState: "failed", modelDownloadMessage: nativeReason(msg.error, utf8Bytes("Friday could not add that local model. Choose an allowlisted artifact and its matching Friday manifest.")) };
    case "hf_model_failed":
      return { ...model, hfSourceConfirmed: false, modelDownloadState: "failed", modelDownloadMessage: nativeReason(msg.error, utf8Bytes("Friday could not verify and install that Hugging Face candidate.")) };
    case "model_select_failed":
      return { ...model, modelDownloadMessage: nativeReason(msg.error, utf8Bytes("Friday could not make that model active.")) };
    case "model_remove_failed":
      return { ...model, modelDownloadMessage: nativeReason(msg.error, utf8Bytes("Friday could not remove that model.")) };
    case "hf_draft_edit":
      if (msg.edit.kind === "insert_text") {
        const room = model.hfDraft.length < 160 ? 160 - model.hfDraft.length : 0;
        const addition = msg.edit.text.slice(0, room);
        const next = new Uint8Array(model.hfDraft.length + addition.length);
        next.set(model.hfDraft, 0);
        next.set(addition, model.hfDraft.length);
        return { ...model, hfDraft: next, hfSourceConfirmed: false, hfResolved: false, hfResolvedAllowlisted: false, hfResolvedConfirmed: false };
      }
      if (msg.edit.kind === "delete_backward" && model.hfDraft.length > 0) return { ...model, hfDraft: model.hfDraft.slice(0, model.hfDraft.length - 1), hfSourceConfirmed: false, hfResolved: false, hfResolvedAllowlisted: false, hfResolvedConfirmed: false };
      if (msg.edit.kind === "clear") return { ...model, hfDraft: asciiBytes(""), hfSourceConfirmed: false, hfResolved: false, hfResolvedAllowlisted: false, hfResolvedConfirmed: false };
      return model;
    case "toggle_hf_source_confirmation":
      return { ...model, hfSourceConfirmed: !model.hfSourceConfirmed };
    case "choose_parakeet_ctc":
      return {
        ...model,
        hfDraft: asciiBytes("nvidia/parakeet-ctc-1.1b"),
        hfSourceConfirmed: false,
        hfResolved: false,
        hfResolvedAllowlisted: false,
        hfResolvedConfirmed: false,
        modelDownloadMessage: utf8Bytes("Parakeet CTC selected for metadata inspection. It cannot be downloaded or opened unless a future Friday release adds an exact reviewed artifact to the allowlist."),
      };
    case "model_cleanup_finished":
      return { ...model, modelDownloadState: "idle", modelDownloadedBytes: 0 / 1, modelTotalBytes: 0 / 1, modelDownloadedBytesLabel: asciiBytes("0"), modelTotalBytesLabel: asciiBytes("0"), modelDownloadMessage: contains(msg.body, asciiBytes("\"removed\":true")) ? utf8Bytes("Failed and partial downloads removed.") : utf8Bytes("No failed or partial downloads were present.") };
    case "model_cleanup_failed":
      return { ...model, modelDownloadMessage: nativeReason(msg.error, utf8Bytes("Friday could not clean failed and partial downloads.")) };
    case "model_status_loaded": {
      if (model.automationSceneActive) return model;
      const key = jsonInteger(msg.body, asciiBytes("\"activeModelKey\":"));
      const ready = key > 0 && contains(msg.body, asciiBytes("\"activeModelReady\":true"));
      const downloadActive = contains(msg.body, asciiBytes("\"downloadActive\":true"));
      const pendingResume = contains(msg.body, asciiBytes("\"pendingResumeAvailable\":true"));
      const next = {
        ...model,
        modelsLoaded: true,
        modelReady: ready,
        selectedModelKey: key > 0 ? key / 1 : 0 / 1,
        managedModelBytes: jsonInteger(msg.body, asciiBytes("\"managedBytes\":")),
        modelCount: jsonInteger(msg.body, asciiBytes("\"modelCount\":")),
        activeModelName: jsonString(msg.body, asciiBytes("\"activeModelName\":\"")),
        activeModelSource: jsonString(msg.body, asciiBytes("\"activeModelSource\":\"")),
        activeModelLicense: jsonString(msg.body, asciiBytes("\"activeModelLicense\":\"")),
        activeModelLanguages: jsonString(msg.body, asciiBytes("\"activeModelLanguages\":\"")),
        activeModelSizeText: jsonString(msg.body, asciiBytes("\"activeModelSizeText\":\"")),
        managedModelSizeText: jsonString(msg.body, asciiBytes("\"managedModelSizeText\":\"")),
        activeModelBytes: jsonInteger(msg.body, asciiBytes("\"activeModelBytes\":")),
        modelDownloadedBytes: downloadActive ? jsonInteger(msg.body, asciiBytes("\"downloadedBytes\":")) : pendingResume ? jsonInteger(msg.body, asciiBytes("\"pendingDownloadedBytes\":")) : 0 / 1,
        modelTotalBytes: downloadActive ? jsonInteger(msg.body, asciiBytes("\"totalBytes\":")) : pendingResume ? jsonInteger(msg.body, asciiBytes("\"pendingTotalBytes\":")) : 0 / 1,
        modelDownloadedBytesLabel: downloadActive ? jsonIntegerLabel(msg.body, asciiBytes("\"downloadedBytes\":")) : pendingResume ? jsonIntegerLabel(msg.body, asciiBytes("\"pendingDownloadedBytes\":")) : asciiBytes("0"),
        modelTotalBytesLabel: downloadActive ? jsonIntegerLabel(msg.body, asciiBytes("\"totalBytes\":")) : pendingResume ? jsonIntegerLabel(msg.body, asciiBytes("\"pendingTotalBytes\":")) : asciiBytes("0"),
        modelDownloadState: ready ? "installed" as ModelDownloadState : downloadActive ? "downloading" as ModelDownloadState : pendingResume ? "paused" as ModelDownloadState : model.modelDownloadState === "installed" ? "idle" as ModelDownloadState : model.modelDownloadState,
        modelRows: parseModelRows(msg.body),
        ambientDetail: msg.body,
      };
      if (model.workflow.kind === "booting" || model.workflow.kind === "not_ready" || model.workflow.kind === "ready") return { ...next, workflow: readiness(next) };
      return next;
    }
    case "model_status_failed": {
      const reason = nativeReason(msg.error, utf8Bytes("Friday could not read the local model library."));
      return { ...model, modelsLoaded: true, modelReady: false, workflow: { kind: "not_ready" }, modelDownloadState: "failed", modelDownloadMessage: reason, workflowMessage: reason, ambientDetail: reason };
    }
    case "model_download_failed": {
      const cancelled = contains(msg.error, asciiBytes("\"code\":\"cancelled\""));
      const reason = cancelled ? utf8Bytes("Download cancelled. Retry when you are ready.") : nativeReason(msg.error, utf8Bytes("Parakeet could not be downloaded. Check the connection and retry."));
      return { ...model, modelsLoaded: true, modelReady: false, modelDownloadState: cancelled ? "cancelled" : "failed", modelDownloadMessage: reason, workflow: { kind: "not_ready" }, workflowMessage: reason, ambientDetail: reason };
    }
    default:
      return null;
  }
}
