import fs from "node:fs";
import path from "node:path";

// Scoped CC MCP servers -> OC V1 `mcp` config (packages/core/src/v1/config/mcp.ts:
// local {command[], environment?, enabled?} | remote {url, headers?, enabled?}).
// Header and env VALUES are carried in memory only: nothing here logs, and every unknown
// note names keys, never values.

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const clone = (v) => JSON.parse(JSON.stringify(v));
const strList = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string") : []);

// ~/.claude.json `projects` keys: forward slashes, no trailing slash, upper-case drive letter.
// Only the drive letter is case-folded; the rest of the path is compared as CC wrote it.
export function projectKey(dir) {
  let s = String(dir).replace(/\\/g, "/");
  if (s.length > 1) s = s.replace(/\/+$/, "");
  s = s.replace(/^([A-Za-z]):/, (_, d) => `${d.toUpperCase()}:`);
  if (/^[A-Z]:$/.test(s)) s += "/";
  return s;
}

function readJson(file, unknown, where) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e && e.code !== "ENOENT" && e.code !== "ENOTDIR") unknown.push({ where: file, key: where, note: `unreadable: ${e.code}` });
    return undefined;
  }
  try {
    return JSON.parse(text.replace(/^﻿/, ""));
  } catch (e) {
    unknown.push({ where: file, key: where, note: "unparseable JSON, skipped" });
    return undefined;
  }
}

// .mcp.json is { mcpServers: {...} } or the servers map itself.
const serversOf = (data) => (isObj(data) ? (isObj(data.mcpServers) ? data.mcpServers : data) : {});

// Replace ${CLAUDE_PLUGIN_ROOT} in every string value, deep (returns a copy).
function substituteRoot(v, root) {
  if (typeof v === "string") return v.split("${CLAUDE_PLUGIN_ROOT}").join(root);
  if (Array.isArray(v)) return v.map((x) => substituteRoot(x, root));
  if (isObj(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, substituteRoot(x, root)]));
  return v;
}

function pluginServers(p, unknown) {
  const out = {};
  const root = p.installPath;
  const name = p.name || p.key;
  const add = (servers) => {
    for (const [srv, cfg] of Object.entries(servers)) {
      if (isObj(cfg)) out[`plugin:${name}:${srv}`] = substituteRoot(cfg, root);
    }
  };
  add(serversOf(readJson(path.join(root, ".mcp.json"), unknown, `plugin:${name}:.mcp.json`)));
  const manifest = readJson(path.join(root, ".claude-plugin", "plugin.json"), unknown, `plugin:${name}:plugin.json`);
  if (isObj(manifest) && manifest.mcpServers !== undefined) {
    if (isObj(manifest.mcpServers)) add(manifest.mcpServers);
    else {
      for (const rel of [].concat(manifest.mcpServers)) {
        if (typeof rel === "string") add(serversOf(readJson(path.resolve(root, rel), unknown, `plugin:${name}:${rel}`)));
      }
    }
  }
  return out;
}

// collectMcp({ claudeJson, projectDir, plugins, settings?, unknown?, trusted? })
//   -> Record<name, CcServer & { scope: "user" | "project" | "plugin" }>
// Precedence (later wins): plugin < user < project .mcp.json < the ~/.claude.json projects
// entry (CC's "local" scope). Plugin servers carry CC's own name `plugin:<plugin>:<server>`,
// which sanitises to the `plugin_<plugin>_<server>` prefix CC's mcp__ hook matchers use.
// A project .mcp.json server starts only if CC approved it: `enableAllProjectMcpServers`, or
// its name in `enabledMcpjsonServers` (settings or the projects entry); an unapproved one is
// reported in `unknown` (a sink array the caller may pass). `disabledMcpjsonServers` drops a
// .mcp.json server; the projects entry's `disabledMcpServers` drops a server of any scope.
// R47: a project .mcp.json starts only when CC trusts the directory (`trusted`, default false:
// fail closed); an untrusted one is reported per server and never started, approved or not.
export function collectMcp({ claudeJson, projectDir, plugins = [], settings = {}, unknown = [], trusted = false } = {}) {
  const cj = isObj(claudeJson) ? claudeJson : {};
  const st = isObj(settings) ? settings : {};
  const out = {};
  const put = (servers, scope) => {
    for (const [name, cfg] of Object.entries(servers)) if (isObj(cfg)) out[name] = { ...clone(cfg), scope };
  };

  for (const p of Array.isArray(plugins) ? plugins : []) {
    if (!p || !p.installPath || p.exists === false) continue;
    put(pluginServers(p, unknown), "plugin");
  }
  put(isObj(cj.mcpServers) ? cj.mcpServers : {}, "user");

  let entry = {};
  if (projectDir) {
    const want = projectKey(path.resolve(projectDir));
    const hit = isObj(cj.projects) ? Object.keys(cj.projects).find((k) => projectKey(k) === want) : undefined;
    if (hit && isObj(cj.projects[hit])) entry = cj.projects[hit];

    const enabled = new Set([...strList(st.enabledMcpjsonServers), ...strList(entry.enabledMcpjsonServers)]);
    const disabled = new Set([...strList(st.disabledMcpjsonServers), ...strList(entry.disabledMcpjsonServers)]);
    const all = st.enableAllProjectMcpServers === true || entry.enableAllProjectMcpServers === true;
    const file = path.join(projectDir, ".mcp.json");
    const approved = {};
    for (const [name, cfg] of Object.entries(serversOf(readJson(file, unknown, ".mcp.json")))) {
      if (disabled.has(name)) continue;
      if (trusted !== true) {
        unknown.push({ where: file, key: name, note: "project .mcp.json server not started: the project is not trusted in CC" });
        continue;
      }
      if (all || enabled.has(name)) approved[name] = cfg;
      else unknown.push({ where: file, key: name, note: "project .mcp.json server not approved in CC (enabledMcpjsonServers); not started" });
    }
    put(approved, "project");
    put(isObj(entry.mcpServers) ? entry.mcpServers : {}, "project");
  }

  for (const name of strList(entry.disabledMcpServers)) delete out[name];
  return out;
}

