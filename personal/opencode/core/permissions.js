import path from "node:path";
import { sanitizeMcpName } from "./toolmap.js";
import { wildcardMatch } from "./wildcard.js";

// CC permission rules -> OC V1 `permission` config, LAYERED onto the OC-owned baseline
// (opencode.json). Measured facts this rests on (docs/v1-capabilities.md, OC v1.19.0 source):
// - OC evaluates with findLast over the rules in config key order (permission/index.ts:28-37,
//   fromConfig :186-198), so ORDER is precedence: the last matching key wins.
// - OC `*` and `?` cross `/` (core/src/util/wildcard.ts); `[` is literal. CC uses gitignore
//   semantics: `*` stays within one segment, a bare filename matches at any depth.
// - `**/x` does not match a root-level `x` (row 16a): every `**/x` also emits `x`.
// - `~/x` is expanded to an absolute path, but edit/read ask with a worktree-RELATIVE path
//   (row 16b): every anchored rule also emits path.relative(worktree, abs) (R5).
// - edit/read never get an ALLOW match-everything key (row 16c): it would override the
//   plan/explore agents' built-in edit deny. A CC deny-all is emitted as "*":"deny" LAST; a
//   match-everything ask (I1) and edit's uncovered "*":"ask" (R45) are safe only because
//   v1/plugin.js re-asserts the read-only agents' edit deny per agent (R34), merged after these.
// - MCP tools ask with permission = their tool id `<server>_<tool>`, pattern "*"
//   (session/tools.ts:408), so a CC mcp__ rule becomes a top-level permission key.
// - OC's config schema (core/src/v1/config/permission.ts:18-35) types todowrite, question,
//   webfetch, websearch and doom_loop as a BARE action; an object there makes GET /config
//   fail (HTTP 400) and the TUI exit (T7 review C1). Those keys are only ever strings here.
//
// Key order inside each permission object (R34; CC precedence is deny > ask > allow):
//   "*" catch-all (bash gets "ask" when neither side sets one) -> NEW CC allow keys -> a CC
//   "*":"ask" -> NEW CC ask keys -> the baseline keys in their own order -> NEW CC deny keys ->
//   a CC "*":"deny". So a baseline deny survives a broader CC ask, CC denies beat everything,
//   and only a baseline allow-back can soften a broader CC ask (accepted, R34). A CC rule on an
//   existing baseline key keeps the baseline position and the STRICTER action.
//
// Allows are emitted only in a form that matches no path CC's form would not (R34, I3); an
// allow that cannot be narrowed to such a form is unknown. Denies and asks may over-match.
//
// Fail closed (final review I1): a deny or ask with no exact OC form is emitted as an
// over-matching SUPERSET at the same action (`/x` -> `**/x`, `[ab]` -> `?`, an MCP server glob ->
// one key per configured server it matches plus `<glob>_<tool>` unless that hits an OC built-in, a tool with no per-pattern form -> the whole key), and, where no superset
// exists (a `!x` negation), as an ask on the whole key, following R35. Every lossy translation is
// still reported. Only ALLOWS drop to unknown, since dropping an allow fails closed.
//
// Uncovered calls get CC 2.1.300's own default for the tool (R45 as refined by R49; evidence in
// docs/v1-capabilities.md): edit "*":"ask" comes FIRST within edit, webfetch / websearch get
// "ask", and each skill CC would prompt for (ctx.skillAsks) gets "<name>":"ask", each only when
// neither the baseline nor CC sets it; every configured MCP server gets "<sanitised srv>_*":"ask"
// before the CC allows. task and todowrite get nothing: CC runs Agent and TodoWrite without a
// prompt. A top-level "*" is never emitted: it would loosen OC's built-in question / plan_enter /
// plan_exit denies.

