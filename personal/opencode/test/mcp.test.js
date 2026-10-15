import { describe, test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { collectMcp, toOcMcp, projectKey } from "../core/mcp.js";
import { ruleFiles } from "../core/rules.js";

const made = [];
const tmpDir = (prefix) => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  made.push(d);
  return d;
};
const write = (file, data) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, typeof data === "string" ? data : JSON.stringify(data));
};
afterEach(() => {
  while (made.length) fs.rmSync(made.pop(), { recursive: true, force: true });
});

// The form CC writes into ~/.claude.json `projects`: forward slashes, upper-case drive.
const ccKey = (dir) => dir.replace(/\\/g, "/").replace(/^([a-z]):/, (_, d) => `${d.toUpperCase()}:`);
const SECRET = "sekrit-value-0451";

describe("collectMcp: scoping with positive controls", () => {
  test("from a project that has .mcp.json (approved), its server is present", () => {
    const proj = tmpDir("ccp-mcp-p-");
    write(path.join(proj, ".mcp.json"), { mcpServers: { projsrv: { command: "p-cmd" } } });
    const claudeJson = { projects: { [ccKey(proj)]: { enabledMcpjsonServers: ["projsrv"] } } };
    const s = collectMcp({ trusted: true, claudeJson, projectDir: proj, plugins: [] });
    expect(s.projsrv).toMatchObject({ command: "p-cmd", scope: "project" });
  });
  test("enableAllProjectMcpServers in settings approves .mcp.json servers", () => {
    const proj = tmpDir("ccp-mcp-p-");
    write(path.join(proj, ".mcp.json"), { projsrv: { command: "p-cmd" } }); // bare-map form
    const s = collectMcp({ trusted: true, claudeJson: {}, projectDir: proj, plugins: [], settings: { enableAllProjectMcpServers: true } });
    expect(Object.keys(s)).toEqual(["projsrv"]);
  });
  test("an unapproved .mcp.json server is NOT started and is reported", () => {
    const proj = tmpDir("ccp-mcp-p-");
    write(path.join(proj, ".mcp.json"), { mcpServers: { projsrv: { command: "p-cmd" } } });
    const unknown = [];
    const s = collectMcp({ trusted: true, claudeJson: {}, projectDir: proj, plugins: [], unknown });
    expect(s).toEqual({});
    expect(unknown).toHaveLength(1);
    expect(unknown[0]).toMatchObject({ key: "projsrv" });
    expect(unknown[0].note).toContain("not approved");
  });
  test("from a project listed in .claude.json projects, that server is present", () => {
    const proj = tmpDir("ccp-mcp-q-");
    const claudeJson = { projects: { [ccKey(proj)]: { mcpServers: { localsrv: { type: "http", url: "https://x.test/mcp" } } } } };
    const s = collectMcp({ trusted: true, claudeJson, projectDir: proj, plugins: [] });
    expect(s.localsrv).toMatchObject({ url: "https://x.test/mcp", scope: "project" });
  });
  test("from elsewhere, neither project server is present (user scope still is)", () => {
    const projA = tmpDir("ccp-mcp-p-");
    const projB = tmpDir("ccp-mcp-q-");
    const elsewhere = tmpDir("ccp-mcp-e-");
    write(path.join(projA, ".mcp.json"), { mcpServers: { projsrv: { command: "p-cmd" } } });
    const claudeJson = {
      mcpServers: { usersrv: { command: "u-cmd" } },
      projects: {
        [ccKey(projA)]: { enabledMcpjsonServers: ["projsrv"] },
        [ccKey(projB)]: { mcpServers: { localsrv: { command: "l-cmd" } } },
      },
    };
    const s = collectMcp({ trusted: true, claudeJson, projectDir: elsewhere, plugins: [] });
    expect(Object.keys(s)).toEqual(["usersrv"]);
    expect(s.usersrv.scope).toBe("user");
  });
  test("the projects key matches with backslashes, a trailing slash and either drive-letter case", () => {
    const proj = tmpDir("ccp-mcp-q-");
    const claudeJson = { projects: { [ccKey(proj)]: { mcpServers: { localsrv: { command: "l" } } } } };
    const variants = [proj, proj + path.sep, proj.replace(/\\/g, "/")];
    if (/^[A-Za-z]:/.test(proj)) {
      variants.push(proj[0].toLowerCase() + proj.slice(1), proj[0].toUpperCase() + proj.slice(1));
    }
    for (const v of variants) expect(Object.keys(collectMcp({ trusted: true, claudeJson, projectDir: v, plugins: [] }))).toEqual(["localsrv"]);
  });
  test.if(process.platform === "win32")("a lower-case drive in the stored key also matches an upper-case projectDir", () => {
    const proj = tmpDir("ccp-mcp-q-");
    const lower = proj.replace(/\\/g, "/").replace(/^([A-Za-z]):/, (_, d) => `${d.toLowerCase()}:`);
    const claudeJson = { projects: { [lower]: { mcpServers: { localsrv: { command: "l" } } } } };
    const upper = proj[0].toUpperCase() + proj.slice(1);
    expect(Object.keys(collectMcp({ trusted: true, claudeJson, projectDir: upper, plugins: [] }))).toEqual(["localsrv"]);
  });
  test("projectKey normalises separators, trailing slash and the drive letter only", () => {
    expect(projectKey("c:\\Work\\Proj\\")).toBe("C:/Work/Proj");
    expect(projectKey("C:/Work/Proj")).toBe("C:/Work/Proj");
    expect(projectKey("/home/u/proj/")).toBe("/home/u/proj");
    expect(projectKey("c:\\")).toBe("C:/");
  });
});

