import { describe, test, expect } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync } from "node:child_process";
import { OC_TO_CC, OC_INTERNAL, PATCH_BLOCK_REASON, toCcCalls, toCcResponse, applyUpdatedInput, parseApplyPatch } from "../core/toolmap.js";
import { parseApplyPatch as parseDirect, parseApplyPatchFull } from "../core/patch.js";
import { HANDLED, enumerate } from "../core/enumerate.js";

const cwd = path.join(os.tmpdir(), "ccp-tm-work");
const A = (p) => path.resolve(cwd, p);

describe("OC_TO_CC / enumerate wiring (R1, R30)", () => {
  test("covers the brief rows and the other row-11 built-ins", () => {
    expect(OC_TO_CC).toMatchObject({
      bash: "Bash", edit: "Edit", write: "Write", read: "Read", grep: "Grep", glob: "Glob",
      webfetch: "WebFetch", task: "Task", todowrite: "TodoWrite", skill: "Skill",
      websearch: "WebSearch", question: "AskUserQuestion", lsp: "LSP", plan_exit: "ExitPlanMode",
    });
    expect(Object.hasOwn(OC_TO_CC, "apply_patch")).toBe(true);
  });
  test("HANDLED.ocTools is the tool-map keys plus OC_INTERNAL", () => {
    expect(OC_INTERNAL).toEqual(["invalid", "execute"]);
    expect(HANDLED.ocTools).toEqual([...Object.keys(OC_TO_CC), ...OC_INTERNAL]);
  });
  test("invalid and execute are handled and silent (R39: Code Mode child calls fire the tool hooks)", () => {
    const r = enumerate({ ocTools: ["bash", "websearch", "invalid", "execute", "execute", "serena_x", "brand_new"], mcpServers: ["serena"] });
    expect(r.map((x) => x.key)).toEqual(["brand_new"]);
  });
  test("an unknown tool is still an unknown", () => {
    expect(enumerate({ ocTools: ["brand_new"] }).map((x) => x.key)).toEqual(["brand_new"]);
  });
  test("invalid and execute are never hooked", () => {
    expect(toCcCalls("invalid", {}, cwd, ["invalid"])).toBeNull();
    expect(toCcCalls("execute", {}, cwd, [])).toBeNull();
  });
  test("parseApplyPatch is re-exported from patch.js", () => {
    expect(parseApplyPatch).toBe(parseDirect);
  });
});

