// Bun test preload (bunfig.toml). Points the OC data dir, the parity state file and the user-local
// dispositions file at a fresh temp dir unless the caller already set them, so a bare `bun test`
// can never write the user's real cc-parity.log or state file, nor read their real
// cc-parity-dispositions.json (round 4 m4: a catch-all user rule there failed 41 tests). The
// dispositions path is left nonexistent: no user rules. It runs before any test module is loaded;
// ocPaths() also reads env lazily, per call. The temp dir is removed afterwards (m7).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

if (!process.env.XDG_DATA_HOME || !process.env.CC_PARITY_STATE || !process.env.CC_PARITY_DISPOSITIONS) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-test-"));
  process.env.CC_PARITY_TEST_DIR = dir;
  process.env.XDG_DATA_HOME ||= path.join(dir, "xdg-data");
  process.env.CC_PARITY_STATE ||= path.join(dir, "state.json");
  process.env.CC_PARITY_DISPOSITIONS ||= path.join(dir, "no-user-dispositions.json");
  const cleanup = () => {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      // best effort: a file still held open on Windows
    }
  };
  // Bun 1.4.0's test runner does not fire process "exit" handlers (measured), so under `bun test` a
  // global afterAll from this preload does the cleanup; "exit" covers a plain import of this file.
  process.on("exit", cleanup);
  try {
    const { afterAll } = await import("bun:test");
    afterAll(cleanup);
  } catch {
    // not under the test runner
  }
}
