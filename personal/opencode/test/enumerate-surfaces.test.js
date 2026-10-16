import { describe, expect, test, afterEach } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { enumerate, HANDLED, IGNORED, NOT_TRANSLATED } from "../core/enumerate.js";

const tmp = [];
afterEach(() => {
  while (tmp.length) fs.rmSync(tmp.pop(), { recursive: true, force: true });
});
function dir(files) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-surf-"));
  tmp.push(d);
  for (const [rel, c] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(d, rel)), { recursive: true });
    fs.writeFileSync(path.join(d, rel), typeof c === "string" ? c : JSON.stringify(c));
  }
  return d;
}
const plug = (name, files) => ({ key: `${name}@mk`, name, installPath: dir(files), exists: true });
const keys = (r) => r.map((u) => u.key).sort();
const hookFile = (handler, extra = {}) => ({ description: "d", hooks: { PreToolUse: [{ matcher: "Bash", hooks: [handler] }] }, ...extra });
const okHandler = { type: "command", command: "x", if: "Bash(git *)", asyncRewake: true, rewakeMessage: "m", rewakeSummary: "s", onFailure: "ignore", statusMessage: "s", args: [], shell: "bash", async: false, timeout: 5 };

describe("plugin hooks/hooks.json is inside the alarm (C1)", () => {
  test("handled fields incl. if/asyncRewake are silent", () => {
    const p = plug("p", { "hooks/hooks.json": hookFile(okHandler) });
    expect(enumerate({ plugins: [p] })).toEqual([]);
  });
  test("an unknown hook field, event, type and group field are reported with where = plugin:<name>", () => {
    const f = hookFile({ type: "prompt", command: "x", brandNew: 1 });
    f.hooks.PreToolUse[0].weird = 1;
    f.hooks.NewEvent = [];
    const r = enumerate({ plugins: [plug("p", { "hooks/hooks.json": f })] });
    expect(keys(r)).toEqual(["hooks.event.NewEvent", "hooks.field.brandNew", "hooks.group.weird", "hooks.type=prompt"]);
    expect(r.every((u) => u.where === "plugin:p")).toBe(true);
  });
  test("commandWindows is silent: CC has no reader for it on hooks and runs `command` on Windows", () => {
    const p = plug("p", { "hooks/hooks.json": hookFile({ type: "command", command: "x", commandWindows: "& x.exe" }) });
    expect(enumerate({ plugins: [p] })).toEqual([]);
    const s = { scope: "user", path: "S", data: { hooks: { Stop: [{ hooks: [{ type: "command", command: "x", commandWindows: "y" }] }] } } };
    expect(enumerate({ sources: [s] })).toEqual([]);
  });
  test("an unknown hooks.json top-level key is reported; description is silent", () => {
    const r = enumerate({ plugins: [plug("p", { "hooks/hooks.json": hookFile(okHandler, { newTop: 1 }) })] });
    expect(keys(r)).toEqual(["hooks.json:newTop"]);
  });
  test("a manifest inline hooks object and a manifest hooks path are walked too", () => {
    const inline = plug("a", { ".claude-plugin/plugin.json": { name: "a", hooks: hookFile({ type: "command", zed: 1 }).hooks } });
    expect(keys(enumerate({ plugins: [inline] }))).toEqual(["hooks.field.zed"]);
    const viaPath = plug("b", { ".claude-plugin/plugin.json": { name: "b", hooks: "./hooks/h2.json" }, "hooks/h2.json": hookFile({ type: "command", yak: 1 }) });
    expect(keys(enumerate({ plugins: [viaPath] }))).toEqual(["hooks.field.yak"]);
  });
  test("a BOM on hooks.json is stripped and still parsed", () => {
    const p = plug("p", { "hooks/hooks.json": "﻿" + JSON.stringify(hookFile({ type: "command", zed: 1 })) });
    expect(keys(enumerate({ plugins: [p] }))).toEqual(["hooks.field.zed"]);
  });
  test("the same field in plugin and settings are distinct reports", () => {
    const p = plug("p", { "hooks/hooks.json": hookFile({ type: "command", zed: 1 }) });
    const s = { scope: "user", path: "S", data: { hooks: { PreToolUse: [{ hooks: [{ type: "command", zed: 1 }] }] } } };
    expect(enumerate({ plugins: [p], sources: [s] }).map((u) => u.where).sort()).toEqual(["S", "plugin:p"]);
  });
});