const RANK = { allow: 0, ask: 1, deny: 2 };
const KINDS = ["allow", "ask", "deny"];
const stricter = (a, b) => (RANK[b] > RANK[a] ? b : a);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const MATCH_ALL = /^[*/\\]*$/;
const GLOB = /[*?]/;
// Bare-action keys in OC v1.19.0's permission schema (core/src/v1/config/permission.ts:18-35).
export const OC_ACTION_ONLY = ["todowrite", "question", "webfetch", "websearch", "doom_loop"];
// OC v1.19.0's built-in permission names (config/permission.ts:18-35, agent.ts defaults).
const OC_BUILTIN = ["read", "edit", "glob", "grep", "list", "bash", "task", "external_directory", "todowrite", "question", "webfetch", "websearch", "lsp", "doom_loop", "skill", "plan_enter", "plan_exit"];
// Built-ins OC denies by default (agent.ts defaults). A user-level ask or allow on a key that
// wildcard-matches one of these would lift that deny for every agent that does not re-allow it.
const DEFAULT_DENY = ["question", "plan_enter", "plan_exit"];
// Keys with no `ctx.ask`: OC gates the question and plan_exit tools only by visibility
// (Permission.disabled: a "*" deny hides them), so an ask is never prompted.
const VISIBILITY_ONLY = ["question", "plan_exit"];
// Keys emitted as a bare action string (the schema's action-only keys, plus plan_exit, which the
// defaults also set as a string).
const AS_STRING = new Set([...OC_ACTION_ONLY, "plan_exit"]);
// Object keys that get "*":"ask" when neither the baseline nor CC sets one (R45; bash per plan).
// Not task: CC's Agent tool needs no permission outside auto mode (R49).
const ASK_STAR = new Set(["bash", "edit"]);
// Bare-action keys that get "ask" when neither the baseline nor CC sets them (R45).
const ASK_STRING = ["webfetch", "websearch"];

// CC tool -> OC permission key, for the tools OC gates by a permission of its own (OC v1.19.0
// tool sources: websearch.ts:120, task.ts:24,121 (pattern = subagent_type), grep.ts:40,
// glob.ts:29, skill.ts:28 (pattern = skill name), todo.ts:25, lsp.ts:57; question and plan_exit
// by visibility). Read/Edit/Write/MultiEdit/NotebookEdit, Bash, WebFetch and mcp__ are handled
// apart. NotebookEdit has no OC tool; OC's file writers all ask `edit`, so its rules land there.
const TOOL_KEY = {
  WebSearch: "websearch",
  Task: "task",
  Agent: "task",
  Grep: "grep",
  Glob: "glob",
  Skill: "skill",
  TodoWrite: "todowrite",
  LSP: "lsp",
  AskUserQuestion: "question",
  ExitPlanMode: "plan_exit",
};
// CC built-in subagent names whose OC counterpart has another name (OC agent.ts).
const CC_AGENT_ALIASES = { "general-purpose": "general" };

const builtinHits = (key) => OC_BUILTIN.filter((b) => wildcardMatch(b, key));

class Untranslatable extends Error {}
const fail = (note) => {
  throw new Untranslatable(note);
};

// Would OC's cross-segment `*`/`?` make this ALLOW cover more than CC's gitignore pattern?
// A last segment right after `**/` is equivalent. A single-segment RELATIVE pattern matches at
// any depth either way; anchored (~/, //) it does not, so `anchored` drops that exemption.
function broadensInOc(p, anchored) {
  const segs = p.split("/");
  return segs.some(
    (s, i) => s !== "**" && GLOB.test(s) && !((!anchored && segs.length === 1) || (i === segs.length - 1 && segs[i - 1] === "**")),
  );
}

// A worktree-relative OC form whose first non-`..` segment is a glob also matches paths that
// climb OUT of its anchor (`**/x` matches `../../x`). Absolute forms are compared against
// normalised absolute asks only, so they cannot escape their prefix.
function escapesAnchor(f) {
  if (f.startsWith("~") || path.isAbsolute(f) || /^[A-Za-z]:/.test(f)) return false;
  const segs = f.split(/[\\/]/);
  let i = 0;
  while (segs[i] === "..") i++;
  return GLOB.test(segs[i] ?? "");
}

const twinOf = (p) => (p.startsWith("**/") ? [p, p.slice(3)] : [p]);

