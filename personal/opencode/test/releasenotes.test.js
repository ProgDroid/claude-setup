import { test, expect } from "bun:test";
import { HANDLED } from "../core/enumerate.js";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseChangelog, novelLines, hookDigest, ccVersion, fetchChangelog, knownSet, identifiersIn, cmpVer, semver, CHANGELOG_URL,
} from "../core/releasenotes.js";
import { INPUT_FIELDS, OUTPUT_FIELDS } from "../core/protocol.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const md = fs.readFileSync(path.join(here, "fixtures", "changelog-sample.md"), "utf8");
const entries = parseChangelog(md);
const known = knownSet();

test("parseChangelog keeps file order (newest first) and the bullet lines", () => {
  expect(entries.map((e) => e.version)).toEqual(["2.1.5", "2.1.4", "2.1.3", "2.1.2", "2.1.1"]);
  expect(entries[0].lines).toHaveLength(3);
  expect(entries[0].lines[0]).toStartWith("Added `CLAUDE_CODE_PLANTED_FLAG`");
  expect(entries[3].lines).toEqual(["Fixed a crash in `git` when run from a symlink in a hook", "Improved startup time"]);
});

test("parseChangelog tolerates CRLF, a v prefix, and garbage input", () => {
  const crlf = parseChangelog("# C\r\n\r\n## v1.2.3\r\n- Added `fooBarBaz` here\r\n");
  expect(crlf).toEqual([{ version: "1.2.3", lines: ["Added `fooBarBaz` here"] }]);
  // the whole fixture parses identically with CRLF endings, and no carriage return survives anywhere
  const viaCrlf = parseChangelog(md.replace(/\r?\n/g, "\r\n"));
  expect(viaCrlf).toEqual(entries);
  expect(JSON.stringify(viaCrlf)).not.toContain("\\r");
  expect(novelLines(viaCrlf, "2.1.0", "2.1.5", known)).toEqual(novelLines(entries, "2.1.0", "2.1.5", known));
  expect(parseChangelog("")).toEqual([]);
  expect(parseChangelog(null)).toEqual([]);
  expect(parseChangelog("- orphan bullet before any version")).toEqual([]);
});

test("cmpVer compares numerically, not as strings", () => {
  expect(cmpVer("2.1.10", "2.1.9")).toBeGreaterThan(0);
  expect(cmpVer("2.1.9", "2.1.9")).toBe(0);
  expect(cmpVer("2.0.99", "2.1.0")).toBeLessThan(0);
});

test("range is (fromVer, toVer]: from exclusive, to inclusive", () => {
  const ids = (from, to) => novelLines(entries, from, to, known).map((l) => identifiersIn(l).find((i) => !known.has(i)));
  expect(ids("2.1.0", "2.1.5")).toEqual(["plantedHookField", "PostCompact", "olderPlantedKey"]);
  // from is exclusive: 2.1.4's PostCompact is not shown when from = 2.1.4 ...
  expect(ids("2.1.4", "2.1.5")).toEqual(["plantedHookField"]);
  expect(ids("2.1.1", "2.1.1")).toEqual([]);
  expect(ids("2.1.0", "2.1.1")).toEqual(["olderPlantedKey"]);
  // ... and to is inclusive, anything above it is excluded.
  expect(ids("2.1.3", "2.1.4")).toEqual(["PostCompact"]);
});

test("a hook line with a novel field fires, returned verbatim", () => {
  expect(novelLines(entries, "2.1.4", "2.1.5", known)).toEqual(["Added `plantedHookField` to the input of PreToolUse hooks"]);
});

test("R40: a non-hook line with a novel settings key or env var is silent", () => {
  const all = novelLines(entries, null, null, known).join("\n");
  expect(all).not.toContain("CLAUDE_CODE_PLANTED_FLAG"); // env var line, no hook mention
  expect(all).not.toContain("plantedSettingKey"); // settings key line, no hook mention
  // the same identifiers are novel by shape: only the hook requirement silences them
  expect(identifiersIn("Added `plantedSettingKey` to settings.json").some((i) => !known.has(i))).toBe(true);
  // and the hook mention is case-insensitive
  const upper = [{ version: "9.9.9", lines: ["Added `plantedUpperKey` to HOOK input"] }];
  expect(novelLines(upper, null, null, known)).toHaveLength(1);
});

