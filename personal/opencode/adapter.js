import { createV1 } from "./v1/plugin.js";
import { log } from "./core/log.js";

// The CC parity adapter's OC V1 entry point. The stable loader (Task 12) imports `server`.
export const id = "cc-parity";

// Building the front-end never throws into OC: a failure is logged and the adapter loads empty.
export async function safeServer(ctx, create = createV1, logFn = log) {
  try {
    return await create(ctx);
  } catch (e) {
    try {
      logFn(`adapter init failed: ${String(e?.stack ?? e?.message ?? e)}`);
    } catch {
      // logging must not throw either
    }
    return {};
  }
}

export async function server(ctx) {
  return safeServer(ctx);
}

// OC v1.19.0 reads a default { id, server } first (plugin/shared.ts readV1Plugin, "detect" mode).
// Without it, its legacy path calls EVERY named export as a plugin function and throws on the
// string `id` (plugin/index.ts getLegacyPlugins), so this default is what makes the file loadable.
export default { id, server };