describe("MCP server fields in every source (I4)", () => {
  const srv = { type: "stdio", command: "c", args: [], env: { K: "SECRETVAL" }, headers: { A: "SECRETVAL" } };
  test("plugin .mcp.json, both shapes", () => {
    const wrapped = plug("w", { ".mcp.json": { mcpServers: { s: { ...srv, oauth: 1 } } } });
    const flat = plug("f", { ".mcp.json": { s: { ...srv, authHelper: 1 } } });
    const r = enumerate({ plugins: [wrapped, flat] });
    expect(keys(r)).toEqual(["mcp.*.authHelper", "mcp.*.oauth"]);
    expect(JSON.stringify(r)).not.toContain("SECRETVAL");
  });
  test("a clean plugin .mcp.json is silent", () => {
    expect(enumerate({ plugins: [plug("w", { ".mcp.json": { mcpServers: { s: srv } } })] })).toEqual([]);
  });
  test("manifest inline mcpServers and manifest mcpServers path", () => {
    const inl = plug("i", { ".claude-plugin/plugin.json": { name: "i", mcpServers: { s: { ...srv, a1: 1 } } } });
    const pth = plug("j", { ".claude-plugin/plugin.json": { name: "j", mcpServers: "./agents/m.json" }, "agents/m.json": { s: { ...srv, a2: 1 } } });
    expect(keys(enumerate({ plugins: [inl, pth] }))).toEqual(["mcp.*.a1", "mcp.*.a2"]);
  });
  test("the project's .mcp.json (projectDir)", () => {
    const proj = dir({ ".mcp.json": { mcpServers: { s: { ...srv, pz: 1 } } } });
    const r = enumerate({ projectDir: proj });
    expect(keys(r)).toEqual(["mcp.*.pz"]);
    expect(r[0].where).toBe("project:.mcp.json");
    expect(enumerate({})).toEqual([]);
  });
  test("project-entry mcpServers in ~/.claude.json are walked (M3)", () => {
    const c = { projects: { "/x": { mcpServers: { s: { ...srv, pe: 1 } } } } };
    expect(keys(enumerate({ claudeJson: c }))).toEqual(["projects.*.mcpServers.*.pe"]);
  });
});