describe("toCcCalls: built-ins", () => {
  test("edit -> CC Edit with absolute file_path and snake_case args", () => {
    const r = toCcCalls("edit", { filePath: "src/a.ts", oldString: "x", newString: "y", replaceAll: true }, cwd, []);
    expect(r).toEqual([{ tool_name: "Edit", tool_input: { file_path: A("src/a.ts"), old_string: "x", new_string: "y", replace_all: true } }]);
    expect(path.isAbsolute(r[0].tool_input.file_path)).toBe(true);
  });
  test("an already-absolute filePath is preserved", () => {
    const f = path.join(cwd, "deep", "b.ts");
    expect(toCcCalls("edit", { filePath: f, oldString: "a", newString: "b" }, "/elsewhere", [])[0].tool_input.file_path).toBe(f);
  });
  test("write, read", () => {
    expect(toCcCalls("write", { filePath: "w.txt", content: "hi" }, cwd, [])).toEqual([{ tool_name: "Write", tool_input: { file_path: A("w.txt"), content: "hi" } }]);
    expect(toCcCalls("read", { filePath: "r.txt", offset: 3, limit: 9 }, cwd, [])).toEqual([{ tool_name: "Read", tool_input: { file_path: A("r.txt"), offset: 3, limit: 9 } }]);
    expect(toCcCalls("read", { filePath: "r.txt" }, cwd, [])[0].tool_input).toEqual({ file_path: A("r.txt") });
  });
  test("bash drops workdir from the input and returns no cwd when absent", () => {
    const r = toCcCalls("bash", { command: "ls", timeout: 5000 }, cwd, []);
    expect(r).toEqual([{ tool_name: "Bash", tool_input: { command: "ls", timeout: 5000 } }]);
    expect("cwd" in r[0]).toBe(false);
  });
  test("bash workdir becomes the returned cwd (R6), relative resolved against cwd", () => {
    const abs = path.join(os.tmpdir(), "elsewhere");
    expect(toCcCalls("bash", { command: "ls", workdir: abs }, cwd, [])[0]).toEqual({ tool_name: "Bash", tool_input: { command: "ls" }, cwd: abs });
    expect(toCcCalls("bash", { command: "ls", workdir: "sub" }, cwd, [])[0].cwd).toBe(A("sub"));
    expect(toCcCalls("bash", { command: "ls", workdir: "" }, cwd, [])[0].cwd).toBeUndefined();
  });
  test("grep include -> glob; glob passes through; webfetch adds an empty prompt and drops format", () => {
    expect(toCcCalls("grep", { pattern: "p", path: "d", include: "*.js" }, cwd, [])[0].tool_input).toEqual({ pattern: "p", path: "d", glob: "*.js" });
    expect(toCcCalls("grep", { pattern: "p" }, cwd, [])[0].tool_input).toEqual({ pattern: "p" });
    expect(toCcCalls("glob", { pattern: "*.md", path: "d" }, cwd, [])[0]).toEqual({ tool_name: "Glob", tool_input: { pattern: "*.md", path: "d" } });
    expect(toCcCalls("webfetch", { url: "https://x.test", format: "text", timeout: 3 }, cwd, [])[0]).toEqual({ tool_name: "WebFetch", tool_input: { url: "https://x.test", prompt: "" } });
  });
  test("task keeps description/prompt/subagent_type only", () => {
    expect(toCcCalls("task", { description: "d", prompt: "p", subagent_type: "general", task_id: "t", background: true }, cwd, [])[0]).toEqual({
      tool_name: "Task", tool_input: { description: "d", prompt: "p", subagent_type: "general" },
    });
  });
  test("todowrite, skill and pass-through rows keep args, as a COPY (M6)", () => {
    expect(toCcCalls("todowrite", { todos: [1] }, cwd, [])).toEqual([{ tool_name: "TodoWrite", tool_input: { todos: [1] } }]);
    expect(toCcCalls("skill", { name: "n" }, cwd, [])).toEqual([{ tool_name: "Skill", tool_input: { name: "n" } }]);
    const args = { query: "q" };
    const ws = toCcCalls("websearch", args, cwd, []);
    expect(ws).toEqual([{ tool_name: "WebSearch", tool_input: { query: "q" } }]);
    expect(ws[0].tool_input).not.toBe(args);
    ws[0].tool_input.query = "mutated";
    expect(args.query).toBe("q");
  });
  test("missing / non-object args never throw", () => {
    expect(() => toCcCalls("edit", undefined, cwd, [])).not.toThrow();
    expect(toCcCalls("bash", null, cwd, [])[0].tool_input).toEqual({});
  });
  test("unmapped tool -> null", () => {
    expect(toCcCalls("nope", {}, cwd, [])).toBeNull();
    expect(toCcCalls(undefined, {}, cwd, [])).toBeNull();
    expect(toCcCalls("__proto__", {}, cwd, [])).toBeNull();
  });
});

describe("toCcCalls: MCP names", () => {
  test("known server -> mcp__server__tool, args copied", () => {
    const args = { a: 1 };
    const r = toCcCalls("serena_find_symbol", args, cwd, ["serena"]);
    expect(r).toEqual([{ tool_name: "mcp__serena__find_symbol", tool_input: { a: 1 } }]);
    expect(r[0].tool_input).not.toBe(args);
  });
  test("unknown server -> null", () => {
    expect(toCcCalls("serena_find_symbol", { a: 1 }, cwd, ["other"])).toBeNull();
    expect(toCcCalls("serena_find_symbol", { a: 1 }, cwd, [])).toBeNull();
    expect(toCcCalls("serena_find_symbol", { a: 1 }, cwd, null)).toBeNull();
  });
  test("longest known server prefix wins, in either list order", () => {
    for (const servers of [["my", "my_srv"], ["my_srv", "my"]]) {
      expect(toCcCalls("my_srv_do_it", {}, cwd, servers)[0].tool_name).toBe("mcp__my_srv__do_it");
    }
    expect(toCcCalls("my_other", {}, cwd, ["my", "my_srv"])[0].tool_name).toBe("mcp__my__other");
  });
  test("the emitted server name is sanitized as CC does (I3)", () => {
    expect(toCcCalls("plugin_qmd_qmd_multi_get", {}, cwd, ["plugin:qmd:qmd"])[0].tool_name).toBe("mcp__plugin_qmd_qmd__multi_get");
    expect(toCcCalls("claude_ai_Google_Calendar_list_events", {}, cwd, ["claude.ai Google Calendar"])[0].tool_name).toBe("mcp__claude_ai_Google_Calendar__list_events");
    expect(toCcCalls("my_srv_x", {}, cwd, ["my.srv"])[0].tool_name).toBe("mcp__my_srv__x");
  });
  test("a bare server name with no tool part, or an empty server, is not an MCP call", () => {
    expect(toCcCalls("serena_", {}, cwd, ["serena"])).toBeNull();
    expect(toCcCalls("serena", {}, cwd, ["serena"])).toBeNull();
    expect(toCcCalls("_x", {}, cwd, [""])).toBeNull();
  });
  test("a built-in id wins over a server of the same prefix", () => {
    expect(toCcCalls("bash", { command: "ls" }, cwd, ["bash"])[0].tool_name).toBe("Bash");
  });
});

