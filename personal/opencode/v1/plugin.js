import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { buildInventory, permissionAndAgents, PROBLEM_LABELS } from "../core/inventory.js";
import { toOcPermission } from "../core/permissions.js";
import { stateStore } from "../core/state.js";
import { ocPaths } from "../core/paths.js";
import { log as coreLog } from "../core/log.js";
import { buildInput, interpret } from "../core/protocol.js";
import { runHook as coreRunHook, timeoutFor } from "../core/runner.js";
import { matches, ifAllows, tokenize } from "../core/hooks.js";
import { wildcardMatch } from "../core/wildcard.js";
import { toCcCalls, toCcResponse, applyUpdatedInput, unmappedUpdateKeys, undroppableKeys, UPDATE_ARG_MAPS, sanitizeMcpName } from "../core/toolmap.js";
import { ccVersion as coreCcVersion, fetchChangelog as coreFetchChangelog, parseChangelog, hookDigest, knownSet, semver, cmpVer } from "../core/releasenotes.js";

// OC V1 front-end (docs/v1-capabilities.md holds the measured hook behaviour this relies on).
// Every hook catches its own errors, logs them and counts them in the state file's failure counter,
// so they reach the next parity line. The only throws are deliberate blocks in
// tool.execute.before: a CC hook's deny/ask/continue:false, R32's unrepresentable apply_patch,
// (R48) an updatedInput OC cannot apply, and (Minor 1) an internal error while a CC PreToolUse
// entry may apply. Each fails closed.

const RUNS = new Set(["bridge", "degraded"]); // skip / cc-only never run
const SESSION_END_BUDGET_MS = 1500; // CC's SessionEnd hooks share a 1.5 s budget (hooks docs)
// D4: past a hook's own timeout, the runner's tree kill (R27: snapshot steps capped at 3 s, then
// taskkill capped at 3 s) still needs time to settle the run; dispose waits this much longer.
const EXIT_GRACE_MS = 10000;

// Built-in agents whose own rules deny edit (OC v1.19.0 agent/agent.ts:156-249: plan's edit map;
// explore, compaction, title, summary via "*":"deny"). R34 re-asserts the deny per agent, which OC
// merges AFTER the user ruleset (agent.ts:293), so a CC Edit/Write allow cannot loosen them.
export const READ_ONLY_AGENTS = ["plan", "explore", "compaction", "title", "summary"];
// Minor 2: when the CC inventory throws, nothing about CC's rules is known, so the baseline gets a
// fail-closed overlay: these CC-style asks, layered by toOcPermission like any CC rule (a stricter
// baseline value survives; a looser one is tightened to ask). They are the tools CC 2.1.300 asks
// for by default (R49), plus Skill, since which skills CC would prompt for is unknown. Not Task: CC
// runs Agent without a prompt. Seen-key text: keep it stable.
export const INVENTORY_FAILED = "CC inventory failed (see cc-parity.log): no CC hooks run, and bash, edit, webfetch, websearch, skill and every MCP server ask";
const FAILSAFE_ASKS = ["Bash", "Edit", "WebFetch", "WebSearch", "Skill"];
// OC tools whose args toolmap.applyUpdatedInput can rewrite from a CC updatedInput.
const UPDATABLE = new Set(Object.keys(UPDATE_ARG_MAPS));
// R48 (b): OC v1.19.0 built-ins whose own rules start "*":"deny" (agent.ts explore :201,
// compaction :228, title :244, summary :259), with the keys their built-in rules ALLOW, which are
// left alone (an R45 ask may make them stricter, never looser).
export const DENY_ALL_AGENTS = { explore: ["webfetch", "websearch"], compaction: [], title: [], summary: [] };
// The user-level keys R45/R49 defaults add at top level (besides edit, which R34 covers, and the
// MCP servers): webfetch, websearch, skill (R49 per-skill asks), and task, which only a CC Task or
// Agent rule now emits.
const R45_KEYS = ["webfetch", "websearch", "task", "skill"];
// Other built-in denies (agent.ts) that a user-level key the adapter emits would loosen: plan's
// task.general (a CC Task/Agent rule) and general's todowrite (a CC TodoWrite allow).
const OTHER_BUILTIN_DENIES = { plan: { task: { general: "deny" } }, general: { todowrite: "deny" } };

// R42: the compact parity line.
export const LINE_MAX = 500;
export const GROUP_SEP = " | ";
// [kind, singular label, plural label, max name length, keep the tail when truncating], in
// delivery order. Unknown names keep their tail: "command:commit-commands:clean_gone" and
// "...:commit" differ at the end, not the start.
const KINDS = [
  ["notTranslated", "not translated", "not translated", 32, false],
  ["unknown", "unknown", "unknown", 32, true],
  ["bridged", "hook bridged unreviewed", "hooks bridged unreviewed", 40, false],
  ["degraded", "hook degraded", "hooks degraded", 40, false],
  ["failure", "hook failure", "hook failures", 40, false],
  ["problem", "problem", "problems", 40, false],
  ["kind3", "CC changelog digest", "CC changelog digests", 90, false],
  ["ocVersion", "OC version change", "OC version changes", 40, false],
  ["probe", "OC arg drift", "OC arg drifts", 32, false],
];
// A name never contains GROUP_SEP: spaces around "|" are removed and newlines flattened. Truncated
// names carry "..." on the cut side.
export function shortName(s, max = 32, tail = false) {
  const t = String(s ?? "").replace(/[\r\n]+/g, " ").replace(/\s*\|\s*/g, "|").trim();
  if (t.length <= max) return t;
  return tail ? `...${t.slice(t.length - (max - 3))}` : `${t.slice(0, max - 3)}...`;
}

