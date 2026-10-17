import fs from "node:fs";
import os from "node:os";
import { ccPaths } from "./paths.js";

// Enabled CC plugins -> install records. Versions come ONLY from
// installed_plugins.json (user-scope record -> installPath); cache dirs are never listed.
export function enabledPlugins({ home = os.homedir(), merged = {} } = {}) {
  const unknown = [];
  const ignored = [];
  const plugins = [];
  const file = ccPaths(home).installedPlugins;
  const enabled = Object.entries(merged.enabledPlugins || {})
    .filter(([, v]) => v === true)
    .map(([k]) => k);

  let installed = {};
  let readable = true;
  try {
    const d = JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
    installed = (d && d.plugins) || {};
  } catch (e) {
    readable = false;
    if (enabled.some((k) => !k.endsWith("@builtin"))) {
      unknown.push({ where: file, key: "installed_plugins", note: `unreadable or unparseable: ${e && (e.code || e.message)}` });
    }
  }

  for (const key of enabled) {
    const at = key.lastIndexOf("@");
    const name = at > 0 ? key.slice(0, at) : key;
    const marketplace = at > 0 ? key.slice(at + 1) : "";
    if (marketplace === "builtin") {
      ignored.push({ key, reason: "built into CC" });
      continue;
    }
    if (!readable) continue;
    const records = Array.isArray(installed[key]) ? installed[key] : [];
    const rec = records.find((r) => r && r.scope === "user");
    if (!rec || !rec.installPath) {
      unknown.push({
        where: file,
        key,
        note: records.length
          ? "plugin-missing: no user-scope install record"
          : "plugin-missing: enabled but not in installed_plugins.json",
      });
      continue;
    }
    const exists = fs.existsSync(rec.installPath);
    if (!exists) unknown.push({ where: rec.installPath, key, note: "plugin-missing: installPath does not exist" });
    plugins.push({ key, name, marketplace, version: rec.version, installPath: rec.installPath, exists });
  }
  return { plugins, unknown, ignored };
}
