import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pluginHookSources } from "./pluginhooks.js";
import { OC_TO_CC, OC_INTERNAL } from "./toolmap.js";

const require = createRequire(import.meta.url);
// Keys that genuinely do not affect OC behaviour, each with a reason. Only
// ever add to this file for a key that changes nothing; behaviour belongs in HANDLED
// (translated) or NOT_TRANSLATED (a decided gap).
export const IGNORED = require("./ignored.json");
// Keys that DO affect behaviour but are not translated to OC (R16). Each live hit is
// reported as an Unknown so the user is told once. Task 9's `known` includes these.
export const NOT_TRANSLATED = require("./not-translated.json");

// What the adapter has a translator for. Anything outside HANDLED, IGNORED and
// NOT_TRANSLATED is an "unknown": the drift alarm.
export const HANDLED = {
  settings: ["env", "permissions", "hooks", "enabledPlugins"],
  // env keys are all CC-process flags today and live in IGNORED.env / NOT_TRANSLATED.env
  env: [],
  hookEvents: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "PreCompact"],
  hookGroupFields: ["matcher", "hooks", "origin"],
  hookFields: [
    "type", "command", "args", "timeout", "shell", "async", "origin",
    "asyncRewake", "rewakeMessage", "rewakeSummary", "if", "onFailure", "statusMessage",
  ],
  hookTypes: ["command"],
  permissionKinds: ["allow", "ask", "deny"],
  pluginManifest: ["name", "version", "skills", "agents", "commands", "hooks", "mcpServers"],
  // bin: Task 10 prepends each enabled plugin's bin/ to PATH through shell.env (R17).
  pluginEntries: [".claude-plugin", "skills", "agents", "commands", "hooks", ".mcp.json", "bin"],
  // A plugin's own OC integration, composed by v1/plugin.js for this plugin only (R18).
  pluginEntriesByPlugin: ["superpowers:.opencode", "superpowers:index.js"],
  pluginHooksFile: ["hooks"],
  claudeJson: ["mcpServers", "projects"],
  // hasTrustDialogAccepted gates the project scope (R47; settings.js ccTrusted), so it is translated.
  claudeJsonProject: ["mcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers", "disabledMcpServers", "hasTrustDialogAccepted"],
  mcpServerFields: ["type", "url", "headers", "command", "args", "env"],
  // The tool-map keys (R1): every OC tool id the adapter can translate. MCP ids are matched by prefix.
  ocTools: [...Object.keys(OC_TO_CC), ...OC_INTERNAL],
};

// Project-entry keys that are ignorable only while empty; a non-empty value is behaviour.
const IGNORED_WHILE_EMPTY = new Set(["allowedTools", "mcpContextUris"]);

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const sanitize = (s) => String(s).replace(/[^a-zA-Z0-9_-]/g, "_");
const isEmpty = (v) => v === undefined || v === null || (Array.isArray(v) ? v.length === 0 : isObj(v) ? Object.keys(v).length === 0 : v === "" || v === false);

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
  } catch {
    return undefined; // missing or unparseable: plugins.js/settings.js report those
  }
}

