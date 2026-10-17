import crypto from "node:crypto";
import { pluginHookSources } from "./pluginhooks.js";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

const FIELDS = ["type", "command", "args", "timeout", "shell", "async", "asyncRewake", "rewakeMessage", "rewakeSummary", "if", "onFailure", "statusMessage"];

export function hookId({ origin, event, matcher, command, args, if: ifExpr }) {
  const s = [origin, event, matcher ?? "", command ?? "", JSON.stringify(args ?? null), ifExpr ?? ""].join("\u0000");
  return crypto.createHash("sha1").update(s).digest("hex").slice(0, 12);
}

function* walk(hooksObj) {
  if (!isObj(hooksObj)) return;
  for (const [event, groups] of Object.entries(hooksObj)) {
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      if (!isObj(g) || !Array.isArray(g.hooks)) continue;
      for (const h of g.hooks) if (isObj(h)) yield { event, group: g, handler: h };
    }
  }
}

function entryFrom({ event, group, handler }, origin, pluginRoot) {
  const e = { origin: origin ?? handler.origin ?? group.origin, event, matcher: group.matcher };
  for (const k of FIELDS) if (handler[k] !== undefined) e[k] = handler[k];
  if (pluginRoot !== undefined) e.pluginRoot = pluginRoot;
  e.id = hookId(e);
  return e;
}

// merged.hooks (settings; groups and handlers carry their own origin) + every existing
// enabled plugin's hooks via the shared reader. Identical settings handlers collapse
// (lowest scope wins, since settings arrive lowest -> highest); plugin copies never do.
export function collectHooks({ merged, plugins } = {}) {
  const out = [];
  const settingsSeen = new Set();
  for (const item of walk(merged?.hooks)) {
    const e = entryFrom(item);
    const key = [e.event, e.matcher ?? "", e.command ?? "", JSON.stringify(e.args ?? null), e.if ?? "", e.type ?? ""].join("\u0000");
    if (settingsSeen.has(key)) continue;
    settingsSeen.add(key);
    out.push(e);
  }
  for (const p of Array.isArray(plugins) ? plugins : []) {
    if (!p || !p.installPath || p.exists === false) continue;
    for (const src of pluginHookSources(p.installPath)) {
      const hooksObj = src.kind === "file" ? src.data.hooks : src.data;
      for (const item of walk(hooksObj)) out.push(entryFrom(item, `plugin:${p.key}`, p.installPath));
    }
  }
  return out;
}

// CC matcher: "*", "" or absent = all. Only [A-Za-z0-9_\- ,|] = exact name or |-list.
// Anything else = unanchored RegExp.test (so "mcp__serena__*" is a regex, as in CC).
export function matches(matcher, value) {
  if (matcher === undefined || matcher === null || matcher === "" || matcher === "*") return true;
  const m = String(matcher);
  if (/^[A-Za-z0-9_\- ,|]+$/.test(m)) {
    return m.split(/[|,]/).map((s) => s.trim()).filter(Boolean).includes(String(value));
  }
  try {
    return new RegExp(m).test(String(value));
  } catch {
    return false;
  }
}

// ifAllows FAILS OPEN. A false "allows" only spawns a hook; a false "denies" silently skips a
// guard. So it returns false only when it can PROVE the call does not match: a different tool
// name, or a Bash command it parsed completely whose every segment fails the pattern.
// Anything it cannot parse or resolve returns true (CC does the same: "can't determine which
// commands the Bash input runs -> runs your hook regardless of the pattern").

const CONTROL_WORDS = new Set(["do", "then", "else", "elif", "if", "while", "until", "!", "&&", "||"]);

