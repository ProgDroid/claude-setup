import fs from "node:fs";
import path from "node:path";
import { ocPaths } from "./paths.js";

// Append-only cc-parity.log in the OC data dir (console.error never reaches opencode.log).
// Never throws: logging must not be able to break a hook. Returns whether the line was written, so a
// caller whose correctness depends on the log (the parity full list) can tell. `file` lets a caller
// write to the same path it shows the user.
export function log(msg, file = ocPaths().logFile) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(file, `${new Date().toISOString()} ${String(msg).replace(/\r?\n/g, " | ")}\n`);
    return true;
  } catch {
    return false;
  }
}
