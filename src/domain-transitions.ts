import type { Model, Msg } from "./domain.ts";
import { updateAppState } from "./app-transitions.ts";
import { updateModelState } from "./model-transitions.ts";
import { updateWorkflowState } from "./workflow-transitions.ts";

export type TransitionEffect = "none" | "hide_overlay" | "show_unsupported";

export interface DomainTransition {
  readonly model: Model;
  readonly effect: TransitionEffect;
}

function isTerminalWorkflowMessage(msg: Msg): boolean {
  return msg.kind === "source_capture_failed" ||
    msg.kind === "audio_start_failed" ||
    msg.kind === "audio_stop_failed" ||
    msg.kind === "transcription_failed" ||
    msg.kind === "delivery_finished" ||
    msg.kind === "delivery_failed";
}

/**
 * Owns message precedence across the three pure domains. A message is reduced
 * once, by the first domain that recognizes it. The returned semantic effect
 * lets core.ts remain the sole Native SDK command-construction adapter.
 */
export function reduceDomain(model: Model, msg: Msg): DomainTransition | null {
  const app = updateAppState(model, msg);
  if (app !== null) return {
    model: app,
    effect: msg.kind === "platform_failed" ? "show_unsupported" : "none",
  };

  const models = updateModelState(model, msg);
  if (models !== null) return { model: models, effect: "none" };

  const workflow = updateWorkflowState(model, msg);
  if (workflow === null) return null;
  return {
    model: workflow,
    effect: isTerminalWorkflowMessage(msg) && workflow !== model
      ? "hide_overlay"
      : "none",
  };
}
