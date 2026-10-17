import { describe, test, expect } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { ocPaths } from "../core/paths.js";

// Round 4 m4 / m7: the preload isolates the user-local dispositions file and cleans up after itself.
const here = path.dirname(fileURLToPath(import.meta.url));

describe("test preload (test/setup.js)", () => {
  test("m4: CC_PARITY_DISPOSITIONS points at a nonexistent temp file, so no real user rule loads", () => {
    const f = process.env.CC_PARITY_DISPOSITIONS;
    expect(typeof f).toBe("string");
    expect(fs.existsSync(f)).toBe(false);
    expect(ocPaths().dispositionsFile).toBe(f);
  });
  test("m4: a caller's own env object without the key still gets the process override", () => {
    expect(ocPaths({}).dispositionsFile).toBe(process.env.CC_PARITY_DISPOSITIONS);
    expect(ocPaths({ CC_PARITY_DISPOSITIONS: "x.json" }).dispositionsFile).toBe("x.json");
  });
  test("m7: the preload's temp dir is removed when the process exits", () => {
    const env = { ...process.env };
    for (const k of ["XDG_DATA_HOME", "CC_PARITY_STATE", "CC_PARITY_DISPOSITIONS", "CC_PARITY_TEST_DIR"]) delete env[k];
    const setup = path.join(here, "setup.js").replaceAll("\\", "/");
    const r = spawnSync(process.execPath, ["-e", `await import(${JSON.stringify("file:///" + setup.replace(/^\/+/, ""))}); console.log(process.env.CC_PARITY_TEST_DIR)`], { env, encoding: "utf8" });
    expect(r.status).toBe(0);
    const dir = r.stdout.trim();
    expect(dir).toContain("ccp-test-");
    expect(fs.existsSync(dir)).toBe(false);
  });
  test("m7: under `bun test` too (its runner fires no process exit handlers; a preload afterAll cleans up)", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-m7-"));
    try {
      const out = path.join(tmpDir, "dir.txt");
      const probe = path.join(tmpDir, "probe.test.js");
      fs.writeFileSync(probe, `import { test } from "bun:test";
import fs from "node:fs";
test("p", () => fs.writeFileSync(${JSON.stringify(out)}, process.env.CC_PARITY_TEST_DIR));
`);
      const env = { ...process.env };
      for (const k of ["XDG_DATA_HOME", "CC_PARITY_STATE", "CC_PARITY_DISPOSITIONS", "CC_PARITY_TEST_DIR"]) delete env[k];
      const r = spawnSync(process.execPath, ["test", probe], { cwd: path.dirname(here), env, encoding: "utf8" });
      expect(r.status).toBe(0);
      const dir = fs.readFileSync(out, "utf8");
      expect(dir).toContain("ccp-test-");
      expect(fs.existsSync(dir)).toBe(false);
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
