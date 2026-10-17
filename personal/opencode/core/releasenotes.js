import { spawnSync } from "node:child_process";
import { HANDLED, IGNORED, NOT_TRANSLATED } from "./enumerate.js";
import { OC_TO_CC } from "./toolmap.js";
import { INPUT_FIELDS, OUTPUT_FIELDS } from "./protocol.js";

export const CHANGELOG_URL = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md";

// Identifier shapes, tightened from the loose first cut (/^[A-Z][A-Za-z]+$/, /^[a-z][A-Za-z]+$/,
// /^[A-Z][A-Z0-9_]+$/) after measuring on the real changelog; see README. In order:
//  - hook-event-like: two or more capitalised words (PermissionRequest, WorktreeCreate)
//  - settings-key / hook-field-like: lowerCamelCase with an interior capital (forceLoginMethod)
//  - env var: CC-owned prefix (CLAUDE_, ANTHROPIC_)
export const SHAPES = [/^[A-Z][a-z]+([A-Z][a-z]+)+$/, /^[a-z]+([A-Z][a-z0-9]*)+$/, /^(CLAUDE|ANTHROPIC)_[A-Z0-9_]+$/];

// A line opening with Removed/Deprecated mentions an identifier going away, not arriving.
const GOING_AWAY = /^(Removed|Deprecated)\b/;
// R40: only the hook protocol can change behaviour with no config footprint; settings keys and env
// vars are reported by enumerate() the first time the user sets them.
const MENTIONS_HOOK = /hook/i;

// Everything the adapter already accounts for: handled, ignored, decided-not-translated.
export function knownSet() {
  const known = new Set();
  for (const v of Object.values(HANDLED)) if (Array.isArray(v)) v.forEach((k) => known.add(k));
  for (const table of [IGNORED, NOT_TRANSLATED]) {
    for (const [name, cat] of Object.entries(table)) {
      // An ignored hook field is one CC does not read TODAY; a release that starts reading it is
      // exactly what this detector exists to catch, so it stays novel.
      if (table === IGNORED && name === "hookFields") continue;
      if (cat && typeof cat === "object") Object.keys(cat).forEach((k) => known.add(k));
    }
  }
  HANDLED.hookEvents.forEach((e) => known.add(e));
  // CC tool names (Bash, Edit, ...): nearly every hook line names one, and the tool map owns them.
  for (const v of Object.values(OC_TO_CC).flat()) if (typeof v === "string") known.add(v);
  // CC hook stdin fields the adapter sends, and the output keys it reads (protocol.js owns both).
  for (const f of [...INPUT_FIELDS, ...OUTPUT_FIELDS]) known.add(f);
  return known;
}

// A level-2 heading. The version is a semver at the start of its text ("## 2.1.0", "## [2.1.0] - date",
// "## v2.1.0 (date)", "## 2.1.0-beta.1" all yield 2.1.0). Any other level-2 heading ("## Unreleased")
// ends the current entry, so the bullets under it are dropped instead of joining the previous release.
const HEADING = /^##(?!#)\s/;
const HEADING_VER = /^##\s+\[?v?(\d+\.\d+\.\d+)/;
const SEMVER = /^\d+\.\d+\.\d+$/;

// A bare x.y.z, or null. "2.1.300 (Claude Code)" is normalised; anything without a semver is null.
export function semver(v) {
  const m = /(\d+\.\d+\.\d+)/.exec(String(v ?? ""));
  return m ? m[1] : null;
}

// Newest first, as the file is written.
export function parseChangelog(md) {
  const entries = [];
  let cur = null;
  for (const raw of String(md ?? "").split(/\r?\n/)) {
    if (HEADING.test(raw)) {
      const m = HEADING_VER.exec(raw);
      cur = m ? { version: m[1], lines: [] } : null;
      if (cur) entries.push(cur);
    } else if (cur && /^\s*[-*]\s+/.test(raw)) {
      cur.lines.push(raw.replace(/^\s*[-*]\s+/, "").trim());
    }
  }
  return entries;
}

