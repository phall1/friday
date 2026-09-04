import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const read = (path: string) => readFileSync(path, "utf8");

test("the stock SDK runner owns the app-extension host lifecycle", () => {
  const patch = read("patches/@native-sdk+cli+0.10.1.patch");
  const build = read("build.zig");

  assert.equal(existsSync("native/friday_main.zig"), false);
  assert.doesNotMatch(build, /ts_runner/);
  assert.match(build, /\.ts_extension = "native\/friday_host\.zig"/);

  // These are the actual stock-runner call sites. Removing construction,
  // destruction, or binding makes this test fail even when FridayHost still
  // happens to compile in isolation.
  assert.match(patch, /\+\s*var extension_host = try app_extension\.Host\.create\(/);
  assert.match(patch, /\+\s*defer extension_host\.destroy\(\);/);
  assert.match(patch, /\+\s*extension_host\.binding\(\),/);
  assert.doesNotMatch(patch, /\+\s*ts_runner:/);
});
