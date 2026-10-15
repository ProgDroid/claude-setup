import { test, expect, afterEach } from "bun:test";
import path from "node:path";
import { makeHome } from "./helpers.js";
import { loadSettings, sameDir } from "../core/settings.js";
import { ccPaths, projectPaths, ocPaths } from "../core/paths.js";

let h;
afterEach(() => h && h.cleanup());

test("scalars: highest scope wins", () => {
  h = makeHome({
    ".claude/settings.json": { model: "user", effortLevel: "low", only: "u" },
    "project:.claude/settings.json": { model: "project", effortLevel: "mid" },
    "project:.claude/settings.local.json": { model: "local" },
  });
  const r = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect(r.merged.model).toBe("local");
  expect(r.merged.effortLevel).toBe("mid");
  expect(r.merged.only).toBe("u");
  expect(r.sources.map((s) => s.scope)).toEqual(["user", "project", "projectLocal"]);
  expect(r.unknown).toEqual([]);
});

test("permission lists merge and dedupe; objects deep-merge", () => {
  h = makeHome({
    ".claude/settings.json": {
      permissions: { allow: ["Bash(ls)", "Read"], deny: ["Read(.env)"] },
      enabledPlugins: { "a@m": true, "b@m": true },
    },
    "project:.claude/settings.json": {
      permissions: { allow: ["Read", "Bash(git *)"], ask: ["Edit"] },
      enabledPlugins: { "b@m": false },
    },
  });
  const { merged } = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect(merged.permissions.allow).toEqual(["Bash(ls)", "Read", "Bash(git *)"]);
  expect(merged.permissions.deny).toEqual(["Read(.env)"]);
  expect(merged.permissions.ask).toEqual(["Edit"]);
  expect(merged.enabledPlugins).toEqual({ "a@m": true, "b@m": false });
});

test("hooks concatenate in scope order with origin labels", () => {
  const g = (cmd) => [{ matcher: "Bash", hooks: [{ type: "command", command: cmd }] }];
  h = makeHome({
    ".claude/settings.json": { hooks: { PreToolUse: g("u") } },
    "project:.claude/settings.json": { hooks: { PreToolUse: g("p"), Stop: g("ps") } },
    "project:.claude/settings.local.json": { hooks: { PreToolUse: g("l") } },
  });
  const { merged } = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  const pre = merged.hooks.PreToolUse;
  expect(pre.map((x) => x.hooks[0].command)).toEqual(["u", "p", "l"]);
  expect(pre.map((x) => x.origin)).toEqual(["settings:user", "settings:project", "settings:projectLocal"]);
  expect(pre.map((x) => x.hooks[0].origin)).toEqual(["settings:user", "settings:project", "settings:projectLocal"]);
  expect(merged.hooks.Stop).toHaveLength(1);
  expect(merged.hooks.Stop[0].origin).toBe("settings:project");
});

test("hooks do not leak into other merged keys and absent hooks stay absent", () => {
  h = makeHome({ ".claude/settings.json": { model: "x" } });
  const { merged } = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect("hooks" in merged).toBe(false);
});

test("user settings.local.json is reported as unknown, not read", () => {
  h = makeHome({
    ".claude/settings.json": { model: "user" },
    ".claude/settings.local.json": { model: "SHOULD-NOT-APPLY", extra: 1 },
  });
  const r = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect(r.merged.model).toBe("user");
  expect("extra" in r.merged).toBe(false);
  expect(r.sources.every((s) => !s.path.endsWith("settings.local.json") || s.scope !== "user")).toBe(true);
  expect(r.unknown).toHaveLength(1);
  expect(r.unknown[0].where).toBe(ccPaths(h.home).settingsLocalUser);
  expect(r.unknown[0].note).toMatch(/not read/);
});

test("projectDir === home skips the project scope (1 source, not loaded twice)", () => {
  h = makeHome({
    ".claude/settings.json": {
      permissions: { allow: ["A"] },
      hooks: { Stop: [{ hooks: [{ type: "command", command: "x" }] }] },
    },
    ".claude/settings.local.json": { model: "ignored" },
  });
  const r = loadSettings({ home: h.home, projectDir: h.home });
  expect(r.sources).toHaveLength(1);
  expect(r.sources[0].scope).toBe("user");
  expect(r.merged.hooks.Stop).toHaveLength(1);
  // trailing separator and case variants resolve to the same dir
  const r2 = loadSettings({ home: h.home, projectDir: h.home + path.sep });
  expect(r2.sources).toHaveLength(1);
});

test("missing files are fine", () => {
  h = makeHome({});
  const r = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect(r.merged).toEqual({});
  expect(r.sources).toEqual([]);
  expect(r.unknown).toEqual([]);
});

test("sources carry the raw data per scope", () => {
  h = makeHome({
    ".claude/settings.json": { a: 1 },
    "project:.claude/settings.json": { a: 2 },
  });
  const r = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect(r.sources.map((s) => s.data.a)).toEqual([1, 2]);
  expect(r.sources[1].path).toBe(projectPaths(h.projectDir).settings);
});

