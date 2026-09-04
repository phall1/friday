import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { basename, dirname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { reduceDomain } from "../src/domain-transitions.ts";
import { defaultModel } from "../src/state.ts";

const root = normalize(join(dirname(fileURLToPath(import.meta.url)), ".."));

function sourceGraph(): ReadonlyMap<string, readonly string[]> {
  const sourceRoot = join(root, "src");
  const files = readdirSync(sourceRoot)
    .filter((name) => name.endsWith(".ts"))
    .map((name) => join(sourceRoot, name));
  const known = new Set(files);
  return new Map(files.map((file) => {
    const imports = [...readFileSync(file, "utf8").matchAll(/from\s+["'](\.\/.+?\.ts)["']/g)]
      .map((match) => normalize(join(dirname(file), match[1])))
      .filter((dependency) => known.has(dependency));
    return [file, imports] as const;
  }));
}

test("TypeScript module dependencies are acyclic and point away from core", () => {
  const graph = sourceGraph();
  const core = join(root, "src", "core.ts");
  const visited = new Set<string>();
  const active = new Set<string>();

  function visit(file: string): void {
    if (active.has(file)) assert.fail(`import cycle reaches ${basename(file)}`);
    if (visited.has(file)) return;
    active.add(file);
    for (const dependency of graph.get(file) ?? []) visit(dependency);
    active.delete(file);
    visited.add(file);
  }

  for (const file of graph.keys()) visit(file);
  for (const [file, dependencies] of graph) {
    if (file !== core) assert.equal(dependencies.includes(core), false, `${basename(file)} imports the root adapter`);
  }
});

test("domain routing owns semantic terminal and platform effects", () => {
  const model = defaultModel();
  const unsupported = reduceDomain(model, { kind: "platform_failed", error: new Uint8Array() });
  assert.equal(unsupported?.effect, "show_unsupported");

  const starting = {
    ...model,
    workflow: { kind: "starting", lockCandidate: false, committed: true, audioStarted: false, releasePending: false } as const,
  };
  const captureFailure = reduceDomain(starting, { kind: "audio_start_failed", error: new TextEncoder().encode("failed") });
  assert.equal(captureFailure?.effect, "hide_overlay");

  const appearance = reduceDomain(model, { kind: "appearance_changed", colorScheme: "dark", reduceMotion: true, highContrast: true });
  assert.equal(appearance?.effect, "none");
});
