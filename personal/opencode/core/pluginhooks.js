import fs from "node:fs";
import path from "node:path";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
  } catch {
    return undefined;
  }
}

// The one reader of a plugin's hook definitions, shared by enumerate (key drift) and
// collectHooks (the hooks themselves) so the two can never cover different sources.
// Sources: the default hooks/hooks.json, plus a manifest `hooks` (inline object, or
// path(s) to hooks files). Each file is read once even if two routes reach it.
// Returns [{ kind: "file", data: <hooks.json contents> } | { kind: "inline", data: <hooks object> }].
export function pluginHookSources(installPath) {
  const out = [];
  const seen = new Set();
  const addFile = (file) => {
    const abs = path.resolve(file);
    const key = process.platform === "win32" ? abs.toLowerCase() : abs;
    if (seen.has(key)) return;
    seen.add(key);
    const data = readJson(file);
    if (isObj(data)) out.push({ kind: "file", data });
  };
  addFile(path.join(installPath, "hooks", "hooks.json"));
  const m = readJson(path.join(installPath, ".claude-plugin", "plugin.json"));
  if (isObj(m) && m.hooks !== undefined) {
    if (isObj(m.hooks)) out.push({ kind: "inline", data: m.hooks });
    else {
      for (const rel of [].concat(m.hooks)) {
        if (typeof rel === "string") addFile(path.resolve(installPath, rel));
      }
    }
  }
  return out;
}
