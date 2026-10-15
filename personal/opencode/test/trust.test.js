import { describe, test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { makeHome } from "./helpers.js";
import { loadSettings, ccTrusted, UNTRUSTED_NOTE } from "../core/settings.js";
import { projectKey, collectMcp } from "../core/mcp.js";
import { buildInventory } from "../core/inventory.js";

// R47 (final review I2): project and projectLocal hooks, allow/ask rules and every other project
// setting load only when CC trusts the directory. Project DENY rules always load (fail closed).
// The trust walk mirrors CC 2.1.300's own (iO/Nm/Fm): from the directory up through its parents,
// stopping at the nearest `.git` (file or dir), else at the filesystem root.

let h;
afterEach(() => h && h.cleanup());

const g = (cmd) => [{ hooks: [{ type: "command", command: cmd }] }];
const PROJECT = {
  ".claude/settings.json": { permissions: { allow: ["Bash(ls)"], deny: ["Read(.env)"] }, hooks: { Stop: g("user-stop") } },
  "project:.claude/settings.json": {
    permissions: { allow: ["Bash(rm *)"], ask: ["Bash(curl *)"], deny: ["Read(secret.txt)"] },
    hooks: { SessionStart: g("proj-start") },
    env: { PROJ_ENV: "1" },
    enabledPlugins: { "evil@m": true },
    enableAllProjectMcpServers: true,
  },
  "project:.claude/settings.local.json": { permissions: { allow: ["Edit(**)"], deny: ["Edit(lock.json)"] }, hooks: { Stop: g("local-stop") } },
};
const trustJson = (dir, ok = true) => ({ projects: { [projectKey(dir)]: { hasTrustDialogAccepted: ok } } });
const writeClaudeJson = (data) => fs.writeFileSync(path.join(h.home, ".claude.json"), JSON.stringify(data));

describe("loadSettings: CC's trust gate (R47)", () => {
  test("untrusted: only project denies load; hooks, allows, asks and other keys are skipped and reported per directory", () => {
    h = makeHome(PROJECT); // no ~/.claude.json at all: CC has never opened the directory
    const r = loadSettings({ home: h.home, projectDir: h.projectDir });
    expect(r.trusted).toBe(false);
    expect(r.merged.permissions.deny).toEqual(["Read(.env)", "Read(secret.txt)", "Edit(lock.json)"]);
    expect(r.merged.permissions.allow).toEqual(["Bash(ls)"]);
    expect(r.merged.permissions.ask).toBeUndefined();
    expect(Object.keys(r.merged.hooks)).toEqual(["Stop"]);
    expect(r.merged.hooks.Stop.map((x) => x.hooks[0].command)).toEqual(["user-stop"]);
    for (const k of ["env", "enabledPlugins", "enableAllProjectMcpServers"]) expect(k in r.merged).toBe(false);
    const items = r.unknown.filter((u) => u.note === UNTRUSTED_NOTE);
    expect(items).toEqual([{ where: projectKey(h.projectDir), key: "project settings (untrusted)", note: UNTRUSTED_NOTE }]);
    expect(UNTRUSTED_NOTE).toStartWith("project settings not trusted in CC; hooks and allows skipped");
  });
  test("trusted: everything loads and nothing is reported", () => {
    h = makeHome(PROJECT);
    writeClaudeJson(trustJson(h.projectDir));
    const r = loadSettings({ home: h.home, projectDir: h.projectDir });
    expect(r.trusted).toBe(true);
    expect(r.merged.permissions.allow).toEqual(["Bash(ls)", "Bash(rm *)", "Edit(**)"]);
    expect(r.merged.permissions.ask).toEqual(["Bash(curl *)"]);
    expect(r.merged.hooks.SessionStart).toHaveLength(1);
    expect(r.merged.env).toEqual({ PROJ_ENV: "1" });
    expect(r.unknown).toEqual([]);
  });
  test("hasTrustDialogAccepted false, or any non-true value, is untrusted", () => {
    for (const v of [false, "true", 1, null]) {
      h = makeHome(PROJECT);
      writeClaudeJson({ projects: { [projectKey(h.projectDir)]: { hasTrustDialogAccepted: v } } });
      expect([v, loadSettings({ home: h.home, projectDir: h.projectDir }).trusted]).toEqual([v, false]);
      h.cleanup();
    }
    h = null;
  });
  test("a corrupt ~/.claude.json is untrusted (fails closed)", () => {
    h = makeHome({ ...PROJECT, ".claude.json": "{ not json" });
    expect(loadSettings({ home: h.home, projectDir: h.projectDir }).trusted).toBe(false);
  });
  test("the key matches CC's spelling: forward slashes, upper-case drive, no trailing slash", () => {
    h = makeHome(PROJECT);
    const k = projectKey(h.projectDir);
    expect(k.includes("\\")).toBe(false);
    expect(k.endsWith("/")).toBe(false);
    if (process.platform === "win32") expect(k).toMatch(/^[A-Z]:\//);
    writeClaudeJson({ projects: { [k]: { hasTrustDialogAccepted: true } } });
    expect(loadSettings({ home: h.home, projectDir: h.projectDir + path.sep }).trusted).toBe(true);
  });
  test("an explicit trusted override wins (tests and callers that already decided)", () => {
    h = makeHome(PROJECT);
    expect(loadSettings({ home: h.home, projectDir: h.projectDir, trusted: true }).merged.hooks.SessionStart).toHaveLength(1);
  });
  test("no project settings files: nothing to skip, nothing reported", () => {
    h = makeHome({ ".claude/settings.json": { model: "x" } });
    const r = loadSettings({ home: h.home, projectDir: h.projectDir });
    expect(r.trusted).toBe(false);
    expect(r.unknown).toEqual([]);
  });
  test("the report item is per directory: two untrusted directories give two distinct items", () => {
    h = makeHome(PROJECT);
    const other = path.join(h.projectDir, "nested-repo");
    fs.mkdirSync(path.join(other, ".claude"), { recursive: true });
    fs.mkdirSync(path.join(other, ".git"));
    fs.writeFileSync(path.join(other, ".claude", "settings.json"), JSON.stringify({ hooks: { Stop: g("x") } }));
    const a = loadSettings({ home: h.home, projectDir: h.projectDir }).unknown.filter((u) => u.note === UNTRUSTED_NOTE);
    const b = loadSettings({ home: h.home, projectDir: other }).unknown.filter((u) => u.note === UNTRUSTED_NOTE);
    expect(a).toHaveLength(1);
    expect(b).toHaveLength(1);
    expect(a[0].where).not.toBe(b[0].where);
  });
});

describe("ccTrusted: CC's parent walk, bounded by the nearest .git", () => {
  test("a trusted parent covers a subdirectory when no .git lies between", () => {
    h = makeHome();
    const sub = path.join(h.projectDir, "a", "b");
    fs.mkdirSync(sub, { recursive: true });
    expect(ccTrusted(trustJson(h.projectDir), sub)).toBe(true);
  });
  test("the walk stops at the git root: a trusted dir ABOVE the repo does not cover it (control: without .git it does)", () => {
    h = makeHome();
    const repo = path.join(h.projectDir, "repo");
    const sub = path.join(repo, "src");
    fs.mkdirSync(sub, { recursive: true });
    const cj = trustJson(h.projectDir);
    expect(ccTrusted(cj, sub)).toBe(true); // control: no .git -> the walk reaches the trusted parent
    fs.mkdirSync(path.join(repo, ".git"));
    expect(ccTrusted(cj, sub)).toBe(false);
    fs.rmSync(path.join(repo, ".git"), { recursive: true });
    fs.writeFileSync(path.join(repo, ".git"), "gitdir: elsewhere\n"); // a worktree's .git file
    expect(ccTrusted(cj, sub)).toBe(false);
    expect(ccTrusted(trustJson(repo), sub)).toBe(true); // the git root itself is checked
  });
  test("missing or malformed input is untrusted, never a throw", () => {
    for (const cj of [undefined, null, {}, { projects: null }, { projects: [] }, { projects: { x: null } }]) {
      expect(ccTrusted(cj, process.cwd())).toBe(false);
    }
  });
});

describe("collectMcp / inventory: an untrusted project's .mcp.json never starts (R47)", () => {
  test("user-level enableAllProjectMcpServers does not approve an untrusted project's .mcp.json", () => {
    h = makeHome({ "project:.mcp.json": { mcpServers: { proj: { command: "evil" } } } });
    const unknown = [];
    const out = collectMcp({ claudeJson: {}, projectDir: h.projectDir, settings: { enableAllProjectMcpServers: true }, unknown, trusted: false });
    expect("proj" in out).toBe(false);
    expect(unknown.map((u) => u.note).join("\n")).toContain("not trusted in CC");
    const ok = collectMcp({ claudeJson: {}, projectDir: h.projectDir, settings: { enableAllProjectMcpServers: true }, unknown: [], trusted: true });
    expect("proj" in ok).toBe(true);
  });
  test("end to end: an untrusted project's hooks and allows never reach the inventory; its deny does", () => {
    h = makeHome(PROJECT);
    const inv = buildInventory({ home: h.home, projectDir: h.projectDir, worktree: h.projectDir, env: {} });
    expect(inv.hooks.map((x) => x.command)).toEqual(["user-stop"]);
    expect(JSON.stringify(inv.permission.bash)).not.toContain("rm *");
    expect(inv.permission.read["secret.txt"]).toBe("deny");
    expect(inv.unknown.some((u) => u.note === UNTRUSTED_NOTE && u.where === projectKey(h.projectDir))).toBe(true);
    // ...and once CC trusts the directory, they do
    writeClaudeJson(trustJson(h.projectDir));
    const inv2 = buildInventory({ home: h.home, projectDir: h.projectDir, worktree: h.projectDir, env: {} });
    expect(inv2.hooks.map((x) => x.command).sort()).toEqual(["local-stop", "proj-start", "user-stop"]);
    expect(inv2.permission.bash["rm *"]).toBe("allow");
    expect(inv2.unknown.some((u) => u.note === UNTRUSTED_NOTE)).toBe(false);
  });
});

// Round 4 I-A: CC resolves a git worktree to its main repository (Sr behind qs/X1e in 2.1.300)
// and checks that key before the parent walk, so a trusted main repo covers its worktrees.
describe("ccTrusted: a git worktree is covered by its main repository's entry", () => {
  // main/.git/worktrees/wt1 holds commondir ("../..") and gitdir (back-link to wt/.git), as
  // `git worktree add` writes them; wt/.git is a FILE naming that gitdir.
  const mkWorktree = (base, { relative = false, commondir = "../..", back } = {}) => {
    const main = path.join(base, "main");
    const wt = path.join(base, "wt");
    const gd = path.join(main, ".git", "worktrees", "wt1");
    fs.mkdirSync(gd, { recursive: true });
    fs.mkdirSync(path.join(wt, "src"), { recursive: true });
    if (commondir !== null) fs.writeFileSync(path.join(gd, "commondir"), commondir + "\n");
    fs.writeFileSync(path.join(gd, "gitdir"), (back ?? path.join(wt, ".git")) + "\n");
    fs.writeFileSync(path.join(wt, ".git"), `gitdir: ${relative ? path.relative(wt, gd) : gd}\n`);
    return { main, wt, gd };
  };
  test("a trusted main repo covers its worktree and the worktree's subdirectories (control: untrusted main)", () => {
    h = makeHome();
    const { main, wt } = mkWorktree(h.projectDir);
    expect(ccTrusted(trustJson(main), wt)).toBe(true);
    expect(ccTrusted(trustJson(main), path.join(wt, "src"))).toBe(true);
    expect(ccTrusted(trustJson(main, false), wt)).toBe(false);
    expect(ccTrusted(trustJson(path.join(h.projectDir, "elsewhere")), wt)).toBe(false);
  });
  test("a relative gitdir: line resolves against the worktree root", () => {
    h = makeHome();
    const { main, wt } = mkWorktree(h.projectDir, { relative: true });
    expect(ccTrusted(trustJson(main), wt)).toBe(true);
  });
  test("end to end: a worktree of a trusted repo loads its project settings in full", () => {
    h = makeHome();
    const { main, wt } = mkWorktree(h.projectDir);
    fs.mkdirSync(path.join(wt, ".claude"), { recursive: true });
    fs.writeFileSync(path.join(wt, ".claude", "settings.json"), JSON.stringify({ permissions: { allow: ["Bash(ls)"] } }));
    expect(loadSettings({ home: h.home, projectDir: wt, claudeJson: trustJson(main) }).merged.permissions.allow).toEqual(["Bash(ls)"]);
    expect(loadSettings({ home: h.home, projectDir: wt, claudeJson: trustJson(main, false) }).merged.permissions).toBeUndefined();
  });
  test("fails closed: no commondir (a submodule's gitdir), a gitdir outside <common>/worktrees, a broken back-link, no gitdir: line", () => {
    h = makeHome();
    let w = mkWorktree(path.join(h.projectDir, "a"), { commondir: null });
    expect(ccTrusted(trustJson(w.main), w.wt)).toBe(false);
    // a commondir naming ANOTHER repo's .git: the gitdir is not in <that common>/worktrees
    const evil = path.join(h.projectDir, "b", "evil");
    w = mkWorktree(path.join(h.projectDir, "b"), { commondir: path.join(evil, ".git") });
    expect(ccTrusted(trustJson(evil), w.wt)).toBe(false);
    w = mkWorktree(path.join(h.projectDir, "c"), { back: path.join(h.projectDir, "c", "other", ".git") });
    expect(ccTrusted(trustJson(w.main), w.wt)).toBe(false);
    w = mkWorktree(path.join(h.projectDir, "d"));
    fs.writeFileSync(path.join(w.wt, ".git"), "not a gitdir line\n");
    expect(ccTrusted(trustJson(w.main), w.wt)).toBe(false);
    // control: the same shape, intact, is trusted
    w = mkWorktree(path.join(h.projectDir, "e"));
    expect(ccTrusted(trustJson(w.main), w.wt)).toBe(true);
  });
  test("a nested repo with its own .git DIRECTORY is not covered by a trusted parent", () => {
    h = makeHome();
    const nested = path.join(h.projectDir, "nested");
    fs.mkdirSync(path.join(nested, ".git"), { recursive: true });
    expect(ccTrusted(trustJson(h.projectDir), nested)).toBe(false);
    expect(ccTrusted(trustJson(nested), nested)).toBe(true);
  });
});