test("an identifier that is handled, ignored, not-translated or a hook event is not novel", () => {
  // 2.1.4 mentions PreToolUse (hook event) and statusLine (IGNORED.settings); 2.1.3 mentions
  // CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (NOT_TRANSLATED.env) and enabledPlugins (HANDLED.settings),
  // on a line that mentions hooks.
  const lines = novelLines(entries, "2.1.2", "2.1.4", known);
  expect(lines).toEqual(["Added `PostCompact` hook event, raised after compaction"]);
  // with an empty known set the same range returns more (the known-but-hook lines come back)
  expect(novelLines(entries, "2.1.2", "2.1.4", new Set()).length).toBeGreaterThan(lines.length);
});

test("knownSet covers every HANDLED key, ignored, not-translated and hook events", () => {
  for (const k of ["env", "enabledPlugins", "PreToolUse", "PreCompact", "statusLine", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "asyncRewake"]) {
    expect(known.has(k)).toBe(true);
  }
  expect(known.has("plantedSettingKey")).toBe(false);
});

test("lines that only mention plain words or a removed identifier are not returned", () => {
  expect(novelLines(entries, "2.1.3", "2.1.4", known).join("\n")).not.toContain("legacyPlantedHookKey"); // Removed ... line mentions hook
  expect(novelLines(entries, "2.1.1", "2.1.2", known)).toEqual([]); // `git` is a plain word, not an identifier shape
  expect(novelLines(entries, "2.1.4", "2.1.5", known).join("\n")).not.toContain("flickering"); // `prompt`/`model`
});

test("hookDigest gives one compact item, or null when nothing fires", () => {
  expect(hookDigest(entries, "2.1.0", "2.1.5", known)).toBe(
    "3 hook-related changelog lines mention identifiers the adapter doesn't know; top 3: plantedHookField, PostCompact, olderPlantedKey");
  expect(hookDigest(entries, "2.1.2", "2.1.3", known)).toBeNull();
  const many = [{ version: "3.0.0", lines: ["a `aaBb` hook", "b `ccDd` hook", "c `eeFf` hook", "d `ggHh` hook", "e `aaBb` hook"] }];
  expect(hookDigest(many, "2.9.9", "3.0.0", known)).toBe("5 hook-related changelog lines mention identifiers the adapter doesn't know; top 3: aaBb, ccDd, eeFf");
});


test("identifiersIn extracts only backticked tokens of an identifier shape", () => {
  expect(identifiersIn("Added `fooBar`, `FooBar`, `FOO_BAR`, `CLAUDE_X`, `git`, `--flag`, `a b` and bare fooBarBaz")).toEqual(["fooBar", "FooBar", "CLAUDE_X"]);
});

test("novelLines with no bounds scans everything", () => {
  expect(novelLines(entries, null, null, known)).toHaveLength(3);
});

test("fetchChangelog returns the text on success and uses the injected URL", async () => {
  let seen;
  const fakeFetch = async (url) => { seen = url; return { ok: true, text: async () => md }; };
  expect(await fetchChangelog(fakeFetch, "http://example.invalid/x.md")).toBe(md);
  expect(seen).toBe("http://example.invalid/x.md");
  await fetchChangelog(fakeFetch);
  expect(seen).toBe(CHANGELOG_URL);
});

test("fetchChangelog returns null on throw, non-ok, empty body and timeout, and never rejects", async () => {
  expect(await fetchChangelog(async () => { throw new Error("offline"); })).toBeNull();
  expect(await fetchChangelog(async () => ({ ok: false, status: 404, text: async () => "nope" }))).toBeNull();
  expect(await fetchChangelog(async () => ({ ok: true, text: async () => "" }))).toBeNull();
  expect(await fetchChangelog(async () => ({ ok: true, text: async () => { throw new Error("body"); } }))).toBeNull();
  const hang = (url, { signal }) => new Promise((_, rej) => signal.addEventListener("abort", () => rej(new Error("aborted"))));
  expect(await fetchChangelog(hang, "http://x.invalid", 30)).toBeNull();
});