// Split a shell command into compound segments on && || ; | |& & newlines, ( ) and standalone
// { }, quote-aware, not splitting the & of a redirect (2>&1, &>). Returns null when the command
// cannot be parsed completely (unterminated quote, $( or backtick, dangling && / ||).
function bashSegments(cmd) {
  const segs = [];
  let cur = "";
  let q = null;
  let lastOp = null; // last operator seen with nothing after it yet
  const push = (op) => {
    if (cur.trim()) segs.push(cur.trim());
    cur = "";
    lastOp = op;
  };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (q) {
      if (c === "\\" && q === '"') {
        cur += c + (cmd[++i] ?? "");
        continue;
      }
      if (q === '"' && (c === "`" || (c === "$" && cmd[i + 1] === "("))) return null;
      if (c === q) q = null;
      cur += c;
      continue;
    }
    if (c === "`" || (c === "$" && cmd[i + 1] === "(")) return null;
    if (c === "\\") {
      cur += c + (cmd[++i] ?? ""); // escaped char is literal, never an operator
      continue;
    }
    if (c === "'" || c === '"') {
      q = c;
      cur += c;
      lastOp = null;
    } else if (c === "\n" || c === ";" || c === "(" || c === ")") push(null);
    else if ((c === "{" || c === "}") && (i === 0 || /\s/.test(cmd[i - 1]) || cmd[i - 1] === ";") && (i + 1 >= cmd.length || /[\s;]/.test(cmd[i + 1]))) push(null);
    else if (c === "&") {
      const prev = cmd[i - 1];
      const next = cmd[i + 1];
      if (prev === ">" || prev === "<" || next === ">") cur += c; // redirect
      else if (next === "&") {
        i++;
        push("&&");
      } else push(null);
    } else if (c === "|") {
      if (cmd[i + 1] === "|") {
        i++;
        push("||");
      } else if (cmd[i + 1] === "&") {
        i++;
        push(null);
      } else push(null);
    } else {
      cur += c;
      if (!/\s/.test(c)) lastOp = null;
    }
  }
  if (q) return null;
  if (lastOp) return null; // dangling && / ||
  push(null);
  return segs;
}

// Documented wrappers CC strips before matching. argFlags take a following argument;
// positional = number of leading positional args (timeout's DURATION).
const WRAPPERS = {
  timeout: { argFlags: ["-k", "-s", "--kill-after", "--signal"], positional: 1 },
  time: { argFlags: [], positional: 0 },
  nice: { argFlags: ["-n", "--adjustment"], positional: 0 },
  nohup: { argFlags: [], positional: 0 },
  stdbuf: { argFlags: ["-i", "-o", "-e"], positional: 0 },
  command: { argFlags: [], positional: 0 },
  builtin: { argFlags: [], positional: 0 },
  noglob: { argFlags: [], positional: 0 },
};

// Peel leading control words, VAR=value assignments and wrappers off a segment.
// Returns every intermediate form (original first), so a rule can match any layer.
// Quote-aware whitespace tokenizer: a quoted value or a backslash-escaped space stays in one
// token. Returns tokens with their start offsets, and the text with runs of unquoted
// whitespace collapsed to one space ("git  commit" -> "git commit"). Exported for v1/plugin.js
// hookName (a hook command whose quoted path holds a space).
export function tokenize(text) {
  const toks = [];
  let out = "";
  let cur = null;
  let q = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      out += c;
      cur.t += c;
      if (c === "\\" && q === '"' && i + 1 < text.length) {
        out += text[++i];
        cur.t += text[i];
      } else if (c === q) q = null;
      continue;
    }
    if (/\s/.test(c)) {
      cur = null;
      if (out && !out.endsWith(" ")) out += " ";
      continue;
    }
    if (!cur) {
      cur = { t: "", at: out.length };
      toks.push(cur);
    }
    out += c;
    cur.t += c;
    if (c === "\\" && i + 1 < text.length) {
      out += text[++i];
      cur.t += text[i];
    } else if (c === "'" || c === '"') q = c;
  }
  return { toks, text: out.trimEnd() };
}

function peel(segment) {
  const norm = tokenize(segment).text;
  const forms = [norm];
  let rest = norm;
  for (let guard = 0; guard < 20; guard++) {
    const toks = tokenize(rest).toks;
    if (!toks.length) break;
    let n = 0;
    const first = toks[0].t;
    if (CONTROL_WORDS.has(first) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(first)) n = 1;
    else if (Object.hasOwn(WRAPPERS, first)) {
      const w = WRAPPERS[first];
      n = 1;
      while (n < toks.length && toks[n].t.startsWith("-") && toks[n].t !== "--") {
        n += w.argFlags.includes(toks[n].t) ? 2 : 1;
      }
      if (n < toks.length && toks[n].t === "--") n++;
      n += w.positional;
    }
    if (!n) break;
    rest = n >= toks.length ? "" : rest.slice(toks[n].at);
    if (!rest) break;
    forms.push(rest);
  }
  return forms;
}