const patch = [
  "*** Begin Patch",
  "*** Add File: new/dir/a.txt",
  "+line one",
  "+line two",
  "*** Update File: src/b.ts",
  "@@ function f()",
  " keep",
  "-old line",
  "+new line",
  "@@",
  "-second old",
  "+second new",
  "*** End of File",
  "*** Delete File: gone.txt",
  "*** Update File: src/c.ts",
  "*** Move to: src/d.ts",
  "@@",
  "-x",
  "+y",
  "*** End Patch",
].join("\n");
const wrap = (...body) => ["*** Begin Patch", ...body, "*** End Patch"].join("\n");

describe("parseApplyPatch (mirrors OC v1.19.0 parsePatch)", () => {
  test("add, update (per-hunk), delete, move", () => {
    expect(parseApplyPatch(patch)).toEqual([
      { op: "add", path: "new/dir/a.txt", content: "line one\nline two\n" },
      { op: "update", path: "src/b.ts", hunks: [{ oldText: "keep\nold line", newText: "keep\nnew line" }, { oldText: "second old", newText: "second new" }] },
      { op: "delete", path: "gone.txt" },
      { op: "update", path: "src/c.ts", moveTo: "src/d.ts", hunks: [{ oldText: "x", newText: "y" }] },
    ]);
    expect(parseApplyPatchFull(patch).unknown).toBe(false);
  });
  test("CRLF: paths are trimmed, rows keep their CR exactly as OC writes them", () => {
    const crlf = parseApplyPatch(wrap("*** Add File: a.txt", "+x", "*** Delete File: d.txt").replace(/\n/g, "\r\n"));
    expect(crlf).toEqual([{ op: "add", path: "a.txt", content: "x\r\n" }, { op: "delete", path: "d.txt" }]);
  });
  test("(M2a) leading whitespace, an indented Begin marker and a trailing blank line still parse", () => {
    expect(parseApplyPatch("\n\n  " + wrap("*** Delete File: a").replace("*** Begin Patch", "*** Begin Patch") + "\n\n")).toEqual([{ op: "delete", path: "a" }]);
    expect(parseApplyPatch("   *** Begin Patch\n*** Delete File: a\n  *** End Patch  ")).toEqual([{ op: "delete", path: "a" }]);
  });
  test("(M2b) headers without a space after the colon", () => {
    expect(parseApplyPatch(wrap("*** Add File:x.txt", "+a", "*** Delete File:y", "*** Update File:z", "@@", "-1", "+2"))).toEqual([
      { op: "add", path: "x.txt", content: "a\n" },
      { op: "delete", path: "y" },
      { op: "update", path: "z", hunks: [{ oldText: "1", newText: "2" }] },
    ]);
  });
  test("(M2c) update rows before the first @@ are ignored", () => {
    expect(parseApplyPatch(wrap("*** Update File: z", "-ignored", "+ignored", "@@", "-1", "+2"))[0].hunks).toEqual([{ oldText: "1", newText: "2" }]);
  });
  test("(M2d) a stray *** line ends Add content and flags unknown", () => {
    const r = parseApplyPatchFull(wrap("*** Add File: a", "+one", "*** Mystery: q", "+two"));
    expect(r.ops).toEqual([{ op: "add", path: "a", content: "one\n" }]);
    expect(r.unknown).toBe(true);
  });
  test("(M2e) add content ends with a newline; an empty add is empty", () => {
    expect(parseApplyPatch(wrap("*** Add File: a", "+x"))[0].content).toBe("x\n");
    expect(parseApplyPatch(wrap("*** Add File: a"))[0].content).toBe("");
  });
  test("(M2f) an empty-path header is not an op and flags unknown", () => {
    const r = parseApplyPatchFull(wrap("*** Add File:   ", "+x"));
    expect(r.ops).toEqual([]);
    expect(r.unknown).toBe(true);
  });
  test("blank rows inside a hunk are ignored; a pure-addition hunk has an empty oldText", () => {
    expect(parseApplyPatch(wrap("*** Update File: z", "@@", " ctx", "", "+added"))[0].hunks).toEqual([{ oldText: "ctx", newText: "ctx\nadded" }]);
    expect(parseApplyPatch(wrap("*** Update File: z", "@@", "+only"))[0].hunks).toEqual([{ oldText: "", newText: "only" }]);
  });
  test("heredoc-wrapped patch text parses", () => {
    expect(parseApplyPatch("cat <<'EOF'\n" + wrap("*** Delete File: a") + "\nEOF")).toEqual([{ op: "delete", path: "a" }]);
  });
  test("garbage, empty and non-string text -> no ops, no throw", () => {
    for (const t of ["", "hello", undefined, null, 42, "*** Add File: x\n+y", "*** End Patch\n*** Begin Patch"]) expect(parseApplyPatch(t)).toEqual([]);
  });
  test("lines outside the markers are ignored", () => {
    expect(parseApplyPatch("junk\n*** Begin Patch\n*** Delete File: a\n*** End Patch\n*** Delete File: b")).toEqual([{ op: "delete", path: "a" }]);
  });
});