// Notes carry key NAMES only, never values: env, headers and .claude.json hold secrets.
export function enumerate({ sources = [], plugins = [], claudeJson, ocTools = [], mcpServers = [], projectDir } = {}) {
  const out = [];
  const seen = new Set();
  const report = (where, key, note) => {
    const id = `${where}\u0000${key}`;
    if (seen.has(id)) return;
    seen.add(id);
    out.push({ where, key, note });
  };
  // Silent when handled or ignored; a NOT_TRANSLATED hit is reported with its reason.
  const check = (category, key, where, label, unknownNote) => {
    if (HANDLED[category]?.includes(key) || (IGNORED[category] && Object.hasOwn(IGNORED[category], key))) return;
    if (NOT_TRANSLATED[category] && Object.hasOwn(NOT_TRANSLATED[category], key)) {
      report(where, label, `affects behaviour; not translated to OC: ${NOT_TRANSLATED[category][key]}`);
      return;
    }
    report(where, label, unknownNote);
  };

  // hooksObj: { <Event>: [ { matcher, hooks: [ {type, command, ...} ] } ] }
  const walkHooks = (where, hooksObj) => {
    if (!isObj(hooksObj)) return;
    for (const [ev, groups] of Object.entries(hooksObj)) {
      if (!HANDLED.hookEvents.includes(ev)) report(where, `hooks.event.${ev}`, "unknown hook event");
      for (const g of Array.isArray(groups) ? groups : []) {
        if (!isObj(g)) continue;
        for (const k of Object.keys(g)) {
          if (!HANDLED.hookGroupFields.includes(k)) report(where, `hooks.group.${k}`, "unknown hook group field");
        }
        for (const h of Array.isArray(g.hooks) ? g.hooks : []) {
          if (!isObj(h)) continue;
          for (const k of Object.keys(h)) {
            if (!HANDLED.hookFields.includes(k)) report(where, `hooks.field.${k}`, "unknown hook field");
          }
          if (h.type !== undefined && !HANDLED.hookTypes.includes(h.type)) {
            report(where, `hooks.type=${String(h.type).slice(0, 40)}`, "unknown hook handler type");
          }
        }
      }
    }
  };
  // A hooks.json file: { description?, hooks: {...} }
  const walkHooksFile = (where, data) => {
    if (!isObj(data)) return;
    for (const k of Object.keys(data)) check("pluginHooksFile", k, where, `hooks.json:${k}`, "unknown hooks.json top-level key");
    walkHooks(where, data.hooks);
  };

  const walkServers = (where, servers, prefix) => {
    if (!isObj(servers)) return;
    for (const s of Object.values(servers)) {
      if (!isObj(s)) continue;
      for (const k of Object.keys(s)) {
        if (!HANDLED.mcpServerFields.includes(k)) report(where, `${prefix}.${k}`, "unknown MCP server field");
      }
    }
  };
  // .mcp.json is either { mcpServers: {...} } or the servers map itself.
  const walkMcpFile = (where, data, prefix) => {
    if (!isObj(data)) return;
    walkServers(where, isObj(data.mcpServers) ? data.mcpServers : data, prefix);
  };

  for (const src of sources) {
    const data = isObj(src?.data) ? src.data : {};
    const where = src.path || `settings:${src.scope}`;
    for (const k of Object.keys(data)) check("settings", k, where, k, "unknown top-level settings key");
    if (isObj(data.env)) {
      for (const k of Object.keys(data.env)) check("env", k, where, `env.${k}`, "unknown env key");
    }
    if (isObj(data.permissions)) {
      for (const k of Object.keys(data.permissions)) {
        if (!HANDLED.permissionKinds.includes(k)) report(where, `permissions.${k}`, "unknown permission kind");
      }
    }
    walkHooks(where, data.hooks);
  }

  for (const p of plugins) {
    if (!p || !p.installPath || p.exists === false) continue;
    const name = p.name || p.key;
    const label = `plugin:${name}`;
    let entries = [];
    try {
      entries = fs.readdirSync(p.installPath);
    } catch {
      continue; // already reported as plugin-missing by plugins.js
    }
    for (const e of entries) {
      const scoped = `${name}:${e}`;
      if (HANDLED.pluginEntriesByPlugin.includes(scoped) || Object.hasOwn(IGNORED.pluginEntriesByPlugin, scoped)) continue;
      check("pluginEntries", e, label, e, "unknown plugin directory entry");
    }
    const m = readJson(path.join(p.installPath, ".claude-plugin", "plugin.json"));
    if (isObj(m)) {
      for (const k of Object.keys(m)) check("pluginManifest", k, label, `plugin.json:${k}`, "unknown plugin manifest key");
    }
    // Hooks: shared reader (pluginhooks.js), the same one collectHooks uses.
    for (const src of pluginHookSources(p.installPath)) {
      if (src.kind === "file") walkHooksFile(label, src.data);
      else walkHooks(label, src.data);
    }
    // MCP: .mcp.json, plus a manifest `mcpServers` (inline object or path(s)).
    walkMcpFile(label, readJson(path.join(p.installPath, ".mcp.json")), "mcp.*");
    if (isObj(m) && m.mcpServers !== undefined) {
      if (isObj(m.mcpServers)) walkServers(label, m.mcpServers, "mcp.*");
      else {
        for (const rel of [].concat(m.mcpServers)) {
          if (typeof rel === "string") walkMcpFile(label, readJson(path.resolve(p.installPath, rel)), "mcp.*");
        }
      }
    }
  }

  if (projectDir) walkMcpFile("project:.mcp.json", readJson(path.join(projectDir, ".mcp.json")), "mcp.*");

  if (isObj(claudeJson)) {
    const where = "~/.claude.json";
    for (const k of Object.keys(claudeJson)) check("claudeJson", k, where, k, "unknown .claude.json top-level key");
    walkServers(where, claudeJson.mcpServers, "mcpServers.*");
    if (isObj(claudeJson.projects)) {
      for (const proj of Object.values(claudeJson.projects)) {
        if (!isObj(proj)) continue;
        for (const [k, v] of Object.entries(proj)) {
          if (HANDLED.claudeJsonProject.includes(k)) continue;
          if (IGNORED_WHILE_EMPTY.has(k)) {
            if (!isEmpty(v)) report(where, `projects.*.${k}`, "non-empty; this field is ignorable only while empty");
            continue;
          }
          check("claudeJsonProject", k, where, `projects.*.${k}`, "unknown project-entry key");
        }
        walkServers(where, proj.mcpServers, "projects.*.mcpServers.*");
      }
    }
  }

  const prefixes = mcpServers.map((s) => `${sanitize(s)}_`);
  for (const t of ocTools) {
    if (HANDLED.ocTools.includes(t)) continue;
    if (Object.hasOwn(NOT_TRANSLATED.ocTools || {}, t)) {
      report("opencode", t, `affects behaviour; not translated to OC: ${NOT_TRANSLATED.ocTools[t]}`);
      continue;
    }
    if (prefixes.some((p) => p.length > 1 && t.startsWith(p))) continue;
    report("opencode", t, "OC tool with no tool-map row");
  }
  return out;
}