// `[<plugin>:]<basename>@<event>` (R42): the script a hook runs, never its id. The command is split
// quote-aware (core/hooks.js tokenize), so a quoted path with a space stays one token. Leading
// VAR=value assignments are skipped. When the first token is an interpreter, the name is the first
// later token that is neither a flag nor a subcommand (a `-File` value is taken as the script);
// otherwise it is the first token. Plugin hooks get their plugin name, since a script called `hook`
// identifies nothing.
const INTERPRETERS = new Set(["bash", "sh", "zsh", "node", "bun", "deno", "python", "python3", "py", "pwsh", "powershell", "cmd", "uv", "uvx", "npx", "bunx", "env", "exec", "run"]);
const unquote = (t) => String(t ?? "").replace(/["']/g, "");
const baseOf = (t) => unquote(t).split(/[\\/]/).filter(Boolean).pop() ?? "";
const isInterp = (t) => INTERPRETERS.has(baseOf(t).toLowerCase().replace(/\.exe$/, ""));
const isFlag = (t) => unquote(t).startsWith("-") || /^\/[a-z]$/i.test(unquote(t)); // -x, --x, cmd's /c
export function hookName(h) {
  const toks = Array.isArray(h?.args) ? [String(h.command ?? ""), ...h.args.map(String)] : tokenize(String(h?.command ?? "")).toks.map((x) => x.t);
  let i = 0;
  while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) i++;
  let pick = toks[i];
  if (pick !== undefined && isInterp(pick)) {
    const rest = toks.slice(i + 1);
    const file = rest.findIndex((t) => /^-file$/i.test(unquote(t)));
    pick = (file >= 0 ? rest[file + 1] : undefined) ?? rest.find((t) => !isFlag(t) && !isInterp(t)) ?? pick;
  }
  const plugin = /^plugin:([^@]+)/.exec(String(h?.origin ?? ""))?.[1];
  return `${plugin ? `${plugin}:` : ""}${baseOf(pick) || "hook"}@${h?.event}`;
}

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const dedupe = (a) => [...new Set(a)];
const withoutOverride = ({ override: _drop, ...rest }) => rest;
const isDir = (p) => {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
};

// A part id in OC's format (packages/opencode/src/id/id.ts create("prt","ascending")): "prt_" + the
// low 48 bits of ms*4096+counter as 12 hex + 14 base62. A pushed part needs its own id (row 6).
const B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
let lastMs = 0;
let ctr = 0;
export function newPartId() {
  const now = Date.now();
  if (now !== lastMs) {
    lastMs = now;
    ctr = 0;
  }
  ctr++;
  const hex = ((BigInt(now) * 0x1000n + BigInt(ctr)) & 0xffffffffffffn).toString(16).padStart(12, "0");
  let r = "";
  for (const b of crypto.randomBytes(14)) r += B62[b % 62];
  return `prt_${hex}${r}`;
}

// R10: the OC version from the running binary, once per process.
let ocVersionCache;
function defaultOcVersion() {
  if (ocVersionCache === undefined) {
    try {
      const r = spawnSync(process.execPath, ["--version"], { encoding: "utf8", timeout: 5000, windowsHide: true });
      ocVersionCache = semver(r?.stdout);
    } catch {
      ocVersionCache = null;
    }
  }
  return ocVersionCache;
}

// The superpowers 7.0.0 OC adapter (.opencode/plugins/superpowers.js), loaded from the install
// path installed_plugins.json names for the enabled plugin (context.md: never sort cache dirs).
// Not enabled in CC -> nothing to compose and no problem. Enabled but unloadable -> a problem.
export async function loadSuperpowers({ plugins = [], ctx } = {}) {
  const sp = plugins.find((p) => p?.name === "superpowers");
  if (!sp) return { hooks: null };
  const problem = `superpowers ${sp.version ?? "?"} OC adapter unavailable (see cc-parity.log)`;
  if (!sp.exists || !sp.installPath) return { problem, detail: "plugin installPath does not exist" };
  const file = path.join(sp.installPath, ".opencode", "plugins", "superpowers.js");
  if (!fs.existsSync(file)) return { problem, detail: `${file} not found` };
  try {
    const mod = await import(pathToFileURL(file).href);
    const factory = typeof mod.SuperpowersPlugin === "function" ? mod.SuperpowersPlugin : mod.default?.server;
    if (typeof factory !== "function") return { problem, detail: "no V1 server export" };
    const hooks = await factory(ctx ?? {});
    return isObj(hooks) ? { hooks } : { problem, detail: "factory returned no hooks object" };
  } catch (e) {
    return { problem, detail: String(e?.message ?? e) };
  }
}

// Runs fn off the init path. A rejection goes to onError (the caller logs and counts it) and
// resolves null, so awaiting it never throws.
const later = (fn, onError) =>
  new Promise((resolve) => {
    setTimeout(() => {
      Promise.resolve()
        .then(fn)
        .then(resolve, (e) => {
          try {
            onError?.(e);
          } catch {
            // the error path must not throw
          }
          resolve(null);
        });
    }, 0);
  });

function failMsg(r) {
  if (r?.timedOut) return "timeout";
  if (r?.spawnError) return `spawn error: ${String(r.spawnError).slice(0, 80)}`;
  const err = String(r?.stderr ?? "").trim().split(/\r?\n/)[0].slice(0, 80);
  return `exit ${r?.status}${err ? `: ${err}` : ""}`;
}

class Block extends Error {}

export async function createV1(ctx = {}, deps = {}) {
  const env = deps.env ?? process.env;
  const home = deps.home ?? os.homedir();
  // One path computation for both the file written and the path the parity line shows.
  const logFile = ocPaths(env).logFile;
  // A throwing log must never turn a deliberate block into a swallowed error, or break init.
  // Returns false when the line was not written (a sink returning false, or throwing).
  const rawLog = deps.log ?? ((m) => coreLog(m, logFile));
  const log = (m) => {
    try {
      return rawLog(m) !== false;
    } catch {
      return false;
    }
  };
  const runHook = deps.runHook ?? coreRunHook;
  const partId = deps.partId ?? newPartId;
  const flushMs = deps.flushMs ?? 1000;
  const exitGraceMs = deps.exitGraceMs ?? EXIT_GRACE_MS;
  const projectDir = ctx?.directory ?? ctx?.worktree ?? process.cwd();
  const worktree = ctx?.worktree ?? projectDir;
  const client = ctx?.client;
  const state = stateStore(deps.stateFile ?? ocPaths(env).stateFile);

  let timer = null;
  const flushNow = () => {
    if (timer) clearTimeout(timer);
    timer = null;
    return state.flush();
  };
  const scheduleFlush = () => {
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      state.flush();
    }, flushMs);
    timer.unref?.();
  };
  // Every non-block error: logged, and counted so it surfaces in the next parity line.
  const fail = (where, e) => {
    const m = String(e?.message ?? e).slice(0, 200);
    try {
      log(`${where}: ${m}`);
      state.failures.add(`adapter:${where}`, m);
      scheduleFlush();
    } catch {
      // never throw from the error path
    }
  };

  // ---- Inventory (previous session's observations; selfprobe.js explains the lag) ----
  let inv;
  try {
    inv = (deps.buildInventory ?? buildInventory)({ home, projectDir, worktree, env, ocTools: state.observed.tools.list(), observedArgs: state.observed.args.all() });
  } catch (e) {
    fail("inventory", e);
    // Minor 2: no CC hooks run, and the config hook applies FAILSAFE_ASKS over the baseline.
    inv = { failed: true, merged: {}, plugins: [], hooks: [], degraded: [], permission: {}, mcp: {}, agent: {}, command: {}, skillPaths: [], instructions: [], unknown: [], problems: [INVENTORY_FAILED], probeMismatches: [] };
  }
  const unknownKeys = new Set(inv.unknown.map((u) => `${u.where}\u0000${u.key}\u0000${u.note}`));
  const addUnknowns = (list) => {
    for (const u of list) {
      const k = `${u.where}\u0000${u.key}\u0000${u.note}`;
      if (!unknownKeys.has(k)) {
        unknownKeys.add(k);
        inv.unknown.push(u);
      }
    }
  };
  const settingsEnv = Object.fromEntries(Object.entries(isObj(inv.merged?.env) ? inv.merged.env : {}).map(([k, v]) => [k, String(v)]));

  // ---- superpowers composition ----
  let sp = { hooks: null };
  try {
    sp = await (deps.loadSuperpowers ?? loadSuperpowers)({ plugins: inv.plugins, ctx });
  } catch (e) {
    sp = { hooks: null, problem: "superpowers OC adapter unavailable (see cc-parity.log)", detail: String(e?.message ?? e) };
  }
  if (sp?.problem) {
    inv.problems.push(sp.problem);
    log(`superpowers adapter: ${sp.detail ?? "unavailable"}`);
  }
  const spHooks = isObj(sp?.hooks) ? sp.hooks : {};

  // ---- versions: kind-3 digest (R40) and the OC version (R10), off the init path ----
  const storedCc = state.versions.cc;
  const storedOc = state.versions.oc;
  const ocVersionP = later(() => (deps.ocVersion ?? defaultOcVersion)(), (e) => fail("ocVersion", e));
  const kind3 = later(async () => {
    const cur = semver((deps.ccVersion ?? coreCcVersion)());
    if (!cur) return null; // unknown: record nothing
    const prev = semver(storedCc); // the stored value may carry text ("2.1.0 (Claude Code)")
    if (!prev || cmpVer(prev, cur) > 0) return { record: cur, item: null }; // first run / downgrade
    if (prev === cur) return null;
    const md = await (deps.fetchChangelog ?? coreFetchChangelog)();
    if (!md) return null; // fetch failed: keep the stored version so the range is retried
    const digest = hookDigest(parseChangelog(md), prev, cur, knownSet());
    return { record: cur, item: digest ? { key: `k3\u0000${prev}\u0000${cur}`, prev, cur, digest } : null };
  }, (e) => fail("kind3", e));

  // ---- shared helpers ----
  let cfgMcpNames = [];
  const mcpNames = () => dedupe([...Object.keys(inv.mcp ?? {}), ...cfgMcpNames]);
  // Minor 6: only `command` handlers are dispatched; prompt/http/agent types stay reported as unknown
  // (enumerate) and never spawn `bash -c undefined`.
  const hooksFor = (event) => inv.hooks.filter((h) => h.event === event && RUNS.has(h.disposition) && h.type === "command");
  const toolHooks = (event, call) => hooksFor(event).filter((h) => matches(h.matcher, call.tool_name) && ifAllows(h.if, call));

  const topCache = new Map();
  // isTopLevel = !(await client.session.get({ path: { id } })).data?.parentID, cached per session.
  // A failed lookup is logged and treated as top-level, uncached (superpowers 7.0.0 does the same).
  async function isTopLevel(sessionID) {
    if (topCache.has(sessionID)) return topCache.get(sessionID);
    try {
      const r = await client.session.get({ path: { id: sessionID } });
      if (!r || r.error != null || !isObj(r.data)) throw new Error("session lookup returned no session");
      const top = !r.data.parentID;
      topCache.set(sessionID, top);
      return top;
    } catch (e) {
      log(`isTopLevel(${sessionID}): ${String(e?.message ?? e)}; treated as top-level`);
      return true;
    }
  }

  // D4: Stop runs, started from the un-awaited `event`, are tracked here; dispose awaits each,
  // bounded by its hooks' own timeouts plus exitGraceMs, and the process "exit" handler records
  // whatever is still in flight. R53.1: detached hooks (R26, D3) are NOT in this set: they go in
  // detachedRuns, and dispose cancels them instead of waiting (CC's teardown, `Qis`).
  // R54 I-1: a run's deadline and the hooks it may count come from its SYNC entries only. An async
  // or asyncRewake entry is detached once spawned: its timeout must not stretch the wait, and it is
  // never a failure here (R53.1). A run with only async entries is still tracked, with exitGraceMs
  // as its deadline, so dispose lets run() spawn them before the cancel step looks for them.
  const inflight = new Set(); // { p, entries: sync entries (counted), all, deadline }
  const detachedRuns = new Set(); // { entry, cancel }
  const track = (p, entries) => {
    if (!entries.length) return;
    const sync = entries.filter((e) => !(e.async || e.asyncRewake));
    const rec = { p, entries: sync, all: entries, deadline: Date.now() + (sync.length ? Math.max(...sync.map((e) => timeoutFor(e))) * 1000 : 0) + exitGraceMs };
    inflight.add(rec);
    p.then(
      () => inflight.delete(rec),
      () => inflight.delete(rec),
    );
  };
  const idList = (entries) => dedupe(entries.map((e) => `${e.id} (${e.event})`)).join(", ");
  const inflightIds = (recs) => idList(recs.flatMap((r) => r.entries));

  // Runs entries in parallel (CC semantics), one runHook per entry so R26's onDetached knows which
  // hook failed. Failures -> state.failures; malformed / not-honoured (R24) / unknown fields -> log.
  async function run(entries, input, cwd = projectDir) {
    return Promise.all(
      entries.map(async (e) => {
        let settle;
        const settled = new Promise((res) => (settle = res));
        const r = await runHook(e, input, {
          cwd,
          projectDir,
          env: settingsEnv,
          onDetached: (d) => {
            try {
              if (d?.failed) {
                state.failures.add(e.id, failMsg(d));
                log(`detached hook failed: ${e.id} (${e.event}) ${failMsg(d)}`);
                scheduleFlush();
              }
            } finally {
              settle();
            }
          },
        });
        if (r?.detached) {
          const rec = { entry: e, cancel: r.cancel };
          detachedRuns.add(rec);
          settled.then(() => detachedRuns.delete(rec));
        }
        const it = interpret(e.event, r);
        if (it.failed) {
          state.failures.add(e.id, failMsg(r));
          log(`hook failed: ${e.id} (${e.event}) ${failMsg(r)}`);
          scheduleFlush();
        }
        if (it.malformed) log(`hook ${e.id} (${e.event}) printed malformed JSON; ignored`);
        if (it.notHonoured) log(`hook ${e.id} not honoured: ${it.notHonoured}`);
        if (it.unknownFields?.length) log(`hook ${e.id} (${e.event}) output fields not handled: ${it.unknownFields.join(", ")}`);
        return { entry: e, r, it };
      }),
    );
  }

  const textPart = (sid, output, text) => ({ id: partId(), sessionID: sid, messageID: output?.message?.id, type: "text", synthetic: true, text });

  // Unseen items in the brief's order: unknowns (not-translated first), unclassified bridged hooks,
  // degraded hooks, failures, problems, kind-3, self-probe mismatches. Each item has a `kind`, a short
  // `name` for the compact line and the `full` text (ids included) for cc-parity.log.
  function parityItems(k3, failures, ocChange) {
    const items = [];
    const local = new Set();
    const add = (key, kind, name, full) => {
      if (key !== undefined && (state.seen.has(key) || local.has(key))) return;
      if (key !== undefined) local.add(key);
      items.push({ key, kind, name, full });
    };
    const nt = (u) => /^affects behaviour; not translated/.test(u.note);
    for (const u of inv.unknown) if (nt(u)) add(`u\u0000${u.where}\u0000${u.key}\u0000${u.note}`, "notTranslated", u.key, `${u.key} (${u.where}): ${u.note}`);
    for (const u of inv.unknown) if (!nt(u)) add(`u\u0000${u.where}\u0000${u.key}\u0000${u.note}`, "unknown", u.key, `${u.key} (${u.where}): ${u.note}`);
    const hookLine = (h) => `${h.id} ${hookName(h)} (${h.event}${h.matcher ? ` ${h.matcher}` : ""}, ${h.origin}): ${h.command ?? ""}${Array.isArray(h.args) ? ` ${JSON.stringify(h.args)}` : ""}`;
    for (const h of inv.hooks) {
      if (h.disposition === "bridge" && !h.classified) add(`hb\u0000${h.id}`, "bridged", hookName(h), `unclassified hook, runs bridged: ${hookLine(h)}`);
    }
    for (const h of inv.degraded) add(`hd\u0000${h.id}`, "degraded", hookName(h), `degraded hook: ${hookLine(h)}; ${h.reason}`);
    const byId = new Map(inv.hooks.map((h) => [h.id, h]));
    for (const f of failures) {
      const h = byId.get(f.hookId);
      add(undefined, "failure", h ? hookName(h) : f.hookId, `failure ${f.hookId}${h ? ` ${hookName(h)}` : ""} at ${f.ts}: ${f.msg}`);
    }
    const probe = new Set(inv.probeMismatches);
    const label = (p) => PROBLEM_LABELS[p] ?? (p === INVENTORY_FAILED ? "CC inventory failed" : /^superpowers .*unavailable/.test(p) ? "superpowers adapter unavailable" : p);
    for (const p of inv.problems) if (!probe.has(p)) add(`p\u0000${p}`, "problem", label(p), p);
    if (k3?.item) {
      const top = /top 3: (.*)$/.exec(k3.item.digest)?.[1] ?? "";
      const n = /^(\d+)/.exec(k3.item.digest)?.[1] ?? "?";
      add(k3.item.key, "kind3", `${k3.item.prev}->${k3.item.cur}: ${n} hook lines, ${top}`, `CC ${k3.item.prev} -> ${k3.item.cur}: ${k3.item.digest}`);
    }
    // Minor 7: an OC version change, once (keyed by the pair), like a CC version change.
    if (ocChange) {
      const { prev, cur } = ocChange;
      add(`oc\u0000${prev}\u0000${cur}`, "ocVersion", `${prev}->${cur}`, `OC ${prev} -> ${cur}: the adapter's measured OC behaviour (docs/v1-capabilities.md) is for OC 1.19.0; hook and permission behaviour may differ, and the self-probe re-checks tool args from this session's calls`);
    }
    for (const p of inv.probeMismatches) {
      const m = /OC tool (\S+) sent arg "([^"]*)"/.exec(p);
      add(`p\u0000${p}`, "probe", m ? `${m[1]}.${m[2]}` : p, p);
    }
    return items;
  }

  // R42: ONE compact line (spec 5.7), at most LINE_MAX chars, grouped by kind with counts, groups
  // joined by GROUP_SEP (which no name can contain), ending with the log path. Names per group
  // shrink 3 -> 0 until the line fits.
  function compactLine(items) {
    const build = (maxNames) => {
      const groups = [];
      for (const [kind, one, many, len, tail] of KINDS) {
        const its = items.filter((i) => i.kind === kind);
        if (!its.length) continue;
        const counts = new Map();
        for (const i of its) {
          const n = shortName(i.name, len, tail);
          counts.set(n, (counts.get(n) ?? 0) + 1);
        }
        const shown = [...counts].slice(0, maxNames);
        const rest = its.length - shown.reduce((s, [, c]) => s + c, 0);
        const names = shown.map(([n, c]) => (c > 1 ? `${n} x${c}` : n));
        if (names.length && rest) names.push(`+${rest}`);
        groups.push(`${its.length} ${its.length === 1 ? one : many}${names.length ? ` (${names.join(", ")})` : ""}`);
      }
      return `CC parity: ${[...groups, `full list: ${logFile}`].join(GROUP_SEP)}`;
    };
    let line;
    for (const k of [3, 2, 1, 0]) {
      line = build(k);
      if (line.length <= LINE_MAX) break;
    }
    return line;
  }

  // First user message of a top-level session: SessionStart (awaited) + the parity line, as ONE
  // pushed part. Items are marked seen, failures drained and the CC version recorded only AFTER the
  // push. Never rejects.
  const started = new Set();
  async function deliver(sid, output) {
    try {
      started.add(sid);
      const contexts = [];
      const ss = hooksFor("SessionStart").filter((h) => matches(h.matcher, "startup"));
      if (ss.length) {
        for (const { it } of await run(ss, buildInput("SessionStart", { sessionId: sid, cwd: projectDir, source: "startup" }))) {
          if (it.context) contexts.push(it.context);
        }
      }
      const k3 = await kind3;
      const ocv = await ocVersionP;
      const prevOc = semver(storedOc);
      // First run (nothing stored): record only. Any later change, either way, is reported once.
      const ocChange = ocv && prevOc && prevOc !== ocv ? { prev: prevOc, cur: ocv } : null;
      const failures = state.failures.list();
      const items = parityItems(k3, failures, ocChange);
      const blocks = [...contexts];
      const line = items.length ? compactLine(items) : null;
      if (line) blocks.push(line);
      if (blocks.length) output.parts.push(textPart(sid, output, blocks.join("\n\n")));
      // ---- only after the push ----
      let logged = true;
      if (line) {
        // The full itemised list, one item per line under a header, is the readable record (R42).
        logged = log(`CC parity delivered to ${sid}: ${items.length} items; line (${line.length} chars): ${line}`);
        for (const i of items) logged = log(`  parity [${i.kind}] ${i.full}`) && logged;
      }
      if (logged) {
        for (const i of items) if (i.key) state.seen.add(i.key);
        if (failures.length) state.failures.drain();
        if (k3?.record) state.versions.setCc(k3.record);
        if (ocv) state.versions.setOc(ocv);
      } else {
        // The line pointed at a full list that was not written: leave every item, failure and the
        // CC/OC versions as they were, so the line repeats next session (a repeat, never a loss).
        log(`cc-parity.log write failed: ${items.length} parity items left unseen; they repeat next session`);
      }
      flushNow();
    } catch (e) {
      fail("chat.message:deliver", e);
    }
  }

  async function userPromptSubmit(sid, output) {
    const entries = hooksFor("UserPromptSubmit");
    if (!entries.length) return;
    const prompt = output.parts
      .filter((p) => p?.type === "text" && !p.synthetic && typeof p.text === "string")
      .map((p) => p.text)
      .join("\n");
    const blocks = [];
    const contexts = [];
    for (const { it } of await run(entries, buildInput("UserPromptSubmit", { sessionId: sid, cwd: projectDir, prompt }))) {
      if (it.block) blocks.push(it.block);
      if (it.context) contexts.push(it.context);
    }
    // chat.message must not throw (OC turns a rejection into a defect), so a block is told to the
    // model instead of erasing the prompt as CC does.
    let text = null;
    if (blocks.length) {
      text = `A UserPromptSubmit hook blocked this prompt: ${blocks.join("; ")}. Do not act on the prompt; tell the user it was blocked and why.`;
      log(`UserPromptSubmit block in ${sid}: ${blocks.join("; ")}`);
    } else if (contexts.length) text = contexts.join("\n\n");
    if (text) output.parts.push(textPart(sid, output, text));
  }

  const appendContext = (output, text) => {
    if (typeof output?.output === "string") output.output += `\n\n${text}`;
    else if (Array.isArray(output?.content)) output.content.push({ type: "text", text }); // R8: MCP
    else log("PostToolUse context dropped: unrecognised tool output shape");
  };

  // R34: re-assert the read-only built-ins' edit deny; a user's own agent-level OC rule stays last.
  // OC merges cfg.agent.<name>.permission AFTER the user ruleset (agent.ts), so this deny beats the
  // R45 edit "*":"ask" and any CC Edit allow. userEdit: the user-level edit rules about to be set
  // (m6): plan's plan-file allows are dropped when a deny there covers them, since they merge after
  // the user rules and would otherwise beat a CC Edit deny.
  function reassertReadOnly(cfg, userEdit) {
    cfg.agent = isObj(cfg.agent) ? cfg.agent : {};
    const planData = path.relative(worktree, path.join(ocPaths(env).dataDir, "plans", "*.md"));
    for (const name of READ_ONLY_AGENTS) {
      const a = isObj(cfg.agent[name]) ? cfg.agent[name] : (cfg.agent[name] = {});
      a.permission = isObj(a.permission) ? a.permission : {};
      const own = a.permission.edit;
      const base = { "*": "deny" };
      if (name === "plan") {
        const denies = isObj(userEdit) ? Object.keys(userEdit).filter((k) => userEdit[k] === "deny") : userEdit === "deny" ? ["*"] : [];
        for (const k of [path.join(".opencode", "plans", "*.md"), planData]) if (!denies.some((d) => wildcardMatch(k, d))) base[k] = "allow";
      }
      a.permission.edit = { ...base, ...(typeof own === "string" ? { "*": own } : isObj(own) ? own : {}) };
    }
    // R48 (b): by the same mechanism, the built-in DENY value of every key R45 adds at user level
    // (webfetch, websearch, task, skill, each configured server's "<srv>_*") for the deny-all built-ins,
    // plus the other built-in denies listed above. Built-in allows are never touched. A user's own
    // agent-level rule for the key still wins: a string replaces, an object is merged over the deny.
    const servers = Object.keys(isObj(cfg.mcp) ? cfg.mcp : {}).map((s) => `${sanitizeMcpName(s)}_*`);
    const targets = { ...OTHER_BUILTIN_DENIES };
    for (const [name, allowed] of Object.entries(DENY_ALL_AGENTS)) {
      targets[name] = Object.fromEntries([...R45_KEYS, ...servers].filter((k) => !allowed.includes(k)).map((k) => [k, "deny"]));
    }
    for (const [name, rules] of Object.entries(targets)) {
      const a = isObj(cfg.agent[name]) ? cfg.agent[name] : (cfg.agent[name] = {});
      const own = isObj(a.permission) ? a.permission : {};
      const re = {};
      for (const [k, v] of Object.entries(rules)) {
        const o = own[k];
        re[k] = typeof o === "string" ? o : isObj(o) ? { ...(typeof v === "string" ? { "*": v } : v), ...o } : v;
      }
      // Re-asserted keys first, the user's other agent-level keys after, so a user's narrower rule
      // (say `srv_tool: allow` under a re-asserted `srv_*`) is still the last match.
      a.permission = { ...re, ...Object.fromEntries(Object.entries(own).filter(([k]) => !Object.hasOwn(re, k))) };
    }
  }

  // Minor 2 (and a config-hook throw before the CC permission landed): the baseline plus a
  // fail-closed overlay, never the bare baseline, which carries none of CC's denies.
  function failsafe(cfg) {
    const servers = Object.keys(isObj(cfg.mcp) ? cfg.mcp : {});
    const fb = toOcPermission({ ask: FAILSAFE_ASKS }, cfg.permission, { home, worktree, mcpServers: servers });
    reassertReadOnly(cfg, fb.permission.edit);
    cfg.permission = fb.permission;
    log(`config: fail-safe permission overlay applied (${FAILSAFE_ASKS.join(", ")} and every MCP server ask)`);
  }

  const delivery = new Map(); // sessionID -> the in-flight / finished first delivery
  const preContext = new Map(); // callID -> PreToolUse additionalContext, appended to the result

  try {
    (deps.onExit ?? ((fn) => process.once("exit", fn)))(() => {
      // D4: an exit that dispose did not see through (a hard exit, or dispose cut short). Only
      // synchronous work runs here: one log line and one counted failure per Stop hook still in
      // flight, so it surfaces in the next session's parity line. R53.1: Stop only; a detached hook
      // still running is not recorded (CC counts those as cancelled, not failed).
      try {
        const recs = [...inflight].filter((r) => r.entries.length);
        inflight.clear();
        if (recs.length) {
          log(`hooks pending at exit, outcome unknown: ${inflightIds(recs)}`);
          for (const r of recs) for (const e of r.entries) state.failures.add(e.id, "pending at exit: still running when OC exited; outcome unknown");
        }
      } catch {
        // exiting
      }
      try {
        flushNow();
      } catch {
        // exiting
      }
    });
  } catch (e) {
    fail("onExit", e);
  }

  return {
    config: async (cfg) => {
      let applied = false; // the CC-layered (or fail-safe) permission is in cfg
      try {
        if (isObj(cfg) && inv.failed) {
          failsafe(cfg);
          applied = true;
        } else if (isObj(cfg)) {
          // R45: OC's own configured servers ask too, not only the CC ones.
          const servers = dedupe([...Object.keys(isObj(cfg.mcp) ? cfg.mcp : {}), ...Object.keys(inv.mcp ?? {})]);
          const pa = permissionAndAgents({ merged: inv.merged, plugins: inv.plugins, mcp: inv.mcp, home, projectDir, worktree, baseline: cfg.permission, mcpServers: servers });
          addUnknowns(pa.unknown);
          inv.permission = pa.permission;
          inv.agent = pa.agent;
          inv.command = pa.command;
          if (Array.isArray(cfg.skills)) log("config: skills is an array (not OC V1); skills.paths not set");
          else {
            cfg.skills = isObj(cfg.skills) ? cfg.skills : {};
            cfg.skills.paths = dedupe([...(Array.isArray(cfg.skills.paths) ? cfg.skills.paths : []), ...inv.skillPaths]);
          }
          // Minor 9: the serena `override` marker is internal; OC's McpLocalConfig has no such field.
          const ocMcp = Object.fromEntries(Object.entries(inv.mcp ?? {}).map(([k, v]) => [k, isObj(v) ? withoutOverride(v) : v]));
          cfg.mcp = { ...(isObj(cfg.mcp) ? cfg.mcp : {}), ...ocMcp };
          cfgMcpNames = Object.keys(cfg.mcp);
          cfg.agent = isObj(cfg.agent) ? cfg.agent : {};
          for (const [name, a] of Object.entries(pa.agent)) cfg.agent[name] = { ...(isObj(cfg.agent[name]) ? cfg.agent[name] : {}), ...a };
          reassertReadOnly(cfg, pa.permission.edit);
          // Only now the CC-layered permission (review M5). A throw before this line gets the
          // fail-safe overlay in the catch below, never the bare baseline.
          cfg.permission = pa.permission;
          applied = true;
          cfg.command = { ...(isObj(cfg.command) ? cfg.command : {}), ...pa.command };
          cfg.instructions = dedupe([...(Array.isArray(cfg.instructions) ? cfg.instructions : []), ...inv.instructions]);
        }
      } catch (e) {
        fail("config", e);
        if (isObj(cfg) && !applied) {
          try {
            failsafe(cfg);
          } catch (e2) {
            fail("config:failsafe", e2);
          }
        }
      }
      try {
        await spHooks.config?.(cfg);
      } catch (e) {
        fail("config:superpowers", e);
      }
    },

    "tool.definition": async (input) => {
      try {
        if (typeof input?.toolID === "string") {
          state.observed.tools.add(input.toolID);
          scheduleFlush();
        }
      } catch (e) {
        fail("tool.definition", e);
      }
    },

    "tool.execute.before": async (input, output) => {
      const tool = input?.tool;
      const args = output?.args;
      // R7 bookkeeping, isolated: its failure says nothing about the guards, so it never blocks.
      try {
        if (typeof tool === "string" && isObj(args)) {
          // arg names for every tool (MCP included); per-tool union for the self-probe.
          state.observed.args.set(tool, dedupe([...(state.observed.args.get(tool) ?? []), ...Object.keys(args)]));
          scheduleFlush();
        }
      } catch (e) {
        fail("tool.execute.before:observe", e);
      }
      // Minor 1, fail closed: while any configured PreToolUse entry may apply to this call, an
      // internal error BLOCKS; only once matching has proved that none applies is it non-blocking.
      let guarded = false;
      try {
        guarded = hooksFor("PreToolUse").length > 0;
        const calls = toCcCalls(tool, args, projectDir, mcpNames());
        if (calls && !Array.isArray(calls)) {
          if (calls.block) {
            // R32: fail closed, deliberately; logged and counted (a parity item next session). The
            // block is thrown whatever the bookkeeping does.
            try {
              log(`blocked ${tool} (${input?.callID}): ${calls.block}`);
              state.failures.add("apply_patch", calls.block);
              scheduleFlush();
            } catch {
              // bookkeeping only
            }
            throw new Block(calls.block);
          }
          return;
        }
        if (!calls) return;
        const blocks = [];
        const updates = [];
        const contexts = [];
        // Match every call first (pure: matcher + `if`), then run, in the same order as before.
        const matched = [];
        for (const call of calls) {
          const entries = toolHooks("PreToolUse", call);
          if (entries.length) matched.push({ call, entries });
        }
        guarded = matched.length > 0;
        for (const { call, entries } of matched) {
          const cwd = call.cwd ?? projectDir;
          const input2 = buildInput("PreToolUse", { sessionId: input.sessionID, cwd, toolName: call.tool_name, toolInput: call.tool_input, toolUseId: input.callID });
          for (const { entry, it } of await run(entries, input2, cwd)) {
            if (it.block) blocks.push(it.block);
            if (it.updatedInput) updates.push({ entry, u: it.updatedInput, call });
            if (it.context) contexts.push(it.context);
          }
        }
        if (blocks.length) throw new Block(blocks.join("\n"));
        // m3: an update that only echoes its call's input rewrote nothing; with no real change the
        // R48 checks do not apply, on any tool. R51 I-1: CC REPLACES the input (bundle Xwe:
        // `e.updatedInput??n`), so a key of the call's input missing from the update is a change too.
        const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        const changed = updates.filter(
          ({ u, call }) => !isObj(u) || Object.keys(call.tool_input ?? {}).some((k) => !Object.hasOwn(u, k)) || Object.keys(u).some((k) => !same(u[k], call.tool_input?.[k])),
        );
        if (changed.length) {
          // R48: a rewrite that cannot be applied in full BLOCKS. Running the original args would
          // silently drop a sanitising hook's rewrite; applying part of it would run neither version.
          let why = null;
          if (calls.length > 1) why = `${tool} maps to ${calls.length} CC calls`;
          else if (!UPDATABLE.has(tool)) why = `no reverse arg map for OC ${tool}`;
          else {
            const extra = dedupe(changed.flatMap(({ u }) => unmappedUpdateKeys(tool, calls[0].tool_input, u)));
            const dropped = dedupe(changed.flatMap(({ u }) => undroppableKeys(tool, calls[0].tool_input, u)));
            if (extra.length) why = `no OC ${tool} arg for ${extra.join(", ")}`;
            else if (dropped.length) why = `the hook dropped ${dropped.join(", ")}, which OC ${tool} requires`;
          }
          if (why) {
            try {
              // logged AND counted, so the blocked rewrite also reaches the parity line
              log(`updatedInput ignored: ${why}`);
              for (const { entry } of changed) state.failures.add(entry.id, `updatedInput not honoured: ${why}`);
              scheduleFlush();
            } catch {
              // bookkeeping only; the block is thrown whatever it does
            }
            throw new Block(`hook rewrote the input but the rewrite can't be applied in OpenCode: ${why}`);
          }
          // OC executes the ORIGINAL args object (session/tools.ts:106-111), so update it in place.
          // R51 m-6: a dropped optional arg is deleted from the same object.
          for (const { u, call } of changed) {
            const next = applyUpdatedInput(tool, output.args, u, call.tool_input);
            for (const k of Object.keys(output.args)) if (!Object.hasOwn(next, k)) delete output.args[k];
            Object.assign(output.args, next);
          }
        }
        if (contexts.length && input.callID) preContext.set(input.callID, contexts);
      } catch (e) {
        if (e instanceof Block) throw e;
        fail("tool.execute.before", e);
        if (guarded) {
          const m = String(e?.message ?? e).slice(0, 120);
          throw new Block(`the CC parity adapter failed while CC PreToolUse hooks applied to this call (${m}); the call is blocked (failed closed). Details: cc-parity.log`);
        }
      }
    },

    "tool.execute.after": async (input, output) => {
      try {
        const contexts = [];
        if (input?.callID && preContext.has(input.callID)) {
          contexts.push(...preContext.get(input.callID));
          preContext.delete(input.callID);
        }
        const calls = toCcCalls(input?.tool, input?.args, projectDir, mcpNames());
        if (Array.isArray(calls)) {
          // Built-ins: output.output is the text. MCP (row 4): output is the raw MCP result.
          // A snapshot, so the hook input never aliases the content array context is appended to.
          const raw = typeof output?.output === "string" ? output.output : isObj(output) ? { ...output, content: Array.isArray(output.content) ? [...output.content] : output.content } : output;
          for (const call of calls) {
            const entries = toolHooks("PostToolUse", call);
            if (!entries.length) continue;
            const cwd = call.cwd ?? projectDir;
            const input2 = buildInput("PostToolUse", {
              sessionId: input.sessionID,
              cwd,
              toolName: call.tool_name,
              toolInput: call.tool_input,
              toolUseId: input.callID,
              toolResponse: toCcResponse(call.tool_name, raw, call.tool_input),
            });
            for (const { it } of await run(entries, input2, cwd)) if (it.context) contexts.push(it.context);
          }
        }
        if (contexts.length) appendContext(output, contexts.join("\n"));
      } catch (e) {
        fail("tool.execute.after", e);
      }
    },

    // No injection here: OC does not await `event` (row 7). D4: so the Stop run is tracked from this
    // first line (before the session lookup) and dispose awaits it.
    event: async ({ event } = {}) => {
      let p = null;
      try {
        if (event?.type !== "session.idle") return;
        const entries = hooksFor("Stop");
        if (!entries.length) return;
        p = (async () => {
          try {
            const sid = event.properties?.sessionID;
            if (typeof sid !== "string" || !(await isTopLevel(sid))) return; // CC's Stop skips subagents
            await run(entries, buildInput("Stop", { sessionId: sid, cwd: projectDir }));
          } catch (e) {
            fail("event", e);
          }
        })();
        track(p, entries);
      } catch (e) {
        fail("event", e);
      }
      await p;
    },

    // R9: chat.message also fires for other plugins' noReply prompts (indistinguishable here: the
    // trigger passes only sessionID/agent/model/messageID/variant, prompt.ts:999-1008) and in child
    // sessions. Delivery goes to the FIRST qualifying message of a top-level session; a concurrent
    // message in the same session waits for that delivery before it returns.
    "chat.message": async (input, output) => {
      try {
        const sid = input?.sessionID;
        if (typeof sid !== "string" || !Array.isArray(output?.parts)) return;
        if (!(await isTopLevel(sid))) return;
        if (output.parts.every((p) => p?.synthetic === true || p?.ignored === true)) return; // OC-internal prompt
        let d = delivery.get(sid);
        if (!d) {
          d = deliver(sid, output);
          delivery.set(sid, d);
        }
        await d;
        await userPromptSubmit(sid, output);
      } catch (e) {
        fail("chat.message", e);
      }
    },

    "experimental.session.compacting": async (input, output) => {
      try {
        const entries = hooksFor("PreCompact").filter((h) => matches(h.matcher, "auto"));
        if (!entries.length) return;
        for (const { it } of await run(entries, buildInput("PreCompact", { sessionId: input?.sessionID, cwd: projectDir, trigger: "auto" }))) {
          if (it.context && Array.isArray(output?.context)) output.context.push(it.context);
        }
      } catch (e) {
        fail("experimental.session.compacting", e);
      }
    },

    "experimental.chat.messages.transform": async (input, output) => {
      try {
        await spHooks["experimental.chat.messages.transform"]?.(input, output);
      } catch (e) {
        fail("experimental.chat.messages.transform", e);
      }
    },

    // Settings `env`, and (R17) each enabled, existing plugin's bin/ first on PATH, as CC does for Bash.
    "shell.env": async (_input, output) => {
      try {
        if (!isObj(output?.env)) return;
        Object.assign(output.env, settingsEnv);
        const bins = inv.plugins.filter((p) => p?.exists && p.installPath).map((p) => path.join(p.installPath, "bin")).filter(isDir);
        if (bins.length) {
          const key = Object.keys(process.env).find((k) => k.toLowerCase() === "path") ?? "PATH";
          const cur = output.env[key] ?? process.env[key] ?? "";
          output.env[key] = [...bins, cur].filter(Boolean).join(path.delimiter);
        }
      } catch (e) {
        fail("shell.env", e);
      }
    },

    // SessionEnd is best effort: OC calls dispose on instance shutdown; a hard exit only flushes.
    // D4: OC v1.19.0 awaits dispose before it exits (effect-cmd.ts `finally { await
    // store.dispose(ctx) }` -> the plugin scope finalizer `Promise.resolve(hook.dispose?.())`; then
    // index.ts process.exit()), so in-flight synchronous Stop runs are awaited here first, each
    // bounded by its SYNC hooks' own timeouts plus exitGraceMs (R54 I-1). A run that outlives its bound is logged
    // and counted; it never blocks exit for longer. R53.1: then, after SessionEnd (R54 m-6), every
    // detached hook still running (an async Stop or SessionEnd hook included) is cancelled, as CC's
    // teardown does
    // (`Qis`: `r.shellCommand.kill(); await PWe(r,1,"cancelled")`): the runner's R23/R27-R29 tree
    // kill, reported as cancelled and never counted. Detached hooks are never waited for.
    dispose: async () => {
      try {
        const waited = new Set();
        for (;;) {
          const batch = [...inflight].filter((r) => !waited.has(r));
          if (!batch.length) break;
          for (const r of batch) waited.add(r);
          log(`dispose: waiting for Stop runs in flight at exit: ${idList(batch.flatMap((r) => r.all))}`);
          const late = await Promise.all(
            batch.map(
              (r) =>
                new Promise((res) => {
                  // a ref'd timer: it also keeps the process alive while the runs settle
                  const t = setTimeout(() => res(r), Math.max(0, r.deadline - Date.now()));
                  r.p.then(
                    () => (clearTimeout(t), res(null)),
                    () => (clearTimeout(t), res(null)),
                  );
                }),
            ),
          );
          for (const r of late) {
            if (!r || !inflight.has(r)) continue;
            inflight.delete(r); // counted here, so the exit handler does not count it again
            if (!r.entries.length) continue; // async only: nothing to count (R53.1)
            log(`hooks still running at exit, past their timeout: ${inflightIds([r])}`);
            for (const e of r.entries) state.failures.add(e.id, "still running at exit, past its timeout");
          }
        }
      } catch (e) {
        fail("dispose:inflight", e);
      }
      try {
        const entries = hooksFor("SessionEnd").filter((h) => matches(h.matcher, "other"));
        if (entries.length && started.size) {
          const all = Promise.all([...started].map((sid) => run(entries, buildInput("SessionEnd", { sessionId: sid, cwd: projectDir, reason: "other" }))));
          await Promise.race([
            all,
            new Promise((r) => {
              const t = setTimeout(r, SESSION_END_BUDGET_MS);
              t.unref?.();
            }),
          ]);
        }
      } catch (e) {
        fail("dispose", e);
      }
      // R54 m-6: the cancel step runs AFTER SessionEnd, so an async SessionEnd hook spawned just
      // above is cancelled too instead of outliving OC.
      try {
        const recs = [...detachedRuns];
        detachedRuns.clear();
        if (recs.length) {
          log(`dispose: cancelling detached hooks still running at exit (cancelled, not failures, as in CC): ${dedupe(recs.map((r) => `${r.entry.id} (${r.entry.event})`)).join(", ")}`);
          let t;
          await Promise.race([
            Promise.all(recs.map((r) => Promise.resolve().then(() => r.cancel?.()).catch(() => {}))),
            new Promise((res) => (t = setTimeout(res, exitGraceMs))),
          ]);
          clearTimeout(t);
        }
      } catch (e) {
        fail("dispose:cancel", e);
      }
      try {
        await spHooks.dispose?.();
      } catch (e) {
        fail("dispose:superpowers", e);
      }
      flushNow();
    },
  };
}