test("ccVersion parses the first semver from an injected spawn, with a 3 s timeout", () => {
  let args;
  const spawn = (cmd, a, opts) => { args = { cmd, a, opts }; return { stdout: "2.1.300 (Claude Code)\n" }; };
  expect(ccVersion(spawn)).toBe("2.1.300");
  expect(args.cmd).toBe("claude");
  expect(args.a).toEqual(["--version"]);
  expect(args.opts.timeout).toBe(3000);
});

test("ccVersion returns null on garbage output, a null result, or a throw", () => {
  expect(ccVersion(() => ({ stdout: "command not found" }))).toBeNull();
  expect(ccVersion(() => ({ stdout: null, error: new Error("ENOENT") }))).toBeNull();
  expect(ccVersion(() => null)).toBeNull();
  expect(ccVersion(() => { throw new Error("boom"); })).toBeNull();
});

test("I1: a hook line with a novel single-word event or snake_case field fires", () => {
  const e = [{ version: "3.0.0", lines: [
    "Added `Elicitation` hook event, raised when an MCP server asks for input",
    "Added `hook_event_name` to the stdin of every hook",
    "Added `Notification` to the list of hook events",
  ] }];
  expect(novelLines(e, "2.9.9", "3.0.0", known)).toHaveLength(2);
  // hook_event_name is a CC hook stdin field the adapter sends (protocol.js), so it is known
  expect(hookDigest(e, "2.9.9", "3.0.0", known)).toContain("top 3: Elicitation, Notification");
  const k2 = new Set([...known].filter((x) => x !== "hook_event_name"));
  expect(hookDigest(e, "2.9.9", "3.0.0", k2)).toContain("top 3: Elicitation, hook_event_name, Notification");
});

test("Task 9 fold-in: knownSet holds every CC hook stdin field and output key from protocol.js", () => {
  for (const f of [...INPUT_FIELDS, ...OUTPUT_FIELDS]) expect(known.has(f)).toBe(true);
  for (const f of ["tool_input", "tool_name", "session_id", "hook_event_name", "tool_response", "transcript_path", "permission_mode", "cwd", "tool_use_id", "stop_hook_active"]) {
    expect(known.has(f)).toBe(true);
  }
  // a stdin-field line is silent; a genuinely new field on the same line shape still fires
  const e = [{ version: "3.0.0", lines: ["Hooks now receive `tool_use_id` and `permission_mode`", "Hooks now receive `agent_transcript_id`"] }];
  expect(novelLines(e, "2.9.9", "3.0.0", known)).toEqual(["Hooks now receive `agent_transcript_id`"]);
});

test("I1: known single-word and snake_case identifiers stay silent, and the shapes need a hook mention", () => {
  const e = [{ version: "3.0.0", lines: ["Fixed `PreToolUse` hooks reading `tool_input`", "Added `Elicitation` hook event"] }];
  const k = new Set([...known, "tool_input", "Elicitation"]);
  expect(novelLines(e, "2.9.9", "3.0.0", k)).toEqual([]);
  // without a hook mention neither new shape applies
  const plain = [{ version: "3.0.0", lines: ["Added `Elicitation` support and `some_field` to output"] }];
  expect(novelLines(plain, "2.9.9", "3.0.0", known)).toEqual([]);
  // and env-var/camel shapes still work on hook lines only for novel ids
  expect(identifiersIn("a hook with `Notification` and `tool_input`")).toEqual([]);
});

