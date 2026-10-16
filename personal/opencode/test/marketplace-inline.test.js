import { describe, test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { collectMcp } from "../core/mcp.js";
import { enumerate } from "../core/enumerate.js";
import { inlineEntry } from "../core/marketplace.js";
import { buildInventory } from "../core/inventory.js";

// D1 (0.12.1): a marketplace entry can declare components inline. CC 2.1.300 (fWn/Hoe): with no
// plugin.json at the install path the ENTRY is the manifest; with one, the entry's mcpServers and
// lspServers are ignored. {...root .mcp.json, ...manifest.mcpServers} (qot): the manifest wins.

const made = [];
const tmp = (prefix) => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  made.push(d);
  return d;
};
afterEach(() => {
  while (made.length) fs.rmSync(made.pop(), { recursive: true, force: true });
});
const write = (file, data) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, typeof data === "string" ? data : JSON.stringify(data));
};

// A fake ~/.claude with one marketplace "mk" and one plugin "inl" installed from it.
// files = extra files under the install path; entry = the marketplace entry for "inl".
function fixture({ entry, files = {}, marketplaceJson, knownMarketplaces } = {}) {
  const home = tmp("ccp-mk-home-");
  const mkDir = path.join(home, ".claude", "plugins", "marketplaces", "mk");
  const installPath = path.join(home, ".claude", "plugins", "cache", "mk", "inl", "1.0.0");
  fs.mkdirSync(installPath, { recursive: true });
  for (const [rel, c] of Object.entries(files)) write(path.join(installPath, rel), c);
  if (marketplaceJson === undefined) marketplaceJson = { name: "mk", plugins: [entry] };
  if (marketplaceJson !== null) write(path.join(mkDir, ".claude-plugin", "marketplace.json"), marketplaceJson);
  if (knownMarketplaces === undefined) knownMarketplaces = { mk: { source: { source: "github", repo: "o/r" }, installLocation: mkDir } };
  if (knownMarketplaces !== null) write(path.join(home, ".claude", "plugins", "known_marketplaces.json"), knownMarketplaces);
  const plugin = { key: "inl@mk", name: "inl", marketplace: "mk", version: "1.0.0", installPath, exists: true };
  return { home, installPath, plugin, mkDir };
}
const mcp = (f, extra = {}) => {
  const unknown = [];
  const servers = collectMcp({ trusted: true, claudeJson: {}, plugins: [f.plugin], home: f.home, unknown, ...extra });
  return { servers, unknown };
};
const ENTRY = (over = {}) => ({
  name: "inl",
  source: "./skills",
  mcpServers: { srv: { command: "${CLAUDE_PLUGIN_ROOT}/bin/run", args: ["--root", "${CLAUDE_PLUGIN_ROOT}"], env: { R: "${CLAUDE_PLUGIN_ROOT}" } } },
  ...over,
});

describe("inline marketplace mcpServers (no plugin.json)", () => {
  test("inline server is enumerated as plugin:<plugin>:<server>, ${CLAUDE_PLUGIN_ROOT} expanded", () => {
    const f = fixture({ entry: ENTRY() });
    const { servers, unknown } = mcp(f);
    expect(Object.keys(servers)).toEqual(["plugin:inl:srv"]);
    const s = servers["plugin:inl:srv"];
    expect(s.scope).toBe("plugin");
    expect(s.command).toBe(`${f.installPath}/bin/run`);
    expect(s.args).toEqual(["--root", f.installPath]);
    expect(s.env).toEqual({ R: f.installPath });
    expect(JSON.stringify(servers)).not.toContain("CLAUDE_PLUGIN_ROOT");
    expect(unknown).toEqual([]);
  });

  test("inline + file-declared: both present; on a name clash the entry wins (CC: manifest after .mcp.json)", () => {
    const f = fixture({
      entry: ENTRY({ mcpServers: { clash: { command: "from-entry" }, only_entry: { command: "e" } } }),
      files: { ".mcp.json": { mcpServers: { clash: { command: "from-file" }, only_file: { command: "f" } } } },
    });
    const { servers } = mcp(f);
    expect(Object.keys(servers).sort()).toEqual(["plugin:inl:clash", "plugin:inl:only_entry", "plugin:inl:only_file"]);
    expect(servers["plugin:inl:clash"].command).toBe("from-entry");
    expect(servers["plugin:inl:only_file"].command).toBe("f");
  });

  test("a plugin.json at the install path makes the entry's mcpServers inert (CC ignores them)", () => {
    const f = fixture({
      entry: ENTRY(),
      files: { ".claude-plugin/plugin.json": { name: "inl", mcpServers: { fromjson: { command: "j" } } } },
    });
    expect(Object.keys(mcp(f).servers)).toEqual(["plugin:inl:fromjson"]);
  });

  test("an inline path/array form is resolved inside the install path", () => {
    const f = fixture({
      entry: ENTRY({ mcpServers: ["./extra.json", { inl2: { command: "i" } }] }),
      files: { "extra.json": { mcpServers: { viafile: { command: "v" } } } },
    });
    expect(Object.keys(mcp(f).servers).sort()).toEqual(["plugin:inl:inl2", "plugin:inl:viafile"]);
  });

  test("without a home nothing is looked up (no read of the real ~/.claude)", () => {
    const f = fixture({ entry: ENTRY() });
    const servers = collectMcp({ trusted: true, claudeJson: {}, plugins: [f.plugin], unknown: [] });
    expect(servers).toEqual({});
  });

  test("the fixture control: the same entry is found by inlineEntry", () => {
    const f = fixture({ entry: ENTRY() });
    expect(inlineEntry(f.plugin, { home: f.home })?.name).toBe("inl");
  });
});

