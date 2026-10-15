import { describe, expect, test, afterEach } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { enumerate, HANDLED, IGNORED } from "../core/enumerate.js";

const tmp = [];
afterEach(() => {
  while (tmp.length) fs.rmSync(tmp.pop(), { recursive: true, force: true });
});

// A plugin dir on disk: files = { "rel/path": string }.
function plugin(name, files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-plug-"));
  tmp.push(dir);
  for (const [rel, c] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), typeof c === "string" ? c : JSON.stringify(c));
  }
  return { key: `${name}@mk`, name, installPath: dir, exists: true };
}

const goodHook = {
  type: "command", command: "x", args: [], timeout: 5, shell: "bash", async: false, origin: "settings:user",
  asyncRewake: true, rewakeMessage: "m", rewakeSummary: "s", if: "Bash(git *)", onFailure: "ignore", statusMessage: "hi",
};
const goodSettings = () => ({
  scope: "user",
  path: "S",
  data: {
    env: { ENABLE_TOOL_SEARCH: "1" },
    permissions: { allow: [], ask: [], deny: [] },
    hooks: { PreToolUse: [{ matcher: "Bash", origin: "settings:user", hooks: [{ ...goodHook }] }] },
    enabledPlugins: {},
    statusLine: { type: "command" },
  },
});
const goodClaudeJson = () => ({
  numStartups: 3,
  mcpServers: { s: { type: "http", url: "u", headers: { A: "b" }, command: "c", args: [], env: { K: "v" } } },
  projects: { "/p": { mcpServers: {}, enabledMcpjsonServers: [], allowedTools: [], lastCost: 1 } },
});
const run = (over = {}) => enumerate({ sources: [goodSettings()], plugins: [], claudeJson: goodClaudeJson(), ocTools: ["bash", "read"], ...over });
const keys = (r) => r.map((u) => u.key);

describe("enumerate: silent on the known", () => {
  test("handled + ignored keys everywhere produce nothing", () => {
    const p = plugin("good", {
      ".claude-plugin/plugin.json": { name: "g", version: "1", description: "d", skills: "./s" },
      "skills/a.md": "x",
      "README.md": "x",
      ".mcp.json": {},
    });
    expect(run({ plugins: [p] })).toEqual([]);
  });
  test("called with no arguments does not throw and is empty", () => {
    expect(enumerate()).toEqual([]);
  });
});