describe("apply_patch fan-out (R32, fail closed)", () => {
  test("multi-file patch: add -> Write, one Edit per hunk, delete -> Bash rm, move -> Edit + Write + rm; paths absolute", () => {
    const r = toCcCalls("apply_patch", { patchText: patch }, cwd, []);
    expect(r).toEqual([
      { tool_name: "Write", tool_input: { file_path: A("new/dir/a.txt"), content: "line one\nline two\n" } },
      { tool_name: "Edit", tool_input: { file_path: A("src/b.ts"), old_string: "keep\nold line", new_string: "keep\nnew line" } },
      { tool_name: "Edit", tool_input: { file_path: A("src/b.ts"), old_string: "second old", new_string: "second new" } },
      { tool_name: "Bash", tool_input: { command: expect.stringMatching(/^rm -- .*gone\.txt'?$/) } },
      { tool_name: "Edit", tool_input: { file_path: A("src/c.ts"), old_string: "x", new_string: "y" } },
      { tool_name: "Write", tool_input: { file_path: A("src/d.ts"), content: "y" } },
      { tool_name: "Bash", tool_input: { command: expect.stringMatching(/^rm -- .*c\.ts'?$/) } },
    ]);
    for (const c of r) if (c.tool_input.file_path) expect(path.isAbsolute(c.tool_input.file_path)).toBe(true);
  });
  test("delete-only patch -> one Bash rm (not [])", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Delete File: a.txt") }, cwd, []);
    expect(r).toHaveLength(1);
    expect(r[0].tool_name).toBe("Bash");
    expect(r[0].tool_input.command.startsWith("rm -- ")).toBe(true);
    expect(r[0].tool_input.command).toContain("a.txt");
  });
  test("rm quoting: a path with a space or a quote is single-quoted and escaped", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Delete File: it's here.txt") }, cwd, []);
    expect(r[0].tool_input.command).toContain("'\\''");
    expect(r[0].tool_input.command).toMatch(/^rm -- '.*it'\\''s here\.txt'$/);
  });
  test("move: the destination is hooked as a Write, and the source is removed", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Update File: a.txt", "*** Move to: .env", "@@", "-1", "+2") }, cwd, []);
    expect(r.map((c) => c.tool_name)).toEqual(["Edit", "Write", "Bash"]);
    expect(r[1].tool_input.file_path).toBe(A(".env"));
    expect(r[2].tool_input.command).toContain("a.txt");
  });
  // Cases that discriminated in the differential run against OC's own parsePatch (R32).
  test("diff: an Update after an INDENTED End marker is still reached (OC keeps reading)", () => {
    const t = "*** Begin Patch\n*** Update File: .env\n *** End Patch\n@@\n-SECRET=a\n+SECRET=b";
    expect(toCcCalls("apply_patch", { patchText: t }, cwd, [])).toEqual([
      { tool_name: "Edit", tool_input: { file_path: A(".env"), old_string: "SECRET=a", new_string: "SECRET=b" } },
    ]);
  });
  test("diff: Add rows after an INDENTED End marker are part of the Write content", () => {
    const t = "*** Begin Patch\n*** Add File: x.py\n+ok\n *** End Patch\n+eval(input())";
    expect(toCcCalls("apply_patch", { patchText: t }, cwd, [])).toEqual([
      { tool_name: "Write", tool_input: { file_path: A("x.py"), content: "ok\neval(input())\n" } },
    ]);
  });
  test("diff: an Update with no @@ hunks still names its path (empty Edit), alone or beside other ops", () => {
    const edit = { tool_name: "Edit", tool_input: { file_path: A(".env"), old_string: "", new_string: "" } };
    expect(toCcCalls("apply_patch", { patchText: wrap("*** Update File: .env", "-SECRET=a", "+SECRET=b") }, cwd, [])).toEqual([edit]);
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Add File: n.txt", "+x", "*** Update File: .env") }, cwd, []);
    expect(r).toEqual([{ tool_name: "Write", tool_input: { file_path: A("n.txt"), content: "x\n" } }, edit]);
  });
  test("diff: a Move with no hunks still hooks the destination and removes the source", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Update File: a.txt", "*** Move to: .env") }, cwd, []);
    expect(r.map((c) => [c.tool_name, c.tool_input.file_path])).toEqual([["Edit", A("a.txt")], ["Write", A(".env")], ["Bash", undefined]]);
    expect(r[1].tool_input.content).toBe("");
  });
  test("diff: Move plus Delete of the same file emits both, in order", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Update File: a.txt", "*** Move to: b.txt", "@@", "-1", "+2", "*** Delete File: a.txt") }, cwd, []);
    expect(r.map((c) => c.tool_name)).toEqual(["Edit", "Write", "Bash", "Bash"]);
    expect(r[3].tool_input.command).toContain("a.txt");
  });
  test("diff: duplicate paths are not merged", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Add File: d.txt", "+1", "*** Add File: d.txt", "+2") }, cwd, []);
    expect(r.map((c) => c.tool_input.content)).toEqual(["1\n", "2\n"]);
  });
  test("diff: a lone '+' row writes an EMPTY file (OC strips the one trailing newline)", () => {
    expect(toCcCalls("apply_patch", { patchText: wrap("*** Add File: bl.txt", "+") }, cwd, [])[0].tool_input.content).toBe("");
  });
  test("diff: a missing End marker is not representable -> block", () => {
    expect(toCcCalls("apply_patch", { patchText: "*** Begin Patch\n*** Delete File: a.txt" }, cwd, [])).toEqual({ block: PATCH_BLOCK_REASON });
  });
  test("diff: tabs and spaces around Begin/End markers and tab-separated paths parse", () => {
    // The indented End line is a context row for OC's Update loop (it writes it into the file), so
    // it appears in both old and new text.
    const t = "\t*** Begin Patch \t\n*** Update File:\tt.txt\n@@\n-a\n+b\n  *** End Patch\t";
    expect(toCcCalls("apply_patch", { patchText: t }, cwd, [])).toEqual([
      { tool_name: "Edit", tool_input: { file_path: A("t.txt"), old_string: "a\n *** End Patch", new_string: "b\n *** End Patch" } },
    ]);
  });
  test("diff: garbage rows between hunks are ignored, both hunks emitted", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Update File: g.txt", "@@", "-a", "+b", "garbage", "", "@@", "-c", "+d") }, cwd, []);
    expect(r.map((c) => [c.tool_input.old_string, c.tool_input.new_string])).toEqual([["a", "b"], ["c", "d"]]);
  });
  test("diff: '*** End of File' inside a hunk ends the hunk without blocking", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Update File: z.txt", "@@", "-x", "+y", "*** End of File") }, cwd, []);
    expect(r).toEqual([{ tool_name: "Edit", tool_input: { file_path: A("z.txt"), old_string: "x", new_string: "y" } }]);
  });
  test("empty / absent patchText -> [] (nothing to represent)", () => {
    expect(toCcCalls("apply_patch", {}, cwd, [])).toEqual([]);
    expect(toCcCalls("apply_patch", { patchText: "  \n" }, cwd, [])).toEqual([]);
  });
  test("non-empty patchText that parses to nothing -> { block } (not an array)", () => {
    for (const t of ["hello", "*** Begin Patch\n*** End Patch", "*** Add File: x\n+y"]) {
      const r = toCcCalls("apply_patch", { patchText: t }, cwd, []);
      expect(Array.isArray(r)).toBe(false);
      expect(r).toEqual({ block: PATCH_BLOCK_REASON });
    }
    expect(PATCH_BLOCK_REASON).toBe("patch could not be represented for CC hooks; split it or use edit/write");
  });
  test("an unknown op next to valid ones -> { block }", () => {
    const r = toCcCalls("apply_patch", { patchText: wrap("*** Delete File: a", "*** Rename File: b") }, cwd, []);
    expect(r).toEqual({ block: PATCH_BLOCK_REASON });
  });
});