describe("inline marketplace entry fails closed", () => {
  const cases = {
    "marketplace.json missing": { marketplaceJson: null },
    "marketplace.json unparseable": { marketplaceJson: "{ not json" },
    "known_marketplaces.json missing": { knownMarketplaces: null },
    "marketplace not in known_marketplaces.json": { knownMarketplaces: { other: { installLocation: "/x" } } },
    "no entry with the plugin's name": { marketplaceJson: { name: "mk", plugins: [{ name: "someone-else", mcpServers: { a: { command: "a" } } }] } },
  };
  for (const [label, over] of Object.entries(cases)) {
    test(`${label}: reported, no crash, file-declared servers still enumerated`, () => {
      const f = fixture({ entry: ENTRY(), files: { ".mcp.json": { mcpServers: { keep: { command: "k" } } } }, ...over });
      const { servers, unknown } = mcp(f);
      expect(Object.keys(servers)).toEqual(["plugin:inl:keep"]);
      expect(unknown).toHaveLength(1);
      expect(unknown[0].key).toBe("plugin:inl:marketplace-entry");
      expect(unknown[0].note).toContain("inline mcpServers/lspServers not enumerated");
    });
  }
  test("a plugin.json present means the marketplace is never needed: nothing reported when it is missing", () => {
    const f = fixture({ entry: ENTRY(), marketplaceJson: null, knownMarketplaces: null, files: { ".claude-plugin/plugin.json": { name: "inl" } } });
    expect(mcp(f).unknown).toEqual([]);
  });
});

describe("inline lspServers are reported, never silently dropped", () => {
  const LSP = { lspServers: { gopls: { command: "gopls", extensionToLanguage: { ".go": "go" } } } };
  test("enumerate reports an inline lspServers as not translated", () => {
    const f = fixture({ entry: ENTRY({ mcpServers: undefined, ...LSP }) });
    const r = enumerate({ plugins: [f.plugin], home: f.home });
    const hit = r.filter((u) => u.where === "plugin:inl" && u.key === "marketplace-entry:lspServers");
    expect(hit).toHaveLength(1);
    expect(hit[0].note).toContain("not translated to OC");
    expect(JSON.stringify(r)).not.toContain("gopls");
  });
  test("a plugin.json present: the entry's lspServers is inert, so it is not reported from the entry", () => {
    const f = fixture({ entry: ENTRY({ ...LSP }), files: { ".claude-plugin/plugin.json": { name: "inl" } } });
    expect(enumerate({ plugins: [f.plugin], home: f.home }).filter((u) => u.key.includes("lspServers"))).toEqual([]);
  });
  test("lspServers in plugin.json is reported as not translated too", () => {
    const f = fixture({ entry: ENTRY(), files: { ".claude-plugin/plugin.json": { name: "inl", ...LSP } } });
    const hit = enumerate({ plugins: [f.plugin], home: f.home }).filter((u) => u.key === "plugin.json:lspServers");
    expect(hit).toHaveLength(1);
    expect(hit[0].note).toContain("not translated to OC");
  });
  test("an unknown field on an inline MCP server is flagged like a manifest one (drift alarm)", () => {
    const f = fixture({ entry: ENTRY({ mcpServers: { srv: { command: "c", brandNewField: 1 } } }) });
    const r = enumerate({ plugins: [f.plugin], home: f.home });
    expect(r.some((u) => u.where === "plugin:inl" && u.key === "mcp.*.brandNewField")).toBe(true);
  });
});

describe("D1b: other inline components of an entry-as-manifest are reported, never silently dropped", () => {
  const VALUES = { hooks: { PreToolUse: [] }, commands: ["./c.md"], agents: ["./a.md"], outputStyles: ["./o.md"], themes: ["./t.json"] };
  for (const [key, value] of Object.entries(VALUES)) {
    test(`inline ${key}: exactly one not-translated item for the plugin and key`, () => {
      const f = fixture({ entry: ENTRY({ [key]: value }) });
      const hit = enumerate({ plugins: [f.plugin], home: f.home }).filter((u) => u.where === "plugin:inl" && u.key === `marketplace-entry:${key}`);
      expect(hit).toHaveLength(1);
      expect(hit[0].note).toContain("not translated to OC");
    });
  }
  test("control: an entry with none of those keys reports no marketplace-entry item", () => {
    const f = fixture({ entry: ENTRY() });
    expect(enumerate({ plugins: [f.plugin], home: f.home }).filter((u) => u.key.startsWith("marketplace-entry:"))).toEqual([]);
  });
});

describe("buildInventory wiring (real chain, fixture home)", () => {
  test("an enabled plugin with only an inline mcpServers/lspServers entry yields an OC mcp server and an lsp report", () => {
    const f = fixture({ entry: ENTRY({ lspServers: { x: { command: "x" } } }) });
    write(path.join(f.home, ".claude", "settings.json"), { enabledPlugins: { "inl@mk": true } });
    write(path.join(f.home, ".claude", "plugins", "installed_plugins.json"), {
      version: 2,
      plugins: { "inl@mk": [{ scope: "user", installPath: f.installPath, version: "1.0.0" }] },
    });
    const proj = tmp("ccp-mk-proj-");
    const inv = buildInventory({ home: f.home, projectDir: proj, env: {} });
    expect(Object.keys(inv.mcp)).toEqual(["plugin:inl:srv"]);
    expect(inv.mcp["plugin:inl:srv"]).toMatchObject({ type: "local", command: [`${f.installPath}/bin/run`, "--root", f.installPath], enabled: true });
    expect(inv.unknown.filter((u) => u.where === "plugin:inl" && u.key === "marketplace-entry:lspServers")).toHaveLength(1);
  });
});