const VAR = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g;
function expand(v, env, missing) {
  if (typeof v === "string") {
    return v.replace(VAR, (whole, name, dflt) => {
      const val = env[name];
      if (val !== undefined && val !== "") return val;
      if (dflt !== undefined) return dflt;
      missing.add(name);
      return whole;
    });
  }
  if (Array.isArray(v)) return v.map((x) => expand(x, env, missing));
  if (isObj(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, expand(x, env, missing)]));
  return v;
}

const strMap = (o) => (isObj(o) ? Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v)])) : {});

// Serena (spec 5.5): CC's `--context=claude-code` becomes `--context=agent` under OC.
function serenaOverride(name, command) {
  if (![name, ...command].some((t) => /serena/i.test(String(t)))) return null;
  const out = [...command];
  let hit = false;
  for (let i = 0; i < out.length; i++) {
    if (out[i] === "--context=claude-code") {
      out[i] = "--context=agent";
      hit = true;
    } else if (out[i] === "--context" && out[i + 1] === "claude-code") {
      out[i + 1] = "agent";
      hit = true;
    }
  }
  return hit ? out : null;
}

// toOcMcp(servers, { env? }) -> { mcp: Record<name, OcServer>, unknown: Unknown[] }
//   stdio (or no type) -> { type:"local", command:[command, ...args], environment?, enabled:true }
//   http / sse         -> { type:"remote", url, headers?, enabled:true }
//   CC's ${VAR} / ${VAR:-default} expand from env (default process.env); a missing variable
//   without a default skips the server (CC refuses such a config too).
//   The serena entry is tagged override:"serena-context" when its context flag was rewritten.
export function toOcMcp(servers, { env = process.env } = {}) {
  const mcp = {};
  const unknown = [];
  for (const [name, raw] of Object.entries(isObj(servers) ? servers : {})) {
    if (!isObj(raw)) continue;
    const { scope, ...rest } = raw;
    const missing = new Set();
    const s = expand(rest, env, missing);
    if (missing.size) {
      unknown.push({ where: "mcp", key: name, note: `environment variable(s) not set: ${[...missing].join(", ")}; server not started` });
      continue;
    }
    const type = s.type === undefined ? "stdio" : s.type;
    if (type === "stdio") {
      if (typeof s.command !== "string" || !s.command) {
        unknown.push({ where: "mcp", key: name, note: "stdio server without a command" });
        continue;
      }
      let command = [s.command, ...(Array.isArray(s.args) ? s.args.map(String) : [])];
      const env2 = strMap(s.env);
      const over = serenaOverride(name, command);
      if (over) command = over;
      const o = { type: "local", command };
      if (Object.keys(env2).length) o.environment = env2;
      o.enabled = true;
      if (over) o.override = "serena-context";
      mcp[name] = o;
    } else if (type === "http" || type === "sse") {
      if (typeof s.url !== "string" || !s.url) {
        unknown.push({ where: "mcp", key: name, note: `${type} server without a url` });
        continue;
      }
      const o = { type: "remote", url: s.url };
      const headers = strMap(s.headers);
      if (Object.keys(headers).length) o.headers = headers;
      o.enabled = true;
      mcp[name] = o;
    } else {
      unknown.push({ where: "mcp", key: name, note: `unsupported MCP server type "${String(type).slice(0, 40)}"` });
    }
  }
  return { mcp, unknown };
}