// Relative CC pattern (no anchor or ./): gitignore depth rules from the CC permissions docs.
function relativeForms(spec, kind) {
  let s = spec;
  const dotSlash = s.startsWith("./");
  while (s.startsWith("./")) s = s.slice(2);
  if (kind === "allow" && broadensInOc(s, false)) fail("OC's * crosses directories, so this allow would cover more than CC's");
  if (s.startsWith("**/")) return twinOf(s);
  // A bare filename matches at any depth in CC (`.env` == `**/.env`). `./x` as an allow is kept
  // anchored: the docs leave its depth open, and the narrower allow is the safe reading.
  if (!s.includes("/")) return dotSlash && kind === "allow" ? [s] : [s, `**/${s}`];
  // A single directory segment (`secrets/**`) matches at any depth for deny/ask only.
  if (kind !== "allow" && /^[^/]+\/(\*\*)?$/.test(s)) return [s, `**/${s}`];
  return [s];
}

// An absolute target (from ~/ or //): the given form, plus R5's exact worktree-relative form,
// plus in-worktree coverage when a leading `**` spans the worktree.
function anchoredForms(first, abs, kind, { worktree }, notes) {
  const forms = [first];
  if (!worktree) {
    notes.push("no worktree: the worktree-relative form (R5) was not emitted, so this rule does not match files on the worktree's drive");
    return forms;
  }
  const rel = path.relative(worktree, abs);
  if (rel && rel !== first) forms.push(rel);
  const segs = abs.split(/[\\/]/);
  const g = segs.findIndex((s) => GLOB.test(s));
  if (g > 0) {
    const fixed = segs.slice(0, g).join(path.sep) || path.sep;
    const rest = segs.slice(g).join("/");
    const wf = path.relative(fixed, worktree);
    const inside = wf === "" || (!wf.startsWith("..") && !path.isAbsolute(wf));
    if (inside) {
      if (rest === "**" || rest.startsWith("**/")) forms.push(...twinOf(rest));
      else notes.push("its glob spans the worktree; files inside the worktree are not covered");
    }
  }
  return forms;
}

const DENY_ALL = ["*"];
// The whole key at "ask", whatever the rule's kind (R35's floor where no superset exists).
const askAll = () => Object.assign(["*"], { action: "ask" });

// -> an array of OC patterns, emitted at the rule's kind unless the array carries `.action`.
// A deny's ["*"] is the deny-all (emitted LAST, R34 / review M1); an ask's ["*"] is "*":"ask"
// (placed after the CC allows, so it beats them, and before the baseline, which keeps its denies).
function pathForms(spec, kind, ctx, notes) {
  if (spec === undefined) {
    if (kind !== "allow") return DENY_ALL;
    fail("a bare file tool allow would need a match-everything key (row 16c)");
  }
  if (spec === "") fail("empty path pattern");
  if (spec.startsWith("!")) {
    if (kind === "allow") fail("gitignore negation has no OC equivalent");
    notes.push("gitignore negation has no OC equivalent and no narrower superset; the whole key asks instead (R35)");
    return askAll();
  }
  if (/\[[^\]]*\]/.test(spec)) {
    if (kind === "allow") fail("character classes are literal in OC's matcher");
    notes.push("each character class is emitted as OC's one-character `?`, which also matches characters outside the class");
    spec = spec.replace(/\[[^\]]*\]/g, "?");
  }
  const broad = "OC's * crosses directories, so this allow would cover more than CC's";
  let forms;
  if (spec.startsWith("/") && !spec.startsWith("//") && kind !== "allow") {
    notes.push("a /path rule is relative to the settings file that defined it, which merged rules no longer carry; emitted as **/path, which also covers that path under any directory");
    forms = relativeForms(`**/${spec.replace(/^\/+/, "")}`, kind);
  } else if (spec.startsWith("//")) {
    const rest = spec.slice(2);
    if (rest === "**" || rest.startsWith("**/")) forms = twinOf(rest);
    else {
      let abs;
      if (process.platform === "win32") {
        // CC normalises C:\x to /c/x (permissions docs), so //c/x is c:/x.
        const m = /^([A-Za-z])(\/.*)?$/.exec(rest);
        if (!m) fail("an absolute // path on Windows needs a drive segment (//c/...)");
        abs = `${m[1]}:${m[2] || "/"}`;
      } else abs = `/${rest}`;
      if (kind === "allow" && broadensInOc(rest, true)) fail(broad);
      forms = anchoredForms(abs, abs, kind, ctx, notes);
    }
  } else if (spec === "~" || spec.startsWith("~/")) {
    if (!ctx.home) fail("no home directory given");
    const sub = spec.slice(2);
    if (kind === "allow" && broadensInOc(sub, true)) fail(broad);
    forms = anchoredForms(spec, path.join(ctx.home, sub), kind, ctx, notes);
  } else if (spec.startsWith("/")) {
    fail("a /path rule is relative to the settings file that defined it, which merged rules no longer carry");
  } else forms = relativeForms(spec, kind);

  if (forms.some((f) => MATCH_ALL.test(f))) {
    if (kind === "allow") fail("would emit a match-everything read/edit allow, which overrides the plan agent's built-in edit deny (row 16c)");
    notes.push(
      kind === "deny"
        ? "covers the whole worktree, so it is emitted as a deny-all (\"*\":\"deny\" last), which also covers paths outside its anchor"
        : "covers the whole worktree, so it is emitted as \"*\":\"ask\", which also covers paths outside its anchor",
    );
    return DENY_ALL;
  }
  if (kind === "allow") {
    const kept = forms.filter((f) => !escapesAnchor(f));
    if (kept.length === 0) fail("every OC form of this allow would also match paths outside its anchor");
    if (kept.length < forms.length) notes.push("narrowed: forms that would also match paths outside the anchor were not emitted, so OC allows less than CC");
    forms = kept;
  }
  return forms;
}

