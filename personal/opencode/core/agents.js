import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ccPaths } from "./paths.js";
import { OC_TO_CC, sanitizeMcpName } from "./toolmap.js";
import { wildcardMatch } from "./wildcard.js";

// CC agent / command markdown -> OC `agent` / `command` config (in memory only: prompts are
// never logged). Names: plugin agents `<plugin>-<name>`; commands `a/b.md` -> `a:b`
// (v1-capabilities.md row 2: `:` is accepted in command names), plugin commands `<plugin>:...`.

const MODELS = {
  sonnet: "anthropic/claude-sonnet-5-5",
  opus: "anthropic/claude-opus-5-5",
  haiku: "anthropic/claude-haiku-5-5",
};
export const COMMAND_SEP = ":";

// CC tool name -> OC tool id: the inverse of OC_TO_CC (apply_patch is an OC-only marker).
const CC_TO_OC = Object.fromEntries(
  Object.entries(OC_TO_CC).filter(([, cc]) => cc !== "apply_patch").map(([oc, cc]) => [cc, oc]),
);
CC_TO_OC.Agent = "task"; // CC's current name for Task

// Returns { value } where value is an OC id; {} for inherit/absent; or { unknown }.
export function mapModel(raw) {
  if (raw === undefined || raw === "" || raw === "inherit") return {};
  if (typeof raw !== "string") return { unknown: "model is not a string" };
  if (Object.hasOwn(MODELS, raw)) return { value: MODELS[raw] };
  if (/^claude-[A-Za-z0-9._-]+$/.test(raw)) return { value: `anthropic/${raw}` };
  return { unknown: `model ${JSON.stringify(raw)} has no OC mapping` };
}

// CC tool name -> OC tool id, or null.
export function mapTool(name) {
  if (Object.hasOwn(CC_TO_OC, name)) return CC_TO_OC[name];
  const m = /^mcp__(.+?)__(.+)$/.exec(name);
  if (m) return `${sanitizeMcpName(m[1])}_${m[2] === "*" ? "*" : sanitizeMcpName(m[2])}`;
  return null;
}

