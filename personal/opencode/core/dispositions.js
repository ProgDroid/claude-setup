import fs from "node:fs";
import { createRequire } from "node:module";
import { log } from "./log.js";
import { ocPaths } from "./paths.js";

const require = createRequire(import.meta.url);
export const RULES = require("./dispositions.json").rules;

const key = (r) => `${r.plugin ?? ""}|${r.event ?? ""}|${r.script ?? ""}`;

// Shipped rules plus the optional user-local <OC config dir>/cc-parity-dispositions.json
// (same schema; env CC_PARITY_DISPOSITIONS overrides the path). User rules go first (first match
// wins) and replace a shipped rule with the same plugin+event+script key. A missing file is not an
// error. Malformed JSON or a bad shape: one log line, shipped rules only, and `problem` is set.
// -> { rules, file, problem }
export function loadRules(env = process.env) {
  const file = ocPaths(env).dispositionsFile;
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e?.code === "ENOENT") return { rules: RULES, file, problem: null };
    return fail(file, `unreadable: ${e?.code}`);
  }
  let user;
  try {
    const j = JSON.parse(raw);
    user = j?.rules;
    if (!Array.isArray(user) || !user.every((r) => r && typeof r === "object" && typeof r.disposition === "string")) {
      return fail(file, "expected {\"rules\":[{...,\"disposition\":...}]}");
    }
  } catch (e) {
    return fail(file, `unparseable JSON: ${e.message}`);
  }
  const mine = new Set(user.map(key));
  return { rules: [...user, ...RULES.filter((r) => !mine.has(key(r)))], file, problem: null };
}

function fail(file, why) {
  const note = `user dispositions file ignored (${why}); shipped rules only`;
  log(`${file}: ${note}`);
  return { rules: RULES, file, problem: note };
}

// Whole tokens of a command, quotes stripped, reduced to a basename with a trailing
// .exe removed ("C:\\x\\serena-hooks.exe" -> "serena-hooks").
export function scriptNames(command) {
  const names = new Set();
  for (const tok of String(command ?? "").split(/\s+/)) {
    const t = tok.replace(/^["']+|["']+$/g, "");
    if (!t) continue;
    const base = t.split(/[\\/]/).pop().replace(/\.exe$/i, "");
    if (base) names.add(base);
  }
  return names;
}

function ruleMatches(rule, entry, names) {
  if (rule.plugin !== undefined && entry.origin !== `plugin:${rule.plugin}`) return false;
  if (rule.event !== undefined && entry.event !== rule.event) return false;
  if (rule.script !== undefined && !names.has(rule.script)) return false;
  return true;
}

// -> { disposition: "bridge"|"degraded"|"skip"|"cc-only", reason, classified }
// `rules` defaults to the shipped set; pass loadRules().rules to include the user's file.
export function dispositionFor(entry, rules = RULES) {
  const names = scriptNames(entry?.command);
  for (const r of rules) {
    if (ruleMatches(r, entry ?? {}, names)) return { disposition: r.disposition, reason: r.reason, classified: true };
  }
  return { disposition: "bridge", reason: "unclassified: runs with CC semantics until classified", classified: false };
}