describe("notTranslated (R16)", () => {
  test("a notTranslated key is reported with the note, an ignored key is silent", () => {
    const s = { scope: "user", path: "S", data: { effortLevel: "high", statusLine: {}, env: { ENABLE_LSP_TOOL: "1", ENABLE_TOOL_SEARCH: "1" } } };
    const c = { claudeAiMcpEverConnected: true, numStartups: 1, projects: { "/p": { hasTrustDialogAccepted: true, lastCost: 1 } } };
    const r = enumerate({ sources: [s], claudeJson: c });
    // hasTrustDialogAccepted is HANDLED since R47 (the trust gate), so it is silent here
    expect(keys(r)).toEqual(["claudeAiMcpEverConnected", "effortLevel", "env.ENABLE_LSP_TOOL"]);
    for (const u of r) expect(u.note.startsWith("affects behaviour; not translated to OC: ")).toBe(true);
    expect(r.find((u) => u.key === "claudeAiMcpEverConnected").note).toContain("claude.ai connector MCP servers are not available in OC");
  });
  test("exported, every reason non-empty, and disjoint from IGNORED and HANDLED", () => {
    let n = 0;
    for (const [cat, e] of Object.entries(NOT_TRANSLATED)) {
      for (const [k, why] of Object.entries(e)) {
        n++;
        expect(why.trim().length).toBeGreaterThan(8);
        expect(Object.hasOwn(IGNORED[cat] || {}, k)).toBe(false);
        expect((HANDLED[cat] || []).includes(k)).toBe(false);
      }
    }
    expect(n).toBe(9); // ocTools.execute dropped again (R39); hasTrustDialogAccepted handled (R47); +pluginManifest.lspServers (D1, 0.12.1)
  });
  test("the 4 review (b) keys plus effort/model/LSP/trust are members", () => {
    expect(Object.keys(NOT_TRANSLATED.env).sort()).toEqual(["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "ENABLE_LSP_TOOL", "ENABLE_LSP_TOOLS"]);
    expect(Object.keys(NOT_TRANSLATED.settings).sort()).toEqual(["autoCompactWindow", "effortLevel", "modelSettings"]);
  });
});

describe("per-plugin entries (R17, R18)", () => {
  test("bin/ is handled for every plugin", () => {
    expect(enumerate({ plugins: [plug("any", { "bin/tool": "x" })] })).toEqual([]);
  });
  test("an ignored per-plugin entry is silent for its plugin and reported for another plugin", () => {
    const ent = Object.keys(IGNORED.pluginEntriesByPlugin).find((k) => k.startsWith("android-skills:") && k.endsWith(":security"));
    expect(ent).toBe("android-skills:security");
    const mine = plug("android-skills", { "security/x": "1" });
    const other = plug("some-other", { "security/x": "1" });
    const r = enumerate({ plugins: [mine, other] });
    expect(r.map((u) => `${u.where}|${u.key}`)).toEqual(["plugin:some-other|security"]);
  });
  test("superpowers' .opencode and index.js are handled; another plugin's are unknown", () => {
    const sp = plug("superpowers", { ".opencode/x": "1", "index.js": "1" });
    const other = plug("not-superpowers", { ".opencode/x": "1", "index.js": "1" });
    const r = enumerate({ plugins: [sp, other] });
    expect(r.map((u) => `${u.where}|${u.key}`).sort()).toEqual(["plugin:not-superpowers|.opencode", "plugin:not-superpowers|index.js"]);
  });
  test("personal's own opencode/ (this adapter) and semgrep's .codex-plugin are silent; another plugin's are reported", () => {
    const mine = [plug("personal", { "opencode/adapter.js": "1" }), plug("semgrep", { ".codex-plugin/plugin.json": "{}" })];
    const other = plug("not-personal", { "opencode/adapter.js": "1", ".codex-plugin/plugin.json": "{}" });
    const r = enumerate({ plugins: [...mine, other] });
    expect(r.map((u) => `${u.where}|${u.key}`).sort()).toEqual(["plugin:not-personal|.codex-plugin", "plugin:not-personal|opencode"]);
  });
  test("global repo-metadata names stay global", () => {
    expect(enumerate({ plugins: [plug("z", { "README.md": "1", LICENSE: "1", ".github/x": "1", docs: {} })] })).toEqual([]);
  });
  test("every per-plugin ignore and every ignored manifest key is silent through enumerate", () => {
    const byPlugin = {};
    for (const k of Object.keys(IGNORED.pluginEntriesByPlugin)) {
      const i = k.indexOf(":");
      (byPlugin[k.slice(0, i)] ??= {})[k.slice(i + 1)] = "1";
    }
    const plugins = Object.entries(byPlugin).map(([n, files]) => plug(n, files));
    const manifest = {};
    for (const k of Object.keys(IGNORED.pluginManifest)) manifest[k] = "x";
    plugins.push(plug("meta", { ".claude-plugin/plugin.json": manifest }));
    expect(enumerate({ plugins })).toEqual([]);
  });
});

describe("guards (M3)", () => {
  test("a server name that sanitises to just '_' does not blanket-handle every tool", () => {
    // sanitize("") = "" -> prefix "_" has length 1; the guard refuses to treat it as a server prefix
    expect(keys(enumerate({ ocTools: ["_leading", "x_y"], mcpServers: [""] }))).toEqual(["_leading", "x_y"]);
  });
});
