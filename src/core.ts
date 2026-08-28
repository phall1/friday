import { Cmd, asciiBytes, utf8Bytes } from "@native-sdk/core";

export type BridgeState = "checking" | "requesting" | "ready" | "failed";

export interface Model {
  readonly bridgeState: BridgeState;
  readonly bridgeDetail: Uint8Array;
}

export type Msg =
  | { readonly kind: "run_spike" }
  | { readonly kind: "spike_ok"; readonly body: Uint8Array }
  | { readonly kind: "spike_error"; readonly error: Uint8Array };

export const viewUnbound = ["spike_ok", "spike_error"] as const;


export function initialModel(): Model {
  return {
    bridgeState: "checking",
    bridgeDetail: utf8Bytes("Checking the FridayHost bridge…"),
  };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "run_spike":
      return [
        {
          bridgeState: "requesting",
          bridgeDetail: utf8Bytes("Checking the FridayHost bridge…"),
        },
        Cmd.request("friday.spike", asciiBytes("{}"), {
          key: "friday-spike",
          ok: "spike_ok",
          err: "spike_error",
        }),
      ];
    case "spike_ok":
      return { bridgeState: "ready", bridgeDetail: msg.body };
    case "spike_error":
      return { bridgeState: "failed", bridgeDetail: msg.error };
  }
}