const escRe = (s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&");

function bashSpecMatches(spec, segment) {
  let s = spec.trim();
  if (s.endsWith(":*")) s = s.slice(0, -2) + " *"; // legacy prefix form == "prefix *"
  if (!s.includes("*")) return segment === s;
  // Trailing " *" is a word boundary: "ls *" matches "ls" and "ls -la", never "lsof".
  // The bare-command match holds only when that trailing * is the pattern's only wildcard.
  const trailing = s.endsWith(" *");
  const body = trailing ? s.slice(0, -2) : s;
  const re = escRe(body).replace(/\*/g, ".*");
  const tail = trailing ? (body.includes("*") ? "\\s.*" : "(?:\\s.*)?") : "";
  return new RegExp(`^${re}${tail}$`, "s").test(segment);
}

// gitignore-ish glob over a path: ** crosses /, * and ? do not. Backslashes normalised.
// A relative pattern matches at any depth: CC >= 2.1.214 anchors it to the cwd, so this
// over-matches (the safe direction) until the runner can supply a cwd.
function globToRegex(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        i++;
        if (glob[i + 1] === "/") {
          i++;
          re += "(?:.*/)?";
        } else re += ".*";
      } else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else re += escRe(c);
  }
  return re;
}

// true/false when decidable, undefined when not (caller fails open).
function pathSpecMatches(spec, filePath) {
  const p = String(filePath).replace(/\\/g, "/");
  const g = spec.replace(/\\/g, "/");
  // Anchors whose root this module cannot resolve: ~/ (home), // (filesystem root, drive
  // normalised to /c/), and a leading / (settings source or project root).
  if (g.startsWith("~") || g.startsWith("/")) return undefined;
  const re = globToRegex(g);
  const absolute = /^[A-Za-z]:\//.test(g);
  return new RegExp(absolute ? `^${re}$` : `(?:^|/)${re}$`).test(p);
}

const PATH_FIELDS = ["file_path", "notebook_path", "path"];

// Evaluate a CC permission-rule `if` expression. Only defined for tool events.
export function ifAllows(ifExpr, ccCall) {
  try {
    if (ifExpr === undefined || ifExpr === null || String(ifExpr).trim() === "") return true;
    const expr = String(ifExpr).trim();
    const m = /^([A-Za-z0-9_*]+)\s*(?:\(([\s\S]*)\))?$/.exec(expr);
    if (!m) return true; // not understood -> spawn
    const [, tool, spec] = m;
    const name = ccCall?.tool_name;
    if (tool.includes("*")) {
      // wildcard tool name (mcp__x__*): decidable against the name, never against args
      return new RegExp(`^${escRe(tool).replace(/\*/g, ".*")}$`).test(String(name ?? "")) || typeof name !== "string";
    }
    if (typeof name !== "string") return true;
    if (name !== tool) return false; // the one provable non-match
    if (spec === undefined) return true;
    const input = ccCall.tool_input ?? {};
    if (tool === "Bash") {
      if (typeof input.command !== "string") return true;
      const segs = bashSegments(input.command);
      if (segs === null) return true; // cannot parse the command
      for (const seg of segs) {
        for (const form of peel(seg)) {
          if (form.startsWith("$")) return true; // command word is a variable: undeterminable
          if (bashSpecMatches(spec, form)) return true;
        }
      }
      return false;
    }
    const fp = PATH_FIELDS.map((k) => input[k]).find((v) => typeof v === "string");
    if (fp === undefined) return true; // tool has no path field (WebFetch(domain:..), Agent(..))
    const r = pathSpecMatches(spec, fp);
    return r === undefined ? true : r;
  } catch {
    return true;
  }
}
