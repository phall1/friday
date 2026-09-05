import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

test("mise pins the complete source-install toolchain", () => {
  const mise = readFileSync(join(root, "mise.toml"), "utf8");
  assert.match(mise, /^node = "24\.20\.0"$/m);
  assert.match(mise, /^zig = "0\.16\.0"$/m);
  assert.match(mise, /^bun = "1\.3\.14"$/m);
  assert.match(mise, /^\[tasks\.install-app\]$/m);
  assert.match(mise, /^run = "\.\/scripts\/install-from-source\.sh"$/m);

  const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  assert.equal(packageJson.engines.node, ">=24 <25");

  const readme = readFileSync(join(root, "README.md"), "utf8");
  assert.match(readme, /mise install\s+mise run install-app/);
});