describe("collectMcp: precedence, disables, plugins", () => {
  test("project > user on a name collision; the projects entry beats .mcp.json", () => {
    const proj = tmpDir("ccp-mcp-p-");
    write(path.join(proj, ".mcp.json"), { mcpServers: { dup: { command: "from-mcpjson" }, dup2: { command: "from-mcpjson" } } });
    const claudeJson = {
      mcpServers: { dup: { command: "from-user" }, dup2: { command: "from-user" } },
      projects: { [ccKey(proj)]: { enabledMcpjsonServers: ["dup", "dup2"], mcpServers: { dup: { command: "from-local" } } } },
    };
    const s = collectMcp({ trusted: true, claudeJson, projectDir: proj, plugins: [] });
    expect(s.dup).toMatchObject({ command: "from-local", scope: "project" });
    expect(s.dup2).toMatchObject({ command: "from-mcpjson", scope: "project" });
  });
  test("user > plugin on a name collision", () => {
    const plug = tmpDir("ccp-mcp-plug-");
    write(path.join(plug, ".mcp.json"), { mcpServers: { srv: { command: "from-plugin" } } });
    const plugins = [{ key: "pl@m", name: "pl", installPath: plug, exists: true }];
    const s = collectMcp({ trusted: true, claudeJson: { mcpServers: { "plugin:pl:srv": { command: "from-user" } } }, projectDir: plug, plugins });
    expect(s["plugin:pl:srv"]).toMatchObject({ command: "from-user", scope: "user" });
  });
  test("disabledMcpServers and disabledMcpjsonServers drop servers", () => {
    const proj = tmpDir("ccp-mcp-p-");
    write(path.join(proj, ".mcp.json"), { mcpServers: { a: { command: "a" }, b: { command: "b" } } });
    const claudeJson = {
      mcpServers: { u: { command: "u" }, v: { command: "v" } },
      projects: { [ccKey(proj)]: { enabledMcpjsonServers: ["a", "b"], disabledMcpjsonServers: ["b"], disabledMcpServers: ["v"] } },
    };
    expect(Object.keys(collectMcp({ trusted: true, claudeJson, projectDir: proj, plugins: [] })).sort()).toEqual(["a", "u"]);
  });
  test("plugin servers are named plugin:<plugin>:<server> (CC's naming) with ${CLAUDE_PLUGIN_ROOT} substituted", () => {
    const plug = path.join(tmpDir("ccp-mcp-plug-"), "with space", "1.0.0");
    write(path.join(plug, ".mcp.json"), {
      mcpServers: {
        guardian: { command: "${CLAUDE_PLUGIN_ROOT}/scripts/hook", args: ["--root=${CLAUDE_PLUGIN_ROOT}"], env: { R: "${CLAUDE_PLUGIN_ROOT}/x" } },
      },
    });
    write(path.join(plug, ".claude-plugin", "plugin.json"), { name: "sg", mcpServers: { inline: { type: "http", url: "https://i.test" } } });
    const plugins = [{ key: "sg@m", name: "sg", installPath: plug, exists: true }];
    const s = collectMcp({ trusted: true, claudeJson: {}, projectDir: os.tmpdir(), plugins });
    expect(Object.keys(s).sort()).toEqual(["plugin:sg:guardian", "plugin:sg:inline"]);
    const g = s["plugin:sg:guardian"];
    expect(g.scope).toBe("plugin");
    expect(g.command).toBe(`${plug}/scripts/hook`);
    expect(g.args).toEqual([`--root=${plug}`]);
    expect(g.env).toEqual({ R: `${plug}/x` });
    expect(JSON.stringify(s)).not.toContain("CLAUDE_PLUGIN_ROOT");
  });
  test("plugin manifest mcpServers given as a path is read too", () => {
    const plug = tmpDir("ccp-mcp-plug-");
    write(path.join(plug, ".claude-plugin", "plugin.json"), { name: "p2", mcpServers: "./servers.json" });
    write(path.join(plug, "servers.json"), { mcpServers: { s1: { command: "c" } } });
    const s = collectMcp({ trusted: true, claudeJson: {}, projectDir: os.tmpdir(), plugins: [{ key: "p2@m", name: "p2", installPath: plug, exists: true }] });
    expect(Object.keys(s)).toEqual(["plugin:p2:s1"]);
  });
  test("a missing plugin, unreadable files and a missing claudeJson are tolerated", () => {
    const s = collectMcp({ trusted: true, claudeJson: undefined, projectDir: os.tmpdir(), plugins: [{ key: "x@m", name: "x", installPath: path.join(os.tmpdir(), "nope-ccp"), exists: false }] });
    expect(s).toEqual({});
  });
  test("the input objects are not mutated", () => {
    const claudeJson = { mcpServers: { u: { command: "u", args: ["a"] } } };
    const snap = JSON.stringify(claudeJson);
    const s = collectMcp({ trusted: true, claudeJson, projectDir: os.tmpdir(), plugins: [] });
    s.u.args.push("b");
    expect(JSON.stringify(claudeJson)).toBe(snap);
  });
});