// Sanitise a name the way OC and CC do, keeping the glob characters given. An allow keeps only `*`
// (a `?` sanitises to `_`, narrower); a deny/ask keeps `?` too, since narrowing it would fail open.
const sanGlob = (s, keep) => s.split(keep).map((p) => (keep.test(p) ? p : sanitizeMcpName(p))).join("");
const STAR = /(\*)/;
const STAR_Q = /([*?])/;

// OC matches a top-level key against EVERY permission name, built-ins included (merge + findLast
// over Wildcard.match(permission, rule.permission)). -> { key, action? } for one key.
function builtinChecked(key, kind, notes) {
  const hits = builtinHits(key);
  if (!hits.length) return { key };
  if (kind === "allow") fail(`the OC key ${key} also matches OC's built-in ${hits.join(", ")} permission`);
  const lifted = hits.filter((h) => DEFAULT_DENY.includes(h));
  if (kind === "ask" && lifted.length) {
    notes.push(`the OC key ${key} also matches OC's default-denied ${lifted.join(", ")}; emitted as deny so it cannot lift that deny`);
    return { key, action: "deny" };
  }
  notes.push(`the OC key ${key} also matches OC's built-in ${hits.join(", ")} permission; emitted anyway, fail-safe`);
  return { key };
}

// -> [{ key, action? }]. `action` overrides the rule's kind (an ask upgraded to deny).
function mcpKeys(tool, spec, kind, ctx, notes) {
  if (spec !== undefined) fail("CC itself skips mcp__ rules with parentheses");
  const body = tool.slice(5);
  const i = body.indexOf("__");
  const server = i < 0 ? body : body.slice(0, i);
  const toolPart = i < 0 ? "*" : body.slice(i + 2);
  if (!server) fail("empty MCP server name");
  if (!toolPart) fail("empty MCP tool name");
  const keep = kind === "allow" ? STAR : STAR_Q;
  const S = sanGlob(server, keep);
  const T = sanGlob(toolPart, keep);
  const known = [...new Set((Array.isArray(ctx.mcpServers) ? ctx.mcpServers : []).map(sanitizeMcpName))];
  if (GLOB.test(server)) {
    // m2: one key per configured server the glob matches, so it never reaches an OC built-in; the
    // raw glob key (which also covers a server configured later) only when it hits none.
    if (kind === "allow") fail("a server glob needs the server list; not translated");
    const out = known.filter((o) => wildcardMatch(o, S)).map((o) => builtinChecked(`${o}_${T}`, kind, notes));
    const raw = `${S}_${T}`;
    const hits = builtinHits(raw);
    if (!hits.length) out.push({ key: raw });
    if (!out.length) fail(`the glob matches no configured server, and its OC key ${raw} would also match OC's built-in ${hits.join(", ")} permission`);
    notes.push(
      hits.length
        ? `server glob: emitted once per configured server it matches (${out.map((o) => o.key).join(", ")}); the glob key ${raw} would also match OC's built-in ${hits.join(", ")} permission, so a server added later is not covered`
        : "server glob: emitted as one OC key over every matching server's tools (plus one per configured server), which may also cover tools CC's rule does not",
    );
    return out;
  }
  const key = `${S}_${T}`;
  const globbed = GLOB.test(toolPart);
  const others = known.filter((o) => o !== S);
  const ambiguous = others.some((o) => (globbed ? o.startsWith(`${S}_`) : key.startsWith(`${o}_`)));
  if (ambiguous) {
    if (kind === "allow") fail("the OC key would also cover another server's tools (server-name prefix collision)");
    notes.push("the OC key also covers another server's tools (server-name prefix collision); emitted anyway, fail-safe");
  }
  return [builtinChecked(key, kind, notes)];
}