// ---- the real installed guard -----------------------------------------------------------

const semverDesc = (a, b) => {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pb[i] || 0) - (pa[i] || 0);
  return 0;
};
function findGuard() {
  if (process.env.CCP_GUARD) return process.env.CCP_GUARD;
  const cache = path.join(os.homedir(), ".claude", "plugins", "cache", "progdroid");
  // core is unversioned: its cache directory names are not semver, so take the newest by mtime.
  const coreRoot = path.join(cache, "core");
  const coreDirs = fs.existsSync(coreRoot)
    ? fs.readdirSync(coreRoot, { withFileTypes: true }).filter((d) => d.isDirectory())
        .map((d) => ({ d: path.join(coreRoot, d.name), t: fs.statSync(path.join(coreRoot, d.name)).mtimeMs }))
        .sort((a, b) => b.t - a.t)
    : [];
  for (const { d } of coreDirs) {
    const f = path.join(d, "hooks", "negative-result-guard.sh");
    if (fs.existsSync(f)) return f;
  }
  // Fallback: an older personal install that still ships the guard.
  const root = path.join(cache, "personal");
  const vers = fs.existsSync(root) ? fs.readdirSync(root).filter((v) => /^\d+\.\d+\.\d+$/.test(v)).sort(semverDesc) : [];
  for (const v of vers) {
    const f = path.join(root, v, "hooks", "negative-result-guard.sh");
    if (fs.existsSync(f)) return f;
  }
  return null;
}
const bashExe = () => {
  const gb = "C:/Program Files/Git/bin/bash.exe";
  return process.platform === "win32" && fs.existsSync(gb) ? gb : "bash";
};
// Runs the guard with a scratch HOME so its debug log never touches the real one.
function runGuard(payload) {
  const guard = findGuard();
  if (!guard) throw new Error("negative-result-guard.sh not found: set CCP_GUARD or install the core plugin (cache/progdroid/core/*/hooks) or an older personal plugin (cache/progdroid/personal/<semver>/hooks)");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-guard-"));
  try {
    const r = spawnSync(bashExe(), [guard], { input: JSON.stringify(payload), encoding: "utf8", env: { ...process.env, HOME: home, USERPROFILE: home } });
    const dbg = path.join(home, ".claude", "negative-result-guard.debug");
    return { out: r.stdout || "", status: r.status, debug: fs.existsSync(dbg) ? fs.readFileSync(dbg, "utf8") : "" };
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}
const fires = (r) => r.out.includes("NEGATIVE RESULT");
const bashPayload = (cmd, ocOutput) => ({ hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: { command: cmd }, tool_response: toCcResponse("Bash", ocOutput, {}) });
const searchPayload = (tool, ocOutput) => ({ hook_event_name: "PostToolUse", tool_name: tool, tool_input: {}, tool_response: toCcResponse(tool, ocOutput, {}) });

describe("the installed negative-result-guard sees OC's real output shapes (I1, I2)", () => {
  test("the guard script is locatable (this FAILS, never skips, when it is not)", () => {
    const g = findGuard();
    expect(g).not.toBeNull();
    expect(fs.existsSync(g)).toBe(true);
  });
  test("control: a CC-shaped empty Bash response fires, a non-empty one does not", () => {
    expect(fires(runGuard({ tool_name: "Bash", tool_input: { command: "grep -r zzz ." }, tool_response: { stdout: "", stderr: "" } }))).toBe(true);
    expect(fires(runGuard({ tool_name: "Bash", tool_input: { command: "grep -r zzz ." }, tool_response: { stdout: "a:1", stderr: "" } }))).toBe(false);
  });
  test("Bash: OC's literal \"(no output)\" on an empty grep fires", () => {
    const r = runGuard(bashPayload("grep -r zzz .", "(no output)"));
    expect(fires(r)).toBe(true);
    expect(r.debug).toBe("");
  });
  test("Bash: \"(no output)\" plus a shell_metadata block (timeout) still fires", () => {
    const out = "(no output)\n\n<shell_metadata>\nshell tool terminated command after exceeding timeout 100 ms. If this command ...\n</shell_metadata>";
    expect(fires(runGuard(bashPayload("grep -r zzz .", out)))).toBe(true);
  });
  test("Bash: real matches do not fire", () => {
    expect(fires(runGuard(bashPayload("grep -r zzz .", "./a.txt:1:zzz\n")))).toBe(false);
  });
  test("Glob: OC's \"No files found\" fires with no unknown-shape debug line; real paths do not", () => {
    const e = runGuard(searchPayload("Glob", "No files found"));
    expect(fires(e)).toBe(true);
    expect(e.debug).toBe("");
    const f = runGuard(searchPayload("Glob", path.join(cwd, "a.md") + "\n" + path.join(cwd, "b.md")));
    expect(fires(f)).toBe(false);
    expect(f.debug).toBe("");
  });
  test("Grep: OC's \"No files found\" fires with no unknown-shape debug line; OC's real match listing does not", () => {
    const e = runGuard(searchPayload("Grep", "No files found"));
    expect(fires(e)).toBe(true);
    expect(e.debug).toBe("");
    const f = runGuard(searchPayload("Grep", `Found 2 matches\n${path.join(cwd, "a.js")}:\n  Line 3: foo\n  Line 9: foo bar`));
    expect(fires(f)).toBe(false);
    expect(f.debug).toBe("");
  });
});

describe("toCcResponse", () => {
  test("Bash: plain output", () => {
    expect(toCcResponse("Bash", "out\n", {})).toEqual({ stdout: "out\n", stderr: "", interrupted: false, isImage: false });
  });
  test("Bash: \"(no output)\" -> empty stdout; only the EXACT placeholder", () => {
    expect(toCcResponse("Bash", "(no output)", {}).stdout).toBe("");
    expect(toCcResponse("Bash", "(no output) but more", {}).stdout).toBe("(no output) but more");
  });
  test("Bash: the shell_metadata block is stripped; abort and timeout set interrupted", () => {
    const ab = toCcResponse("Bash", "partial\n\n<shell_metadata>\nUser aborted the command\n</shell_metadata>", {});
    expect(ab).toEqual({ stdout: "partial", stderr: "", interrupted: true, isImage: false });
    const to = toCcResponse("Bash", "(no output)\n\n<shell_metadata>\nshell tool terminated command after exceeding timeout 5 ms. retry\n</shell_metadata>", {});
    expect(to.stdout).toBe("");
    expect(to.interrupted).toBe(true);
  });
  test("Bash: program output containing its own <shell_metadata> tag is not truncated; only the LAST block with OC's messages is stripped", () => {
    const fake = "line1\n\n<shell_metadata>\nfake\n</shell_metadata>\n\nline2";
    expect(toCcResponse("Bash", fake, {}).stdout).toBe(fake);
    const real = fake + "\n\n<shell_metadata>\nUser aborted the command\n</shell_metadata>";
    expect(toCcResponse("Bash", real, {})).toMatchObject({ stdout: fake, interrupted: true });
    // a trailing block that is not one of OC's messages is program output, kept whole
    const notOc = "x\n\n<shell_metadata>\nsomething else\n</shell_metadata>";
    expect(toCcResponse("Bash", notOc, {})).toMatchObject({ stdout: notOc, interrupted: false });
  });
  test("Bash: a non-string output never throws", () => {
    expect(toCcResponse("Bash", undefined, {}).stdout).toBe("");
  });
  test("Glob shapes", () => {
    expect(toCcResponse("Glob", "No files found", {})).toEqual({ filenames: [], numFiles: 0, truncated: false });
    expect(toCcResponse("Glob", "/a/x.md\n/a/y.md", {})).toEqual({ filenames: ["/a/x.md", "/a/y.md"], numFiles: 2, truncated: false });
    const t = toCcResponse("Glob", "/a/x.md\n\n(Results are truncated: showing first 100 results. Consider using a more specific path or pattern.)", {});
    expect(t).toEqual({ filenames: ["/a/x.md"], numFiles: 1, truncated: true });
  });
  test("Grep shapes", () => {
    expect(toCcResponse("Grep", "No files found", {})).toMatchObject({ mode: "content", numFiles: 0, filenames: [], content: "" });
    const out = "Found 3 matches\n/a/x.js:\n  Line 1: foo\n  Line 2: foo\n\n/a/y.js:\n  Line 7: foo";
    expect(toCcResponse("Grep", out, {})).toMatchObject({ mode: "content", numFiles: 2, filenames: ["/a/x.js", "/a/y.js"], content: out });
    expect(toCcResponse("Grep", "C:\\p\\x.js:\n  Line 1: a: b:", {}).filenames).toEqual(["C:\\p\\x.js"]);
  });
  test("mcp__*: the content array (M3); a string is wrapped as a text block", () => {
    const c = [{ type: "text", text: "hi" }];
    expect(toCcResponse("mcp__s__t", { content: c, isError: false }, {})).toEqual(c);
    expect(toCcResponse("mcp__s__t", "plain", {})).toEqual([{ type: "text", text: "plain" }]);
  });
  test("Write carries filePath/type; others carry output", () => {
    expect(toCcResponse("Write", "ok", { file_path: "/a/b" })).toEqual({ filePath: "/a/b", type: "create" });
    expect(toCcResponse("Edit", "ok", {})).toEqual({ output: "ok" });
  });
});

describe("applyUpdatedInput", () => {
  test("bash round-trips: command/timeout replaced, workdir kept", () => {
    const orig = { command: "ls", timeout: 1, workdir: "/w" };
    const cc = toCcCalls("bash", orig, cwd, [])[0].tool_input;
    expect(applyUpdatedInput("bash", orig, { ...cc, command: "ls -la" })).toEqual({ command: "ls -la", timeout: 1, workdir: "/w" });
  });
  test("edit maps snake_case back to camelCase", () => {
    const orig = { filePath: "/f", oldString: "a", newString: "b", replaceAll: false };
    expect(applyUpdatedInput("edit", orig, { file_path: "/g", old_string: "c", new_string: "d", replace_all: true })).toEqual({
      filePath: "/g", oldString: "c", newString: "d", replaceAll: true,
    });
  });
  test("edit: a partial update changes only the supplied keys, and the input is not mutated", () => {
    const orig = { filePath: "/f", oldString: "a", newString: "b" };
    const out = applyUpdatedInput("edit", orig, { new_string: "z" });
    expect(out).toEqual({ filePath: "/f", oldString: "a", newString: "z" });
    expect(orig.newString).toBe("b");
    expect(out).not.toBe(orig);
  });
  test("write maps file_path/content", () => {
    expect(applyUpdatedInput("write", { filePath: "/f", content: "a" }, { file_path: "/g", content: "b" })).toEqual({ filePath: "/g", content: "b" });
  });
  test("other tools: args returned unchanged", () => {
    const a = { filePath: "/f" };
    expect(applyUpdatedInput("read", a, { file_path: "/g" })).toBe(a);
    expect(applyUpdatedInput("serena_x", a, { z: 1 })).toBe(a);
  });
  test("a null / non-object updatedInput changes nothing", () => {
    expect(applyUpdatedInput("bash", { command: "ls" }, null)).toEqual({ command: "ls" });
  });
});

describe("unmappedUpdateKeys (R48 a)", () => {
  test("keys with no OC arg whose value changed are returned; mapped keys and unchanged echoes are not", async () => {
    const { unmappedUpdateKeys } = await import("../core/toolmap.js");
    expect(unmappedUpdateKeys("bash", { command: "ls" }, { command: "ls -la", run_in_background: true })).toEqual(["run_in_background"]);
    expect(unmappedUpdateKeys("bash", { command: "ls", description: "d" }, { command: "x", description: "d" })).toEqual([]);
    expect(unmappedUpdateKeys("bash", { command: "ls", description: "d" }, { description: "changed" })).toEqual(["description"]);
    expect(unmappedUpdateKeys("edit", {}, { file_path: "a", old_string: "b", new_string: "c", replace_all: true })).toEqual([]);
    expect(unmappedUpdateKeys("serena_x", { a: 1 }, { a: 2, b: 3 })).toEqual(["a", "b"]);
    expect(unmappedUpdateKeys("bash", { command: "ls" }, null)).toEqual([]);
  });
});

describe("R51 m-6: dropped keys (CC replaces the input with updatedInput)", () => {
  test("undroppableKeys: a dropped required or unmapped key; an optional OC arg may be dropped", async () => {
    const { undroppableKeys } = await import("../core/toolmap.js");
    expect(undroppableKeys("bash", { command: "ls", timeout: 5 }, { command: "ls" })).toEqual([]);
    expect(undroppableKeys("bash", { command: "ls", timeout: 5 }, { timeout: 5 })).toEqual(["command"]);
    expect(undroppableKeys("edit", { file_path: "/f", old_string: "a", new_string: "b", replace_all: true }, { file_path: "/f", old_string: "a", new_string: "b" })).toEqual([]);
    expect(undroppableKeys("write", { file_path: "/f", content: "a" }, { file_path: "/f" })).toEqual(["content"]);
    expect(undroppableKeys("serena_x", { a: 1, b: 2 }, { a: 1 })).toEqual(["b"]);
    expect(undroppableKeys("bash", { command: "ls" }, null)).toEqual(["command"]);
  });
  test("applyUpdatedInput with the CC input removes a dropped optional arg and keeps unmapped OC args", () => {
    const orig = { command: "ls", timeout: 1, workdir: "/w" };
    expect(applyUpdatedInput("bash", orig, { command: "ls -la" }, { command: "ls", timeout: 1 })).toEqual({ command: "ls -la", workdir: "/w" });
    expect(orig.timeout).toBe(1);
    expect(applyUpdatedInput("bash", orig, { command: "ls -la" })).toEqual({ command: "ls -la", timeout: 1, workdir: "/w" }); // no CC input: merge, as before
  });
});