describe("enumerate: unknowns are reported (the drift alarm)", () => {
  test("unknown top-level settings key", () => {
    const s = goodSettings();
    s.data.brandNewKey = 1;
    const r = run({ sources: [s] });
    expect(keys(r)).toEqual(["brandNewKey"]);
    expect(r[0].where).toBe("S");
  });
  test("unknown env key", () => {
    const s = goodSettings();
    s.data.env.NEW_FLAG = "1";
    expect(keys(run({ sources: [s] }))).toEqual(["env.NEW_FLAG"]);
  });
  test("unknown hook field", () => {
    const s = goodSettings();
    s.data.hooks.PreToolUse[0].hooks[0].newField = 1;
    expect(keys(run({ sources: [s] }))).toEqual(["hooks.field.newField"]);
  });
  test("unknown hook group field, event and handler type", () => {
    const s = goodSettings();
    s.data.hooks.PreToolUse[0].weird = 1;
    s.data.hooks.NewEvent = [];
    s.data.hooks.PreToolUse[0].hooks.push({ type: "prompt", prompt: "p" });
    expect(keys(run({ sources: [s] })).sort()).toEqual(["hooks.event.NewEvent", "hooks.field.prompt", "hooks.group.weird", "hooks.type=prompt"]);
  });
  test("unknown permission kind", () => {
    const s = goodSettings();
    s.data.permissions.defaultMode = "plan";
    expect(keys(run({ sources: [s] }))).toEqual(["permissions.defaultMode"]);
  });
  test("unknown plugin entry and manifest key", () => {
    const p = plugin("odd", { ".claude-plugin/plugin.json": { name: "o", lspServers: {} }, "lsp-extra/x": "1" });
    const r = run({ plugins: [p] });
    expect(keys(r).sort()).toEqual(["lsp-extra", "plugin.json:lspServers"]);
    expect(r.every((u) => u.where === "plugin:odd")).toBe(true);
  });
  test("a plugin whose dir is missing is skipped, not crashed on", () => {
    expect(run({ plugins: [{ key: "m@x", name: "m", installPath: "/nope/never", exists: false }] })).toEqual([]);
  });
  test("unknown .claude.json top-level key, project-entry key and MCP field", () => {
    const c = goodClaudeJson();
    c.newTop = 1;
    c.projects["/p"].newShape = 1;
    c.mcpServers.s.oauth = {};
    expect(keys(run({ claudeJson: c })).sort()).toEqual(["mcpServers.*.oauth", "newTop", "projects.*.newShape"]);
  });
  test("project shapes are deduped across projects and paths never appear", () => {
    const c = goodClaudeJson();
    c.projects["/secret/machine/path"] = { newShape: 1 };
    c.projects["/p"].newShape = 2;
    const r = run({ claudeJson: c });
    expect(keys(r)).toEqual(["projects.*.newShape"]);
    expect(JSON.stringify(r)).not.toContain("secret");
  });
  test("allowedTools / mcpContextUris are ignored only while empty", () => {
    const c = goodClaudeJson();
    c.projects["/p"].mcpContextUris = [];
    expect(run({ claudeJson: c })).toEqual([]);
    c.projects["/p"].allowedTools = ["Bash(rm *)"];
    const r = run({ claudeJson: c });
    expect(keys(r)).toEqual(["projects.*.allowedTools"]);
    expect(JSON.stringify(r)).not.toContain("rm");
  });
  test("unknown OC tool", () => {
    expect(keys(run({ ocTools: ["bash", "brand_new_tool"] }))).toEqual(["brand_new_tool"]);
  });
  test("MCP tools whose prefix is a known server are handled; others are not", () => {
    const r = run({ ocTools: ["serena_initial_instructions", "my_srv_do_it", "other_thing", "serena"], mcpServers: ["serena", "my.srv"] });
    expect(keys(r).sort()).toEqual(["other_thing", "serena"]);
  });
  test("no mcpServers given: an MCP-shaped tool is unknown", () => {
    expect(keys(run({ ocTools: ["serena_x"] }))).toEqual(["serena_x"]);
  });
  test("unknown reports carry key names, never values", () => {
    const s = goodSettings();
    s.data.env.TOKEN_X = "sekret-value-123";
    const c = goodClaudeJson();
    c.mcpServers.s.headers = { Authorization: "Bearer sekret-value-456" };
    c.leakyKey = "sekret-value-789";
    const text = JSON.stringify(run({ sources: [s], claudeJson: c }));
    expect(text).toContain("TOKEN_X");
    expect(text).not.toContain("sekret");
  });
  test("the same unknown in two sources is reported once per file", () => {
    const a = goodSettings(), b = { ...goodSettings(), scope: "project", path: "P" };
    a.data.nope = 1;
    b.data.nope = 1;
    expect(run({ sources: [a, b] }).map((u) => u.where).sort()).toEqual(["P", "S"]);
  });
});

describe("HANDLED and IGNORED invariants", () => {
  test("hookFields carries the behaviour fields Tasks 4/5 implement", () => {
    for (const f of ["if", "asyncRewake", "rewakeMessage", "rewakeSummary", "onFailure", "statusMessage"]) {
      expect(HANDLED.hookFields).toContain(f);
    }
  });
  test("those hook fields are never in ignored.json", () => {
    const all = JSON.stringify(IGNORED);
    expect(Object.keys(IGNORED).includes("hookFields")).toBe(false);
    for (const f of ["if", "asyncRewake", "rewakeMessage", "rewakeSummary", "onFailure", "statusMessage"]) {
      for (const cat of Object.keys(IGNORED)) expect(Object.hasOwn(IGNORED[cat], f)).toBe(false);
    }
    expect(all.length).toBeGreaterThan(100);
  });
  test("every ignored entry has a non-empty reason, and ignored never overlaps handled", () => {
    let n = 0;
    for (const [cat, entries] of Object.entries(IGNORED)) {
      for (const [k, reason] of Object.entries(entries)) {
        n++;
        expect(typeof reason).toBe("string");
        expect(reason.trim().length).toBeGreaterThan(8);
        expect((HANDLED[cat] || []).includes(k)).toBe(false);
      }
    }
    expect(n).toBeGreaterThan(100);
  });
  test("ocTools holds the mapped E11 built-ins (invalid/execute are handled-silent internals, R39)", () => {
    for (const t of ["bash", "read", "edit", "write", "apply_patch", "task", "skill"]) expect(HANDLED.ocTools).toContain(t);
  });
  test("every ignored key is actually silent through enumerate", () => {
    const s = goodSettings();
    for (const k of Object.keys(IGNORED.settings)) s.data[k] = 1;
    for (const k of Object.keys(IGNORED.env)) s.data.env[k] = "1";
    const c = goodClaudeJson();
    for (const k of Object.keys(IGNORED.claudeJson)) c[k] = 1;
    for (const k of Object.keys(IGNORED.claudeJsonProject)) if (!["allowedTools", "mcpContextUris"].includes(k)) c.projects["/p"][k] = 1;
    expect(run({ sources: [s], claudeJson: c })).toEqual([]);
  });
});
