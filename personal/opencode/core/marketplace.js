import fs from "node:fs";
import path from "node:path";

// Inline components of a marketplace entry. CC 2.1.300 (plugin loader fWn/Hoe, bundle): the
// manifest is read from <installPath>/.claude-plugin/plugin.json; when that file exists the
// entry's own mcpServers/lspServers are ignored (only commands/agents/skills/hooks/outputStyles/
// themes append). When it does NOT exist, the entry itself (minus id/source/strict) is the
// manifest, so an inline `mcpServers` map is a real plugin MCP server definition.

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function readJsonFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    return { err: e && e.code === "ENOENT" ? "not found" : `unreadable: ${e && (e.code || e.message)}` };
  }
  try {
    return { data: JSON.parse(text.replace(/^﻿/, "")) };
  } catch {
    return { err: "unparseable JSON" };
  }
}

// inlineEntry(plugin, { home, unknown? }) -> the marketplace entry object when the plugin's
// manifest is the entry, else undefined. Anything that stops the entry being read is reported
// in `unknown` (fail closed: the caller then simply has no inline servers for that plugin).
export function inlineEntry(plugin, { home, unknown = [] } = {}) {
  if (!home || !plugin || !plugin.installPath || !plugin.marketplace) return undefined;
  if (fs.existsSync(path.join(plugin.installPath, ".claude-plugin", "plugin.json"))) return undefined;
  const name = plugin.name || plugin.key;
  const known = path.join(home, ".claude", "plugins", "known_marketplaces.json");
  const fail = (where, why) => {
    unknown.push({
      where,
      key: `plugin:${name}:marketplace-entry`,
      note: `plugin has no plugin.json and its marketplace entry could not be read (${why}); inline mcpServers/lspServers not enumerated`,
    });
    return undefined;
  };
  const k = readJsonFile(known);
  if (k.err) return fail(known, k.err);
  const rec = isObj(k.data) ? k.data[plugin.marketplace] : undefined;
  const loc = isObj(rec) && typeof rec.installLocation === "string" ? rec.installLocation : "";
  if (!loc) return fail(known, `no installLocation for marketplace ${String(plugin.marketplace).slice(0, 40)}`);
  const candidates = /\.json$/i.test(loc) ? [loc] : [path.join(loc, ".claude-plugin", "marketplace.json"), path.join(loc, "marketplace.json")];
  let last = "not found";
  for (const file of candidates) {
    const m = readJsonFile(file);
    if (m.err) {
      last = m.err;
      if (m.err === "not found") continue;
      return fail(file, m.err);
    }
    const plugins = isObj(m.data) && Array.isArray(m.data.plugins) ? m.data.plugins : [];
    const entry = plugins.find((p) => isObj(p) && p.name === name);
    return entry ? entry : fail(file, "no entry with this plugin's name");
  }
  return fail(candidates[candidates.length - 1], last);
}