// A CC tool with an OC key of its own (TOOL_KEY). -> [{ perm, pattern, action? }]
function toolKey(key, tool, spec, kind, notes) {
  const pat = (p, action) => ({ perm: key, pattern: AS_STRING.has(key) ? null : p, ...(action ? { action } : {}) });
  if (VISIBILITY_ONLY.includes(key)) {
    // Gated by visibility only: an allow or ask at user level would show the tool to agents whose
    // built-in rules hide it. An ask emits nothing (m1): OC's plan_exit asks the user itself
    // (tool/plan.ts) and the question tool is itself a prompt; a deny is a deny.
    if (kind === "allow") fail(`OC gates ${key} by visibility only; an allow would lift its built-in deny for subagents`);
    if (kind === "ask") fail(`OC gates ${key} by visibility only, and its tool already puts the call to the user; no rule emitted`);
    if (spec !== undefined) notes.push(`OC's ${key} takes no pattern; the whole key is set`);
    return [pat("*", "deny")];
  }
  if (spec === undefined) return [pat("*")];
  if (!spec.trim()) fail(`empty ${tool} pattern`);
  if (key === "task" || key === "skill") {
    // OC asks task with the subagent name and skill with the skill name; both take patterns.
    if (kind === "allow") {
      if (GLOB.test(spec.replace(/ \*$/, ""))) fail(`a ${tool} name glob may cover more names in OC than in CC`);
      return [pat(spec)];
    }
    const names = [spec, spec.toLowerCase()];
    if (key === "task" && CC_AGENT_ALIASES[spec]) names.push(CC_AGENT_ALIASES[spec]);
    if (key === "skill") {
      const bare = spec.replace(/(?::\*| \*)$/, "");
      names.push(bare, bare.slice(bare.lastIndexOf(":") + 1));
    }
    const out = [...new Set(names)].filter(Boolean);
    if (out.length > 1) notes.push(`emitted for the name as given and as OC may spell it (${out.slice(1).join(", ")})`);
    return out.map((n) => pat(n));
  }
  // No per-pattern OC form (OC's grep/glob/lsp patterns are not CC's, websearch/todowrite take none).
  if (kind === "allow") fail(`OC's ${key} permission has no form for this pattern`);
  notes.push(`OC's ${key} permission has no form for this pattern; the whole key is set to ${kind}, which also covers calls CC's rule does not`);
  return [pat("*")];
}