test("unparseable settings file is unknown (where: path), skipped, never throws", () => {
  h = makeHome({
    ".claude/settings.json": { model: "user" },
    "project:.claude/settings.json": "{ not json",
    "project:.claude/settings.local.json": { effortLevel: "ok" },
  });
  let r;
  expect(() => (r = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true }))).not.toThrow();
  expect(r.merged.model).toBe("user");
  expect(r.merged.effortLevel).toBe("ok");
  expect(r.sources.map((s) => s.scope)).toEqual(["user", "projectLocal"]);
  expect(r.unknown).toHaveLength(1);
  expect(r.unknown[0].where).toBe(projectPaths(h.projectDir).settings);
  expect(r.unknown[0].note).toMatch(/unparseable/);
});

test("a JSON array at top level is treated as unparseable settings", () => {
  h = makeHome({ ".claude/settings.json": "[1,2]" });
  const r = loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true });
  expect(r.sources).toEqual([]);
  expect(r.unknown).toHaveLength(1);
});

test("BOM-prefixed settings parse", () => {
  h = makeHome({ ".claude/settings.json": "﻿" + JSON.stringify({ model: "bom" }) });
  expect(loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true }).merged.model).toBe("bom");
});

test("ccPaths derives everything from home", () => {
  const p = ccPaths(path.join("x", "home"));
  const c = path.join("x", "home", ".claude");
  expect(p).toEqual({
    claudeDir: c,
    settings: path.join(c, "settings.json"),
    settingsLocalUser: path.join(c, "settings.local.json"),
    claudeJson: path.join("x", "home", ".claude.json"),
    installedPlugins: path.join(c, "plugins", "installed_plugins.json"),
    skillsDir: path.join(c, "skills"),
    agentsDir: path.join(c, "agents"),
    commandsDir: path.join(c, "commands"),
    rulesDir: path.join(c, "rules"),
  });
});

test("projectPaths", () => {
  const p = projectPaths(path.join("x", "proj"));
  expect(p).toEqual({
    settings: path.join("x", "proj", ".claude", "settings.json"),
    settingsLocal: path.join("x", "proj", ".claude", "settings.local.json"),
    mcpJson: path.join("x", "proj", ".mcp.json"),
    skillsDir: path.join("x", "proj", ".claude", "skills"),
  });
});

test("ocPaths ignores HOME and follows os.homedir() when XDG_DATA_HOME is unset", () => {
  const os = require("node:os");
  const d = ocPaths({ HOME: "/somewhere/else", USERPROFILE: "/other" });
  expect(d.dataDir).toBe(path.join(os.homedir(), ".local", "share", "opencode"));
});

test("sameDir: case-insensitive on win32 only", () => {
  expect(sameDir("C:\\Scratch\\X", "c:/scratch/x", "win32")).toBe(true);
  expect(sameDir("C:\\Scratch\\X\\", "c:/scratch/x", "win32")).toBe(true);
  expect(sameDir("C:\\Scratch\\X", "C:\\Scratch\\Y", "win32")).toBe(false);
  expect(sameDir("/home/X", "/home/x", "linux")).toBe(false);
  expect(sameDir("/home/x/", "/home/x", "linux")).toBe(true);
});

test("ocPaths: default data dir, CC_PARITY_STATE override, XDG_DATA_HOME", () => {
  const base = path.join(require("node:os").homedir(), ".local", "share", "opencode");
  const d = ocPaths({ HOME: "x/h" });
  expect(d.dataDir).toBe(base);
  expect(d.stateFile).toBe(path.join(base, "cc-parity-state.json"));
  expect(d.logFile).toBe(path.join(base, "cc-parity.log"));
  const o = ocPaths({ HOME: "x/h", CC_PARITY_STATE: "/s/state.json" });
  expect(o.stateFile).toBe("/s/state.json");
  expect(o.logFile).toBe(path.join(base, "cc-parity.log"));
  expect(ocPaths({ HOME: "x/h", XDG_DATA_HOME: "/xdg" }).dataDir).toBe(path.join("/xdg", "opencode"));
});

test("makeHome builds both trees (string and JSON) and cleanup removes them", () => {
  const m = makeHome({ "a/b.txt": "hi", "c.json": { k: 1 }, "project:p/q.txt": "pp" });
  const fs = require("node:fs");
  expect(fs.readFileSync(path.join(m.home, "a", "b.txt"), "utf8")).toBe("hi");
  expect(JSON.parse(fs.readFileSync(path.join(m.home, "c.json"), "utf8"))).toEqual({ k: 1 });
  expect(fs.readFileSync(path.join(m.projectDir, "p", "q.txt"), "utf8")).toBe("pp");
  m.cleanup();
  expect(fs.existsSync(m.home)).toBe(false);
  expect(fs.existsSync(m.projectDir)).toBe(false);
});