describe("toOcMcp", () => {
  test("stdio (explicit or absent type) -> local with a command array", () => {
    const { mcp, unknown } = toOcMcp({
      a: { type: "stdio", command: "srv", args: ["x", "y"], env: { K: SECRET }, scope: "user" },
      b: { command: "srv2", scope: "plugin" },
    });
    expect(unknown).toEqual([]);
    expect(mcp.a).toEqual({ type: "local", command: ["srv", "x", "y"], environment: { K: SECRET }, enabled: true });
    expect(mcp.b).toEqual({ type: "local", command: ["srv2"], enabled: true });
  });
  test("http and sse -> remote with headers", () => {
    const { mcp } = toOcMcp({
      h: { type: "http", url: "https://h.test/mcp", headers: { Authorization: SECRET } },
      s: { type: "sse", url: "https://s.test/sse" },
    });
    expect(mcp.h).toEqual({ type: "remote", url: "https://h.test/mcp", headers: { Authorization: SECRET }, enabled: true });
    expect(mcp.s).toEqual({ type: "remote", url: "https://s.test/sse", enabled: true });
  });
  test("any other type, or a server missing its command/url, is unknown and never echoes values", () => {
    const { mcp, unknown } = toOcMcp({
      w: { type: "ws", url: "wss://x", headers: { T: SECRET } },
      n: { type: "stdio", env: { K: SECRET } },
      r: { type: "http", headers: { T: SECRET } },
    });
    expect(mcp).toEqual({});
    expect(unknown.map((u) => u.key)).toEqual(["w", "n", "r"]);
    expect(JSON.stringify(unknown)).not.toContain(SECRET);
  });
  test("serena override: --context=claude-code -> --context=agent, tagged", () => {
    const { mcp } = toOcMcp({ serena: { command: "serena", args: ["start-mcp-server", "--context=claude-code", "--project-from-cwd"] } });
    expect(mcp.serena.command).toEqual(["serena", "start-mcp-server", "--context=agent", "--project-from-cwd"]);
    expect(mcp.serena.override).toBe("serena-context");
  });
  test("serena override handles the two-token form too", () => {
    const { mcp } = toOcMcp({ s: { command: "uvx", args: ["serena", "start-mcp-server", "--context", "claude-code"] } });
    expect(mcp.s.command).toEqual(["uvx", "serena", "start-mcp-server", "--context", "agent"]);
    expect(mcp.s.override).toBe("serena-context");
  });
  test("no serena flag, no override", () => {
    const { mcp } = toOcMcp({ s: { command: "uvx", args: ["serena", "start-mcp-server"] }, o: { command: "other", args: ["--context=claude-code"] } });
    expect(mcp.s.override).toBeUndefined();
    expect(mcp.o.override).toBeUndefined();
    expect(mcp.o.command).toEqual(["other", "--context=claude-code"]);
  });
  test("${VAR} and ${VAR:-default} expand from env; a missing var skips the server, reported by name only", () => {
    const env = { TOKEN_X: SECRET, HOSTX: "h.test" };
    const { mcp, unknown } = toOcMcp({
      r: { type: "http", url: "https://${HOSTX}/mcp", headers: { A: "Bearer ${TOKEN_X}", B: "${NOPE:-dflt}" } },
      l: { command: "c", env: { K: "${MISSING_VAR}" } },
    }, { env });
    expect(mcp.r).toEqual({ type: "remote", url: "https://h.test/mcp", headers: { A: `Bearer ${SECRET}`, B: "dflt" }, enabled: true });
    expect(mcp.l).toBeUndefined();
    expect(unknown).toHaveLength(1);
    expect(unknown[0]).toMatchObject({ key: "l" });
    expect(unknown[0].note).toContain("MISSING_VAR");
    expect(JSON.stringify(unknown)).not.toContain(SECRET);
  });
  test("the scope field never reaches OC config", () => {
    const { mcp } = toOcMcp({ a: { command: "c", scope: "user" } });
    expect("scope" in mcp.a).toBe(false);
  });
});

describe("ruleFiles", () => {
  test("returns the absolute .md paths, sorted, recursively; nothing else", () => {
    const home = tmpDir("ccp-rules-");
    const dir = path.join(home, ".claude", "rules");
    write(path.join(dir, "b.md"), "b");
    write(path.join(dir, "a.md"), "a");
    write(path.join(dir, "notes.txt"), "x");
    write(path.join(dir, "sub", "c.md"), "c");
    fs.mkdirSync(path.join(dir, "dir.md"));
    const r = ruleFiles(home);
    expect(r).toEqual([path.join(dir, "a.md"), path.join(dir, "b.md"), path.join(dir, "sub", "c.md")]);
    expect(r.every((p) => path.isAbsolute(p))).toBe(true);
  });
  test("a missing rules dir yields []", () => {
    expect(ruleFiles(tmpDir("ccp-rules-"))).toEqual([]);
  });
});