// -> [{ perm, pattern|null }] (null pattern = a top-level string permission)
function translate(rule, kind, ctx, notes) {
  if (typeof rule !== "string") fail("not a string rule");
  const m = /^([^()]+)(?:\((.*)\))?$/s.exec(rule.trim());
  if (!m) fail("unparseable rule");
  const tool = m[1].trim();
  const spec = m[2];
  if (tool === "Bash") {
    if (spec === undefined) return [{ perm: "bash", pattern: "*" }];
    if (!spec.trim()) fail("empty Bash pattern");
    return [{ perm: "bash", pattern: spec.endsWith(":*") ? `${spec.slice(0, -2)} *` : spec }];
  }
  const paths = (perm) => {
    const forms = pathForms(spec, kind, ctx, notes);
    return forms.map((p) => ({ perm, pattern: p, ...(forms.action ? { action: forms.action } : {}) }));
  };
  if (tool === "Read") return paths("read");
  if (tool === "Edit" || tool === "Write" || tool === "MultiEdit" || tool === "NotebookEdit") return paths("edit");
  if (tool === "WebFetch") {
    // OC's webfetch permission is a bare action (schema); per-URL rules cannot be expressed.
    if (spec === undefined || /^domain:\s*\*\s*$/.test(spec)) return [{ perm: "webfetch", pattern: null }];
    const why = "OC's webfetch permission takes no per-URL patterns (OC v1.19.0 schema: webfetch is a bare action)";
    if (kind === "allow") fail(why);
    // R35 fail-safe: a domain deny/ask must not fall to OC's "*":"allow". Every fetch asks
    // (a stricter baseline is kept); the lost domain precision is still reported.
    notes.push(`${why}; webfetch is set to ask for every URL instead`);
    return [{ perm: "webfetch", pattern: null, action: "ask" }];
  }
  if (tool.startsWith("mcp__")) {
    return mcpKeys(tool, spec, kind, ctx, notes).map(({ key, action }) => ({ perm: key, pattern: null, ...(action ? { action } : {}) }));
  }
  if (Object.hasOwn(TOOL_KEY, tool)) return toolKey(TOOL_KEY[tool], tool, spec, kind, notes);
  fail("no OC permission translation for this tool");
}

const toObj = (v) => (typeof v === "string" ? { "*": v } : isObj(v) ? v : {});

function layerObject(baseVal, cc, forceStar, defaultAsks = []) {
  const base = toObj(baseVal);
  const own = (k) => Object.hasOwn(base, k);
  const ccStar = cc.get("*");
  const baseStar = own("*") ? base["*"] : undefined;
  const out = {};
  if (ccStar === undefined || ccStar === "allow") {
    let v = baseStar;
    if (ccStar) v = v === undefined ? ccStar : stricter(v, ccStar);
    if (v === undefined && forceStar) v = "ask";
    if (v !== undefined) out["*"] = v;
  }
  // R49 per-name defaults (skill): right after the catch-all, so every CC or baseline key beats them.
  for (const k of defaultAsks) if (!cc.has(k) && !own(k)) out[k] = "ask";
  const add = (want) => {
    for (const [k, a] of cc) if (a === want && k !== "*" && !own(k)) out[k] = a;
  };
  add("allow");
  if (ccStar === "ask") out["*"] = baseStar === undefined ? "ask" : stricter(baseStar, "ask");
  add("ask");
  for (const [k, v] of Object.entries(base)) if (k !== "*") out[k] = cc.has(k) ? stricter(v, cc.get(k)) : v;
  add("deny");
  if (ccStar === "deny") out["*"] = "deny";
  return out;
}