export function cmpVer(a, b) {
  const pa = a.split(".").map(Number), pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) - (pb[i] ?? 0);
  return 0;
}

export function identifiersIn(line) {
  const out = [];
  for (const m of line.matchAll(/`([^`\s]+)`/g)) if (SHAPES.some((re) => re.test(m[1]))) out.push(m[1]);
  return out;
}

// Extra shapes accepted only on lines that already mention a hook (hook events and hook
// input/output fields are not always multi-word camelCase): a single-word PascalCase event
// (Notification, Elicitation) and a snake_case field (hook_event_name, tool_input).
export const HOOK_SHAPES = [/^[A-Z][a-z]+$/, /^[a-z]+(_[a-z0-9]+)+$/];

function hookIdentifiersIn(line) {
  const out = identifiersIn(line);
  for (const m of line.matchAll(/`([^`\s]+)`/g)) if (!out.includes(m[1]) && HOOK_SHAPES.some((re) => re.test(m[1]))) out.push(m[1]);
  return out;
}

// Releases in (fromVer, toVer]: strictly after the version seen at the last start, up to the current one.
// A null (or non-semver) bound is open on that side; hookDigest refuses open ranges.
export function novelLines(entries, fromVer, toVer, known) {
  const from = semver(fromVer), to = semver(toVer);
  const out = [];
  for (const e of entries) {
    if (from && cmpVer(e.version, from) <= 0) continue;
    if (to && cmpVer(e.version, to) > 0) continue;
    for (const line of e.lines) {
      if (!GOING_AWAY.test(line) && MENTIONS_HOOK.test(line) && hookIdentifiersIn(line).some((id) => !isKnown(known, id))) out.push(line);
    }
  }
  return out;
}

export function ccVersion(spawn = spawnSync) {
  try {
    const r = spawn("claude", ["--version"], { encoding: "utf8", timeout: 3000, windowsHide: true, shell: process.platform === "win32" });
    const m = /(\d+\.\d+\.\d+)/.exec(String(r?.stdout ?? ""));
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

export async function fetchChangelog(fetchFn = globalThis.fetch, url = CHANGELOG_URL, timeoutMs = 4000) {
  try {
    const res = await fetchFn(url, { signal: AbortSignal.timeout(timeoutMs) });
    if (!res?.ok) return null;
    const text = await res.text();
    return typeof text === "string" && text.length ? text : null;
  } catch {
    return null;
  }
}

// One compact parity item per CC-version change (R40 fallback: the gate failed, so never list every line).
// Needs a closed range: a missing or non-semver bound (first run, failed ccVersion) or from >= to
// (downgrade, no change) yields null, never a scan of the whole changelog.
// "top 3" = the first three distinct novel identifiers, MOST RECENT RELEASE FIRST.
export function hookDigest(entries, fromVer, toVer, known) {
  const from = SEMVER.test(String(fromVer)) ? fromVer : null, to = SEMVER.test(String(toVer)) ? toVer : null;
  if (!from || !to || cmpVer(from, to) >= 0) return null;
  const lines = novelLines([...entries].sort((a, b) => cmpVer(b.version, a.version)), from, to, known);
  if (!lines.length) return null;
  const top = [];
  for (const l of lines) {
    const id = hookIdentifiersIn(l).find((i) => !isKnown(known, i));
    if (id && !top.includes(id)) top.push(id);
    if (top.length === 3) break;
  }
  return `${lines.length} hook-related changelog lines mention identifiers the adapter doesn't know; top 3: ${top.join(", ")}`;
}

// `mcp__<server>__<tool>` names are MCP tool names, handled by the tool map's MCP translation.
function isKnown(known, id) {
  return known.has(id) || id.startsWith("mcp__");
}
