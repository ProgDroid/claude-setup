import { test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { makeHome } from "./helpers.js";
import { enabledPlugins } from "../core/plugins.js";

let h;
afterEach(() => h && h.cleanup());

// Synthetic fixture of the measured installed_plugins.json shape (version 2).
function setup(enabled, records, { createDirs = [] } = {}) {
  h = makeHome({ ".claude/plugins/installed_plugins.json": { version: 2, plugins: records } });
  for (const d of createDirs) fs.mkdirSync(d, { recursive: true });
  return { home: h.home, merged: { enabledPlugins: enabled } };
}
const rec = (installPath, version = "1.0.0", scope = "user") => ({
  scope, installPath, version, installedAt: "2026-01-01T00:00:00Z", lastUpdated: "2026-01-02T00:00:00Z", gitCommitSha: "abc",
});

test("enabled and installed -> a Plugin record with exists:true", () => {
  const ip = path.join(fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ccp-ip-")), "p1");
  const a = setup({ "p1@mk": true }, { "p1@mk": [rec(ip, "2.3.4")] }, { createDirs: [ip] });
  const r = enabledPlugins(a);
  expect(r.plugins).toEqual([{ key: "p1@mk", name: "p1", marketplace: "mk", version: "2.3.4", installPath: ip, exists: true }]);
  expect(r.unknown).toEqual([]);
  fs.rmSync(path.dirname(ip), { recursive: true, force: true });
});

test("disabled (false) and installed-but-not-listed plugins are excluded", () => {
  const a = setup({ "off@mk": false }, { "off@mk": [rec("/nope")], "unlisted@mk": [rec("/nope")] });
  const r = enabledPlugins(a);
  expect(r.plugins).toEqual([]);
  expect(r.unknown).toEqual([]);
});

test("RF4: enabled with missing installPath -> plugin-missing, rest proceeds", () => {
  const ok = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ccp-ok-"));
  const gone = path.join(ok, "does-not-exist");
  const a = setup({ "gone@mk": true, "fine@mk": true }, { "gone@mk": [rec(gone)], "fine@mk": [rec(ok, "9")] });
  const r = enabledPlugins(a);
  const m = r.unknown.filter((u) => /plugin-missing/.test(u.note));
  expect(m).toHaveLength(1);
  expect(m[0].key).toBe("gone@mk");
  expect(m[0].where).toBe(gone);
  expect(r.plugins.map((p) => [p.key, p.exists])).toEqual([["gone@mk", false], ["fine@mk", true]]);
  fs.rmSync(ok, { recursive: true, force: true });
});

test("enabled but absent from installed_plugins.json -> plugin-missing, no Plugin", () => {
  const a = setup({ "ghost@mk": true }, {});
  const r = enabledPlugins(a);
  expect(r.plugins).toEqual([]);
  expect(r.unknown).toHaveLength(1);
  expect(r.unknown[0]).toMatchObject({ key: "ghost@mk" });
  expect(r.unknown[0].note).toMatch(/plugin-missing/);
});

test("@builtin -> no plugin, no plugin-missing, an ignored note", () => {
  const a = setup({ "thing@builtin": true }, {});
  const r = enabledPlugins(a);
  expect(r.plugins).toEqual([]);
  expect(r.unknown).toEqual([]);
  expect(r.ignored).toEqual([{ key: "thing@builtin", reason: "built into CC" }]);
});

test("@builtin with no installed_plugins.json at all stays silent", () => {
  h = makeHome({});
  const r = enabledPlugins({ home: h.home, merged: { enabledPlugins: { "x@builtin": true } } });
  expect(r.unknown).toEqual([]);
  expect(r.ignored).toHaveLength(1);
});

test("two-record entry (project + user scope) -> the user record is chosen", () => {
  const u = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ccp-u-"));
  const p = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ccp-p-"));
  const a = setup({ "dual@mk": true }, { "dual@mk": [rec(p, "PROJECT", "project"), rec(u, "USER", "user")] });
  const r = enabledPlugins(a);
  expect(r.plugins).toHaveLength(1);
  expect(r.plugins[0].version).toBe("USER");
  expect(r.plugins[0].installPath).toBe(u);
  fs.rmSync(u, { recursive: true, force: true });
  fs.rmSync(p, { recursive: true, force: true });
});

test("only a project-scope record -> not resolved (plugin-missing)", () => {
  const a = setup({ "projonly@mk": true }, { "projonly@mk": [rec("/x", "1", "project")] });
  const r = enabledPlugins(a);
  expect(r.plugins).toEqual([]);
  expect(r.unknown[0].note).toMatch(/plugin-missing/);
});

test("hash versions pass through untouched", () => {
  const d = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ccp-h-"));
  const a = setup({ "hh@mk": true }, { "hh@mk": [rec(d, "6a1f09c2e8b4")] });
  expect(enabledPlugins(a).plugins[0].version).toBe("6a1f09c2e8b4");
  fs.rmSync(d, { recursive: true, force: true });
});

test("names with '@' split on the last '@'", () => {
  const d = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ccp-n-"));
  const a = setup({ "a@b@mk": true }, { "a@b@mk": [rec(d)] });
  const p = enabledPlugins(a).plugins[0];
  expect([p.name, p.marketplace]).toEqual(["a@b", "mk"]);
  fs.rmSync(d, { recursive: true, force: true });
});

test("corrupt installed_plugins.json -> one unknown, no throw, builtin still ignored", () => {
  h = makeHome({ ".claude/plugins/installed_plugins.json": "{oops" });
  const merged = { enabledPlugins: { "a@mk": true, "b@builtin": true } };
  let r;
  expect(() => (r = enabledPlugins({ home: h.home, merged }))).not.toThrow();
  expect(r.plugins).toEqual([]);
  expect(r.unknown).toHaveLength(1);
  expect(r.unknown[0].where).toMatch(/installed_plugins\.json$/);
  expect(r.ignored).toHaveLength(1);
});

test("no enabledPlugins in merged -> empty result", () => {
  h = makeHome({});
  expect(enabledPlugins({ home: h.home, merged: {} })).toEqual({ plugins: [], unknown: [], ignored: [] });
});