// toOcPermission(perms, baseline, { home, worktree, mcpServers?, skillAsks? }) -> { permission, unknown }
//   perms: merged CC permissions { allow, ask, deny }. baseline: opencode.json `permission`
//   (never mutated; no baseline key is removed). mcpServers (optional): known server names,
//   used to detect server-prefix collisions. skillAsks (optional): names of the skills CC would
//   prompt for (skills.js promptingSkills). unknown: [{ where, key, note }], names only.
export function toOcPermission(perms, baseline, { home, worktree, mcpServers, skillAsks } = {}) {
  const unknown = [];
  const ctx = { home, worktree, mcpServers };
  const objs = new Map(); // perm -> Map(pattern -> action)
  const strs = new Map(); // perm -> { action, rules } (top-level string permissions)
  for (const kind of KINDS) {
    const list = isObj(perms) && Array.isArray(perms[kind]) ? perms[kind] : [];
    for (const rule of list) {
      const notes = [];
      let emits;
      try {
        emits = translate(rule, kind, ctx, notes);
      } catch (e) {
        if (!(e instanceof Untranslatable)) throw e;
        unknown.push({ where: `permissions.${kind}`, key: String(rule), note: `not translated to OC: ${e.message}` });
        continue;
      }
      for (const n of notes) unknown.push({ where: `permissions.${kind}`, key: String(rule), note: `partly translated: ${n}` });
      for (const { perm, pattern, action } of emits) {
        if (pattern === null) {
          const s = strs.get(perm);
          const act = action || kind;
          strs.set(perm, { action: s ? stricter(s.action, act) : act, rules: [...(s ? s.rules : []), `permissions.${kind}\u0000${rule}`] });
        } else {
          if (!objs.has(perm)) objs.set(perm, new Map());
          const m = objs.get(perm);
          const act = action || kind;
          m.set(pattern, m.has(pattern) ? stricter(m.get(pattern), act) : act);
        }
      }
    }
  }
  for (const k of ASK_STAR) if (!objs.has(k)) objs.set(k, new Map());

  const base = typeof baseline === "string" ? { "*": baseline } : isObj(baseline) ? baseline : {};
  // R49: the skills CC would prompt for ask, unless the baseline sets skill outright (a bare action
  // or a "*"), as for every other default; a CC or baseline key for the name wins in layerObject.
  const bSkill = base.skill;
  const skillDefaults = Array.isArray(skillAsks) && !(typeof bSkill === "string" || (isObj(bSkill) && Object.hasOwn(bSkill, "*"))) ? [...new Set(skillAsks.filter((n) => typeof n === "string" && n))] : [];
  if (skillDefaults.length && !objs.has("skill")) objs.set("skill", new Map());
  // R45: bare-action keys neither side sets ask.
  for (const k of ASK_STRING) if (!strs.has(k) && !Object.hasOwn(base, k)) strs.set(k, { action: "ask", rules: [] });
  // R45: every configured MCP server's uncovered tools ask, unless either side sets the server key.
  // A key that would also match a default-denied built-in is a deny, so it cannot lift that deny.
  const mcpAsks = {};
  for (const srv of Array.isArray(mcpServers) ? mcpServers : []) {
    const S = sanitizeMcpName(srv);
    const key = `${S}_*`;
    if (!S || Object.hasOwn(base, key) || strs.has(key) || Object.hasOwn(mcpAsks, key)) continue;
    const lifted = builtinHits(key).filter((h) => DEFAULT_DENY.includes(h));
    if (lifted.length) {
      unknown.push({ where: "mcp", key: String(srv), note: `partly translated: its uncovered tools are denied, not asked: the OC key ${key} also matches OC's default-denied ${lifted.join(", ")}` });
      mcpAsks[key] = "deny";
    } else mcpAsks[key] = "ask";
  }
  const merged = (perm, baseVal) => {
    if (objs.has(perm)) return layerObject(baseVal, objs.get(perm), ASK_STAR.has(perm), perm === "skill" ? skillDefaults : []);
    if (strs.has(perm)) {
      const a = strs.get(perm).action;
      if (baseVal === undefined) return a;
      if (typeof baseVal === "string") return stricter(baseVal, a);
      if (OC_ACTION_ONLY.includes(perm)) {
        // The baseline already holds a shape OC rejects; never extend it, report the CC rules.
        for (const r of strs.get(perm).rules) {
          const [where, key] = r.split("\u0000");
          unknown.push({ where, key, note: `not translated to OC: the baseline's ${perm} is not a bare action` });
        }
        return isObj(baseVal) ? { ...baseVal } : baseVal;
      }
      if (isObj(baseVal)) return layerObject(baseVal, new Map([["*", a]]), false);
      return a;
    }
    return isObj(baseVal) ? { ...baseVal } : baseVal;
  };
  // Top level, same order: the R45 MCP server asks, new object perms, new allow strings, new ask
  // strings, the baseline, new deny strings (a server-wide MCP `s_*` and a tool `s_t` are ordered
  // like any keys, so a server ask precedes that server's CC allows).
  const permission = {};
  if (Object.hasOwn(base, "*")) permission["*"] = merged("*", base["*"]);
  Object.assign(permission, mcpAsks);
  for (const perm of objs.keys()) if (!Object.hasOwn(base, perm)) permission[perm] = merged(perm, undefined);
  for (const want of ["allow", "ask"]) {
    for (const [perm, s] of strs) if (s.action === want && !Object.hasOwn(base, perm)) permission[perm] = s.action;
  }
  for (const perm of Object.keys(base)) if (perm !== "*") permission[perm] = merged(perm, base[perm]);
  for (const [perm, s] of strs) if (s.action === "deny" && !Object.hasOwn(base, perm)) permission[perm] = s.action;
  return { permission, unknown };
}