function unquote(v) {
  const t = v.trim();
  if (t.length >= 2 && ((t[0] === '"' && t.at(-1) === '"') || (t[0] === "'" && t.at(-1) === "'"))) {
    return t[0] === '"' ? t.slice(1, -1).replace(/\\(["\\])/g, "$1") : t.slice(1, -1).replace(/''/g, "'");
  }
  return t;
}

// YAML inline comment on a value (R51 m-2): `#` after whitespace (or at the start) ends a plain
// value; after a quoted value only whitespace and a comment may follow. A `#` inside quotes stays.
export function stripComment(v) {
  const t = v.trim();
  const q = t[0];
  if (q === '"' || q === "'") {
    let i = 1;
    for (; i < t.length; i++) {
      if (q === '"' && t[i] === "\\") i++;
      else if (t[i] === q) {
        if (q === "'" && t[i + 1] === "'") i++;
        else break;
      }
    }
    if (i < t.length && /^(\s+#.*)?\s*$/.test(t.slice(i + 1))) return t.slice(0, i + 1);
    return t;
  }
  return t.replace(/(^|\s)#.*$/, "").trimEnd();
}

// Minimal flat frontmatter parser. Handles `key: value` (a key may be quoted, R51 m-2), inline
// `# comments` after a value, quoted values, `|`/`>` block scalars,
// indented plain continuation lines, `- item` lists and inline `[a, b]`. Value is a string or a
// string[] (lists). Anything else is reported in `problems`.
export function parseFrontmatter(text) {
  const src = String(text).replace(/^\uFEFF/, "");
  const lines = src.split(/\r?\n/);
  if (lines[0] !== "---") return { fm: {}, body: src, problems: [] };
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === "---") {
      end = i;
      break;
    }
  }
  if (end < 0) return { fm: {}, body: src, problems: ["frontmatter is not terminated"] };
  const nl = src.includes("\r\n") ? "\r\n" : "\n";
  const body = lines.slice(end + 1).join(nl);
  const fm = {};
  const problems = [];
  for (let i = 1; i < end; i++) {
    const line = lines[i];
    if (!line.trim() || line.trimStart().startsWith("#")) continue;
    const m = /^(?:"([^"\\]+)"|'([^']+)'|([A-Za-z0-9_-]+))\s*:(?:\s+(.*)|\s*)$/.exec(line);
    if (!m) {
      problems.push(`unparseable frontmatter line ${i}`);
      continue;
    }
    const key = m[1] ?? m[2] ?? m[3];
    const val = stripComment(m[4] ?? "");
    const cont = [];
    while (
      i + 1 < end &&
      (/^\s+\S/.test(lines[i + 1]) ||
        (/^\s*$/.test(lines[i + 1]) && i + 2 < end && /^\s+\S/.test(lines[i + 2])) ||
        (val === "" && /^- /.test(lines[i + 1])))
    ) {
      cont.push(lines[++i]);
    }
    if (/^[|>][+-]?$/.test(val)) {
      const parts = cont.map((l) => l.trim());
      fm[key] = (val[0] === "|" ? parts.join("\n") : parts.join(" ").replace(/\s+/g, " ")).trim();
    } else if (val === "" && cont.length && cont.every((l) => !l.trim() || /^\s*- /.test(l))) {
      fm[key] = cont.filter((l) => l.trim()).map((l) => unquote(l.trim().slice(2)));
    } else if (val.startsWith("[") && val.endsWith("]") && !cont.length) {
      fm[key] = val.slice(1, -1).split(",").map(unquote).filter(Boolean);
    } else if (/^[[{|>&*!]/.test(val)) {
      problems.push(`unsupported value syntax for ${key}`);
    } else {
      fm[key] = unquote([val, ...cont.map((l) => l.trim())].filter((s) => s !== "").join(" "));
    }
  }
  return { fm, body, problems };
}

const readText = (f) => {
  try {
    return fs.readFileSync(f, "utf8");
  } catch {
    return null;
  }
};
const isDir = (p) => {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
};

function listMd(dir, recursive) {
  const out = [];
  const seen = new Set();
  const walk = (d, rel, depth) => {
    let real;
    try {
      real = fs.realpathSync(d);
    } catch {
      return;
    }
    if (seen.has(real) || depth > 6) return;
    seen.add(real);
    let ents;
    try {
      ents = fs.readdirSync(d);
    } catch {
      return;
    }
    for (const e of ents.sort()) {
      const p = path.join(d, e);
      let st;
      try {
        st = fs.statSync(p);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        if (recursive) walk(p, [...rel, e], depth + 1);
      } else if (st.isFile() && e.endsWith(".md")) out.push({ file: p, rel: [...rel, e.slice(0, -3)] });
    }
  };
  walk(dir, [], 0);
  return out;
}

// OC's native agent names; a CC agent of the same name would merge into (and break) the built-in.
export const OC_NATIVE_AGENTS = ["build", "plan", "general", "explore", "compaction", "title", "summary"];
const AGENT_KEYS = new Set(["name", "description", "color", "model", "tools", "disallowedTools"]);
const COMMAND_KEYS = new Set(["name", "description", "color", "model", "allowed-tools", "argument-hint"]);

// OC permission key for an OC tool id: write / apply_patch are gated by the `edit` key.
const permKey = (oc) => (oc === "write" || oc === "apply_patch" ? "edit" : oc);
const DEFAULT_READ = { "*": "allow", "*.env": "ask", "*.env.*": "ask", "*.env.example": "allow" };
const clone = (v) => (v && typeof v === "object" ? { ...v } : v);

// CC tool entry -> OC permission key (or null). `mcp__srv` / `mcp__srv__*` -> `<srv>_*`.
function toPermKey(name) {
  const oc = mapTool(name);
  if (oc) return permKey(oc);
  const m = /^mcp__([^_].*?)(?:__\*)?$/.exec(name);
  if (m && !m[1].includes("__")) return `${sanitizeMcpName(m[1])}_*`;
  return null;
}

// R36: OC ignores `tools` set through a config hook, so a CC allowlist becomes a per-agent
// `permission`: "*":"deny" FIRST, then each allowed key with the user's effective rule.
function agentPermission(fm, userPermission, where, key) {
  const unknown = [];
  const up = userPermission || {};
  // N2 (R38): the user's effective rule for an allowed key is the LAST user key whose pattern
  // wildcard-matches it (OC last-match-wins), so `<server>_*` denies and a baseline "*":"ask"
  // carry into the agent; an exact key wins only by being last.
  const rule = (k, dflt) => {
    const hit = Object.keys(up).filter((p) => wildcardMatch(k, p)).at(-1);
    return clone(hit !== undefined ? up[hit] : dflt);
  };
  const list = (v) => (Array.isArray(v) ? v : String(v).split(",")).map((s) => s.trim()).filter(Boolean);
  const note = (n) => unknown.push({ where, key, note: n });
  const sharedEdit = (names) => {
    const has = (n) => names.includes(n);
    if ((has("Edit") || has("Write") || has("MultiEdit") || has("NotebookEdit")) && has("Edit") !== has("Write")) {
      note("OC gates edit and write with one `edit` permission; CC Edit/Write cannot be separated");
    }
  };
  let perm;
  if (fm.tools !== undefined) {
    const names = list(fm.tools);
    perm = { "*": "deny" };
    if (names.length === 0) note("tools list is empty: agent gets no tools");
    sharedEdit(names);
    let any = false;
    let anyMcp = false;
    for (const n of names) {
      const k = toPermKey(n);
      if (!k) {
        note(`tool ${n} has no OC tool`);
        continue;
      }
      any = true;
      if (n.startsWith("mcp__")) anyMcp = true;
      perm[k] = rule(k, k === "read" ? DEFAULT_READ : "allow");
    }
    if (any) {
      perm.external_directory = rule("external_directory", { "*": "ask" });
      perm.invalid = "allow";
      // N1 (R38): under Code Mode MCP tools are reachable only through `execute`; OC filters its
      // catalog by this ruleset (code-mode.ts:207-212) and asks per MCP tool (:147).
      if (anyMcp) perm.execute = rule("execute", "allow");
    }
  }
  if (fm.disallowedTools !== undefined) {
    const names = list(fm.disallowedTools);
    sharedEdit(names);
    perm = perm || {};
    for (const n of names) {
      const k = toPermKey(n);
      if (k) perm[k] = "deny";
      else note(`disallowed tool ${n} has no OC tool`);
    }
  }
  return { perm, unknown };
}

function extraKeys(fm, allowed, where, key, what) {
  return Object.keys(fm)
    .filter((k) => !allowed.has(k))
    .map((k) => ({ where, key, note: `${k} has no OC ${what} equivalent` }));
}

function translateAgent(file, fallbackName, prefix, userPermission) {
  const text = readText(file);
  if (text === null) return null;
  const { fm, body, problems } = parseFrontmatter(text);
  const base = typeof fm.name === "string" && fm.name ? fm.name : fallbackName;
  const name = prefix ? `${prefix}-${base}` : base;
  const key = `agent:${name}`;
  const unknown = [...problems.map((note) => ({ where: file, key, note })), ...extraKeys(fm, AGENT_KEYS, file, key, "agent")];
  const agent = { description: typeof fm.description === "string" ? fm.description : "", mode: "subagent", prompt: body };
  const model = mapModel(fm.model);
  if (model.value) agent.model = model.value;
  if (model.unknown) unknown.push({ where: file, key, note: model.unknown });
  const p = agentPermission(fm, userPermission, file, key);
  if (p.perm) agent.permission = p.perm;
  unknown.push(...p.unknown);
  return { name, agent, unknown };
}

// R37: translation-time substitution and arg remap. CC `$N` / `$ARGUMENTS[N]` are 0-based, OC's `$N` 1-based.
function rewriteTemplate(body, { pluginRoot, projectDir }, where, key) {
  const unknown = [];
  let quoted = false;
  let escaped = false;
  let out = body.replace(/\$\{(CLAUDE_[A-Za-z0-9_]*)\}/g, (m, v) => {
    if (v === "CLAUDE_PLUGIN_ROOT" && pluginRoot) return pluginRoot;
    if (v === "CLAUDE_PROJECT_DIR" && projectDir) return projectDir;
    unknown.push({ where, key, note: `${m} has no OC equivalent` });
    return m;
  });
  out = out
    .split("\n")
    .map((line) =>
      line.replace(/(\\)?\$(?:ARGUMENTS\[(\d+)\]|(\d+))/g, (m, bs, a, n, off) => {
        if (bs) {
          escaped = true;
          return m;
        }
        if ((line.slice(0, off).match(/'/g) || []).length % 2 === 1) quoted = true;
        return `$${Number(a ?? n) + 1}`;
      }),
    )
    .join("\n");
  if (escaped) unknown.push({ where, key, note: "escaped \\$N is literal in CC; OC has no escape and will substitute it" });
  if (quoted) unknown.push({ where, key, note: "$N inside single quotes (shell text): CC leaves an unfilled index literal, OC blanks it" });
  return { out, unknown };
}

function translateCommand(file, rel, prefix, ctx) {
  const text = readText(file);
  if (text === null) return null;
  const { fm, body, problems } = parseFrontmatter(text);
  const name = (prefix ? [prefix, ...rel] : rel).join(COMMAND_SEP);
  const key = `command:${name}`;
  const unknown = [...problems.map((note) => ({ where: file, key, note })), ...extraKeys(fm, COMMAND_KEYS, file, key, "command")];
  const rw = rewriteTemplate(body, ctx, file, key);
  unknown.push(...rw.unknown);
  const command = { template: rw.out };
  if (typeof fm.description === "string" && fm.description) command.description = fm.description;
  const model = mapModel(fm.model);
  if (model.value) command.model = model.value;
  if (model.unknown) unknown.push({ where: file, key, note: model.unknown });
  if (fm["allowed-tools"] !== undefined) {
    unknown.push({ where: file, key, note: "allowed-tools has no OC command equivalent" });
  }
  return { name, command, unknown };
}

// Precedence (later wins): plugins < user < project, as in CC.
export function collectAgents({ home = os.homedir(), projectDir, plugins = [], userPermission } = {}) {
  const agent = {};
  const command = {};
  const unknown = [];
  const hasProject = projectDir && path.resolve(projectDir) !== path.resolve(home);
  const sources = [];
  for (const p of plugins) {
    if (!p || p.exists === false || !p.installPath) continue;
    sources.push({ agents: path.join(p.installPath, "agents"), commands: path.join(p.installPath, "commands"), prefix: p.name, root: p.installPath });
  }
  sources.push({ agents: ccPaths(home).agentsDir, commands: ccPaths(home).commandsDir });
  if (hasProject) {
    sources.push({ agents: path.join(projectDir, ".claude", "agents"), commands: path.join(projectDir, ".claude", "commands") });
  }

  for (const s of sources) {
    if (isDir(s.agents)) {
      for (const { file, rel } of listMd(s.agents, false)) {
        const r = translateAgent(file, rel[0], s.prefix, userPermission);
        if (!r) continue;
        if (OC_NATIVE_AGENTS.includes(r.name)) {
          unknown.push({ where: file, key: `agent:${r.name}`, note: "name collides with an OC built-in agent: skipped" });
          continue;
        }
        agent[r.name] = r.agent;
        unknown.push(...r.unknown);
      }
    }
    if (isDir(s.commands)) {
      for (const { file, rel } of listMd(s.commands, true)) {
        const r = translateCommand(file, rel, s.prefix, { pluginRoot: s.root, projectDir });
        if (!r) continue;
        command[r.name] = r.command;
        unknown.push(...r.unknown);
      }
    }
  }
  return { agent, command, unknown };
}