test("I2: hookDigest never scans an open or inverted range", () => {
  expect(hookDigest(entries, null, null, known)).toBeNull();
  expect(hookDigest(entries, null, "2.1.5", known)).toBeNull(); // first run, nothing stored
  expect(hookDigest(entries, "2.1.0", null, known)).toBeNull(); // ccVersion failed
  expect(hookDigest(entries, "2.1.5", "2.1.0", known)).toBeNull(); // downgrade
  expect(hookDigest(entries, "2.1.5", "2.1.5", known)).toBeNull(); // no change
  expect(hookDigest(entries, "nonsense", "2.1.5", known)).toBeNull();
  expect(hookDigest(entries, "2.1.0", "2.1.5 (Claude Code)", known)).toBeNull(); // not a bare semver
  expect(hookDigest(entries, "2.1.0", "2.1.5", known)).not.toBeNull(); // control: a closed range works
});

test("I3: headings that are not exactly x.y.z attribute correctly or drop their bullets", () => {
  const md2 = [
    "## Unreleased", "- Added `droppedUnreleasedKey` hook", "",
    "## 2.2.0", "- Added `keepA` hook", "",
    "## Unreleased notes", "- Added `droppedAfterTwoTwo` hook", "",
    "## [2.1.9] - 2026-01-02", "- Added `keepBracket` hook", "",
    "## 2.1.8 (2026-01-01)", "- Added `keepDate` hook", "",
    "## v2.1.7-beta.1", "- Added `keepPre` hook", "",
    "### 2.1.6", "- Added `stillOlder` hook", "",
    "## Older stuff", "- Added `droppedOlder` hook",
  ].join("\n");
  const p = parseChangelog(md2);
  expect(p.map((x) => x.version)).toEqual(["2.2.0", "2.1.9", "2.1.8", "2.1.7"]);
  expect(p.map((x) => x.lines.length)).toEqual([1, 1, 1, 2]); // the ### bullet joins 2.1.7
  const all = JSON.stringify(p);
  for (const bad of ["droppedUnreleasedKey", "droppedAfterTwoTwo", "droppedOlder"]) expect(all).not.toContain(bad);
  // a ### heading is not a release heading and does not end the entry
  expect(all).toContain("stillOlder");
});

test("semver normalises or rejects", () => {
  expect(semver("2.1.300 (Claude Code)")).toBe("2.1.300");
  expect(semver("nope")).toBeNull();
  expect(semver(null)).toBeNull();
  // a decorated stored version bounds the range instead of opening it
  expect(novelLines(entries, "2.1.4 (Claude Code)", "2.1.5", known)).toHaveLength(1);
});

test("knownSet reads HANDLED live (a key added at test time silences the detector)", () => {
  const e = [{ version: "3.0.0", lines: ["Added `liveAddedField` to hook input"] }];
  expect(novelLines(e, "2.9.9", "3.0.0", knownSet())).toHaveLength(1);
  HANDLED.hookFields.push("liveAddedField");
  try {
    expect(knownSet().has("liveAddedField")).toBe(true);
    expect(novelLines(e, "2.9.9", "3.0.0", knownSet())).toEqual([]);
  } finally {
    HANDLED.hookFields.pop();
  }
  expect(knownSet().has("liveAddedField")).toBe(false);
});

test("CC tool names and mcp__ names are known: a hook line naming only them is silent", () => {
  for (const t of ["Bash", "Edit", "Write", "Read", "Task"]) expect(known.has(t)).toBe(true);
  const quiet = [{ version: "3.0.0", lines: [
    "Fixed `PreToolUse` hooks not firing for `Bash` and `Edit` calls",
    "Fixed `PostToolUse` hooks for `Write`, `Read` and `mcp__github__create_issue`",
  ] }];
  expect(novelLines(quiet, "2.9.9", "3.0.0", known)).toEqual([]);
  expect(hookDigest(quiet, "2.9.9", "3.0.0", known)).toBeNull();
  // control: the same lines plus a novel field still fire, and the tool names do not crowd the digest
  const loud = [{ version: "3.0.0", lines: [...quiet[0].lines, "Added `permission_suggestions` to `Bash` hook input"] }];
  expect(novelLines(loud, "2.9.9", "3.0.0", known)).toHaveLength(1);
  expect(hookDigest(loud, "2.9.9", "3.0.0", known)).toContain("top 3: permission_suggestions");
  expect(hookDigest(loud, "2.9.9", "3.0.0", known)).not.toContain("Bash");
});
