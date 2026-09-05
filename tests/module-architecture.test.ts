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

test("native ownership modules point away from root adapters", () => {
  const modules = [
    "native/host/operation_registry.zig",
    "native/host/session_artifacts.zig",
    "native/host/diagnostics.zig",
    "native/macos/audio_ffi.zig",
    "native/macos/audio_route.zig",
    "native/macos/canonical_audio_store.zig",
    "native/macos/core_audio_backend.zig",
    "native/macos/model_policy.zig",
    "native/macos/model_publication.zig",
    "native/macos/model_source.zig",
  ];
  for (const relative of modules) {
    const source = readFileSync(join(root, relative), "utf8");
    assert.doesNotMatch(source, /@import\("(?:\.\.\/)*friday_host\.zig"\)/, `${relative} imports FridayHost`);
    assert.doesNotMatch(source, /@import\("(?:audio|models)\.zig"\)/, `${relative} imports its root coordinator`);
  }

  const models = readFileSync(join(root, "native/macos/models.zig"), "utf8");
  assert.match(models, /pub fn submit\(/);
  assert.match(models, /pub fn snapshot\(/);
  assert.doesNotMatch(models, /pub fn beginOperation\(/);
  assert.doesNotMatch(models, /pub fn (?:downloadDefault|resumePending|resolveHF|downloadResolvedHF|addLocal|select)\(/);

  const backend = readFileSync(join(root, "native/macos/core_audio_backend.zig"), "utf8");
  assert.doesNotMatch(backend, /\*AudioSession/);
  assert.match(backend, /pub const Sink = struct/);
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
