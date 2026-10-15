import { test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { makeHome } from "./helpers.js";
import { evaluate, fromConfig, defaults } from "./oc-matcher.js";
import { collectAgents, parseFrontmatter, mapModel, mapTool, COMMAND_SEP } from "../core/agents.js";

let h;
afterEach(() => h && h.cleanup());

const plug = (name, installPath, exists = true) => ({ key: `${name}@mk`, name, marketplace: "mk", installPath, exists });

// The agent's effective ruleset the way OC merges it: defaults -> user -> agent.
const TOOLS = ["bash", "read", "edit", "write", "grep", "glob", "task", "webfetch", "todowrite", "skill", "srv_other_tool"];
function enabled(agentPermission, user = {}, home = "/h") {
  const rules = [defaults(home), fromConfig(user, home), fromConfig(agentPermission || {}, home)];
  const key = (t) => (t === "write" ? "edit" : t);
  return TOOLS.filter((t) => evaluate(key(t), "*", ...rules).action !== "deny");
}
const one = (md, opts = {}) => {
  h = makeHome({ ".claude/agents/a.md": md });
  return collectAgents({ home: h.home, projectDir: h.projectDir, ...opts });
};

test("(a) extractor shape: a single MCP tool -> only it is enabled, everything else denied; first key is *", () => {
  const r = one("---\nname: a\ndescription: d\ntools: mcp__scraper__get_page\n---\nB");
  const p = r.agent.a.permission;
  expect(Object.keys(p)[0]).toBe("*");
  expect(p["*"]).toBe("deny");
  expect("tools" in r.agent.a).toBe(false);
  expect(p.scraper_get_page).toBe("allow");
  const on = enabled(p);
  expect(on).toEqual([]); // none of the built-ins
  expect(evaluate("scraper_get_page", "*", defaults("/h"), fromConfig(p, "/h")).action).toBe("allow");
  // the broken (pre-fix) shape, `tools` only, would leave all built-ins enabled
  expect(enabled({}).length).toBe(TOOLS.length);
});

test("(b) a Read/Grep/Glob agent: bash, edit, write denied; read, grep, glob enabled", () => {
  const r = one("---\nname: a\ntools: Read, Grep, Glob\n---\nB");
  const on = enabled(r.agent.a.permission);
  expect(on).toEqual(["read", "grep", "glob"]);
  expect(r.unknown).toEqual([]);
});

test("(c) a user bash deny survives inside an agent that allows Bash; default read .env ask kept", () => {
  const user = { bash: { "*": "ask", "rm *": "deny" } };
  const r = one("---\nname: a\ntools: Bash, Read\n---\nB", { userPermission: user });
  const p = r.agent.a.permission;
  expect(p.bash).toEqual({ "*": "ask", "rm *": "deny" });
  expect(p.bash).not.toBe(user.bash);
  const rules = [defaults("/h"), fromConfig(user, "/h"), fromConfig(p, "/h")];
  expect(evaluate("bash", "rm -rf x", ...rules).action).toBe("deny");
  expect(evaluate("bash", "ls", ...rules).action).toBe("ask");
  expect(evaluate("read", "/p/.env", ...rules).action).toBe("ask");
  expect(evaluate("read", "/p/a.txt", ...rules).action).toBe("allow");
  // without a user rule it is a bare allow
  expect(one("---\nname: a\ntools: Bash\n---\nB").agent.a.permission.bash).toBe("allow");
});

test("user external_directory is carried into the agent permission", () => {
  const r = one("---\nname: a\ntools: Read\n---\nB", { userPermission: { external_directory: { "*": "deny" } } });
  expect(r.agent.a.permission.external_directory).toEqual({ "*": "deny" });
});

test("(d) all-unmappable tools -> deny-all kept, agent present, unknown reported", () => {
  const r = one("---\nname: a\ntools: PowerShell, NotebookEdit\n---\nB");
  expect(r.agent.a.permission).toEqual({ "*": "deny" });
  expect(enabled(r.agent.a.permission)).toEqual([]);
  expect(r.unknown.length).toBe(2);
});

test("an agent with no tools: gets no permission override", () => {
  expect("permission" in one("---\nname: a\n---\nB").agent.a).toBe(false);
});

test("a partly unmappable list: known tools kept, unknown reported", () => {
  const r = one("---\nname: a\ntools: Read, PowerShell\n---\nB");
  expect(enabled(r.agent.a.permission)).toEqual(["read"]);
  expect(r.unknown.map((u) => u.note)).toEqual(["tool PowerShell has no OC tool"]);
});

test("Edit without Write is reported (one OC edit permission); Edit+Write is not", () => {
  expect(one("---\nname: a\ntools: Edit\n---\nB").unknown.length).toBe(1);
  expect(one("---\nname: a\ntools: Edit, Write\n---\nB").unknown).toEqual([]);
});

test("MCP server-level form mcp__srv__* -> srv_*", () => {
  const r = one("---\nname: a\ntools: mcp__srv__*, mcp__other\n---\nB");
  expect(Object.keys(r.agent.a.permission)).toEqual(["*", "srv_*", "other_*", "external_directory", "invalid", "execute"]);
  expect(evaluate("srv_other_tool", "*", fromConfig(r.agent.a.permission, "/h")).action).toBe("allow");
});

test("disallowedTools -> per-agent deny keys; unmappable -> unknown; combines with tools", () => {
  const r = one("---\nname: a\ndisallowedTools: Bash, PowerShell\n---\nB");
  expect(r.agent.a.permission).toEqual({ bash: "deny" });
  expect(r.unknown.map((u) => u.note)).toEqual(["disallowed tool PowerShell has no OC tool"]);
  const r2 = one("---\nname: a\ntools: Read, Bash\ndisallowedTools: Bash\n---\nB");
  expect(enabled(r2.agent.a.permission)).toEqual(["read"]);
});

test("(I1) unknown frontmatter keys are reported for agents and commands; ignore list is silent", () => {
  h = makeHome({
    ".claude/agents/a.md": "---\nname: a\ndescription: d\ncolor: red\nmodel: haiku\nhooks: x\npermissionMode: plan\nmcpServers: y\n---\nB",
    ".claude/commands/c.md": "---\ndescription: d\nargument-hint: x\ncontext: fork\nagent: foo\n---\nB",
  });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.unknown.map((u) => u.note).sort()).toEqual([
    "agent has no OC command equivalent",
    "context has no OC command equivalent",
    "hooks has no OC agent equivalent",
    "mcpServers has no OC agent equivalent",
    "permissionMode has no OC agent equivalent",
  ]);
  expect(r.agent.a.model).toBe("anthropic/claude-haiku-5-5");
  expect(r.command.c.template).toBe("B");
});

test("(I2) ${CLAUDE_PLUGIN_ROOT} and ${CLAUDE_PROJECT_DIR} are substituted at translation time", () => {
  h = makeHome({ "pl/commands/run.md": "---\ndescription: d\n---\nrun ${CLAUDE_PLUGIN_ROOT}/bin/x in ${CLAUDE_PROJECT_DIR} with $ARGUMENTS" });
  const root = path.join(h.home, "pl");
  const r = collectAgents({ home: h.home, projectDir: h.projectDir, plugins: [plug("acme", root)] });
  expect(r.command["acme:run"].template).toBe(`run ${root}/bin/x in ${h.projectDir} with $ARGUMENTS`);
  expect(r.unknown).toEqual([]);
});

test("(I2) other ${CLAUDE_*} -> unknown for that command, command still added; ${other} untouched", () => {
  h = makeHome({ ".claude/commands/s.md": "id ${CLAUDE_SESSION_ID} and ${chosen_style} and ${CLAUDE_PLUGIN_ROOT}" });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.command.s.template).toBe("id ${CLAUDE_SESSION_ID} and ${chosen_style} and ${CLAUDE_PLUGIN_ROOT}");
  expect(r.unknown.map((u) => u.note)).toEqual(["${CLAUDE_SESSION_ID} has no OC equivalent", "${CLAUDE_PLUGIN_ROOT} has no OC equivalent"]);
});

test("(I2) CC 0-based $N and $ARGUMENTS[N] -> OC 1-based; $ARGUMENTS untouched; git:pr shape", () => {
  h = makeHome({ ".claude/commands/git/pr.md": "TO: $1 (main)\nFROM: $2\nfirst $0 / $ARGUMENTS[0] / $ARGUMENTS[2] / all $ARGUMENTS" });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.command["git:pr"].template).toBe("TO: $2 (main)\nFROM: $3\nfirst $1 / $1 / $3 / all $ARGUMENTS");
  expect(r.unknown).toEqual([]);
});

test("(I2) $N inside single quotes (awk) is reported; escaped \\$N is reported and left", () => {
  h = makeHome({ ".claude/commands/g.md": "git branch | awk '{print $1}'\nprice \\$1.00" });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.command.g.template).toBe("git branch | awk '{print $2}'\nprice \\$1.00");
  expect(r.unknown.map((u) => u.note).length).toBe(2);
});

test("model map: haiku/sonnet/opus, inherit and absent omit, full id, junk -> unknown", () => {
  h = makeHome({
    ".claude/agents/h.md": "---\nname: h\nmodel: haiku\n---\nB",
    ".claude/agents/s.md": "---\nname: s\nmodel: sonnet\n---\nB",
    ".claude/agents/o.md": "---\nname: o\nmodel: opus\n---\nB",
    ".claude/agents/n.md": "---\nname: n\nmodel: inherit\n---\nB",
    ".claude/agents/z.md": "---\nname: z\n---\nB",
    ".claude/agents/f.md": "---\nname: f\nmodel: claude-opus-5-5\n---\nB",
    ".claude/agents/j.md": "---\nname: j\nmodel: gpt-9\n---\nB",
  });
  const { agent, unknown } = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(agent.h.model).toBe("anthropic/claude-haiku-5-5");
  expect(agent.s.model).toBe("anthropic/claude-sonnet-5-5");
  expect(agent.o.model).toBe("anthropic/claude-opus-5-5");
  expect(agent.f.model).toBe("anthropic/claude-opus-5-5");
  expect("model" in agent.n).toBe(false);
  expect("model" in agent.z).toBe(false);
  expect("model" in agent.j).toBe(false);
  expect(unknown.map((u) => u.key)).toEqual(["agent:j"]);
});

test("mapModel and mapTool units", () => {
  expect(mapModel(undefined)).toEqual({});
  expect(mapModel("haiku")).toEqual({ value: "anthropic/claude-haiku-5-5" });
  expect(mapModel("weird").unknown).toBeTruthy();
  expect(mapTool("Bash")).toBe("bash");
  expect(mapTool("Task")).toBe("task");
  expect(mapTool("apply_patch")).toBeNull();
  expect(mapTool("PowerShell")).toBeNull();
  expect(mapTool("mcp__plugin_qmd_qmd__query")).toBe("plugin_qmd_qmd_query");
  expect(mapTool("mcp__s__do.it")).toBe("s_do_it");
  expect(mapTool("mcp__s__*")).toBe("s_*");
  expect(mapTool("Agent")).toBe("task");
});

test("multi-line description (folded and literal), quoted values, CRLF, BOM", () => {
  h = makeHome({
    ".claude/agents/f.md": "﻿---\r\nname: \"quoted-name\"\r\ndescription: >\r\n  one\r\n  two\r\ntools: 'Read, Bash'\r\n---\r\nline1\r\nline2",
    ".claude/agents/p.md": "---\nname: p\ndescription: plain start\n  continues here\n---\nB",
    ".claude/agents/l.md": "---\nname: l\ndescription: |\n  a\n  b\n---\nB",
  });
  const { agent } = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(agent["quoted-name"].description).toBe("one two");
  expect(Object.keys(agent["quoted-name"].permission)).toEqual(["*", "read", "bash", "external_directory", "invalid"]);
  expect(agent["quoted-name"].prompt).toBe("line1\r\nline2");
  expect(agent.p.description).toBe("plain start continues here");
  expect(agent.l.description).toBe("a\nb");
});

test("name falls back to the file basename; colour is ignored", () => {
  h = makeHome({ ".claude/agents/fallback.md": "---\ndescription: d\ncolor: red\n---\nB" });
  const { agent, unknown } = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(Object.keys(agent)).toEqual(["fallback"]);
  expect(JSON.stringify(agent.fallback)).not.toContain("red");
  expect(unknown).toEqual([]);
});

test("plugin agents are prefixed <plugin>-<name>; commands <plugin>:<path>", () => {
  h = makeHome({
    "pl/agents/rev.md": "---\nname: reviewer\ndescription: r\n---\nP",
    "pl/commands/sub/go.md": "---\ndescription: g\n---\nGO",
  });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir, plugins: [plug("acme", path.join(h.home, "pl"))] });
  expect(Object.keys(r.agent)).toEqual(["acme-reviewer"]);
  expect(Object.keys(r.command)).toEqual(["acme:sub:go"]);
});

test("a nested command commands/git/cm.md -> git:cm (row 2: colon accepted); $ARGUMENTS kept verbatim", () => {
  expect(COMMAND_SEP).toBe(":");
  const body = "Commit $ARGUMENTS now\n\nSecond line $ARGUMENTS\n";
  h = makeHome({ ".claude/commands/git/cm.md": `---\ndescription: Commit\nallowed-tools: Bash(git add:*), Bash(git commit:*)\nmodel: sonnet\n---\n${body}` });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.command["git:cm"]).toEqual({ description: "Commit", template: body, model: "anthropic/claude-sonnet-5-5" });
  expect(r.unknown).toEqual([
    { where: path.join(h.home, ".claude", "commands", "git", "cm.md"), key: "command:git:cm", note: "allowed-tools has no OC command equivalent" },
  ]);
});

test("allowed-tools written as a YAML list is also reported; a command without frontmatter is all template", () => {
  h = makeHome({
    ".claude/commands/a.md": "---\nallowed-tools:\n  - Read\n  - Edit\n---\nX",
    ".claude/commands/b.md": "no frontmatter $ARGUMENTS",
  });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.command.a.template).toBe("X");
  expect(r.command.b).toEqual({ template: "no frontmatter $ARGUMENTS" });
  expect(r.unknown.map((u) => u.key)).toEqual(["command:a"]);
});

test("unparseable frontmatter is reported as unknown and the item is still added", () => {
  h = makeHome({
    ".claude/agents/bad.md": "---\nname: bad\nthis line has no colon\nmodel: {a: b}\n---\nB",
    ".claude/commands/open.md": "---\ndescription: never closed\nBODY",
  });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.agent.bad.prompt).toBe("B");
  expect(r.unknown.filter((u) => u.key === "agent:bad").length).toBe(2);
  expect(r.command.open.template).toContain("BODY");
  expect(r.unknown.some((u) => u.key === "command:open")).toBe(true);
});

test("a missing plugin and exists:false are not read; a plugin without agents/commands adds nothing", () => {
  h = makeHome({ "empty/README.md": "x" });
  const r = collectAgents({
    home: h.home,
    projectDir: h.projectDir,
    plugins: [plug("gone", path.join(h.home, "nope"), false), plug("empty", path.join(h.home, "empty"))],
  });
  expect(r).toEqual({ agent: {}, command: {}, unknown: [] });
});

test("precedence: project beats user beats plugin for the same name", () => {
  h = makeHome({
    "pl/commands/x.md": "plugin",
    ".claude/commands/acme:x.md": "ignored-name-shape",
    "project:.claude/agents/dup.md": "---\nname: dup\ndescription: proj\n---\nP",
    ".claude/agents/dup.md": "---\nname: dup\ndescription: user\n---\nU",
  });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(r.agent.dup.description).toBe("proj");
});

test("projectDir === home loads the project scope once (no duplicate scope)", () => {
  h = makeHome({ ".claude/agents/a.md": "---\nname: a\ntools: PowerShell\n---\nB" });
  const r = collectAgents({ home: h.home, projectDir: h.home });
  expect(r.unknown.length).toBe(1);
});

test("a non-.md file and a subdirectory in agents/ are ignored", () => {
  h = makeHome({ ".claude/agents/a.md": "---\nname: a\n---\nB", ".claude/agents/notes.txt": "x", ".claude/agents/sub/b.md": "---\nname: b\n---\nB" });
  expect(Object.keys(collectAgents({ home: h.home, projectDir: h.projectDir }).agent)).toEqual(["a"]);
});

test("parseFrontmatter: no frontmatter -> whole text is body", () => {
  expect(parseFrontmatter("hello")).toEqual({ fm: {}, body: "hello", problems: [] });
});

test("symlinked agents dir (as in the live setup) is followed", () => {
  h = makeHome({ "real/agents/a.md": "---\nname: a\n---\nB" });
  fs.mkdirSync(path.join(h.home, ".claude"), { recursive: true });
  try {
    fs.symlinkSync(path.join(h.home, "real", "agents"), path.join(h.home, ".claude", "agents"), "junction");
  } catch {
    return;
  }
  expect(Object.keys(collectAgents({ home: h.home, projectDir: h.projectDir }).agent)).toEqual(["a"]);
});

test("tools as a YAML list and as inline [a, b]; MCP tool -> <server>_<tool> permission keys", () => {
  h = makeHome({
    ".claude/agents/l.md": "---\nname: l\ntools:\n  - Read\n  - \"Glob\"\n---\nB",
    ".claude/agents/i.md": "---\nname: i\ntools: [Edit, mcp__my-srv__do_it]\n---\nB",
  });
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(Object.keys(r.agent.l.permission)).toEqual(["*", "read", "glob", "external_directory", "invalid"]);
  expect(Object.keys(r.agent.i.permission)).toEqual(["*", "edit", "my-srv_do_it", "external_directory", "invalid", "execute"]);
});

test("(N1) extractor shape gets execute allowed; other MCP tools stay denied (OC matcher)", () => {
  const r = one("---\nname: a\ntools: mcp__scraper__get_page\n---\nB");
  const p = r.agent.a.permission;
  expect(p.execute).toBe("allow");
  const rules = [defaults("/h"), fromConfig(p, "/h")];
  expect(evaluate("execute", "*", ...rules).action).toBe("allow");
  expect(evaluate("scraper_get_page", "*", ...rules).action).toBe("allow");
  expect(evaluate("scraper_other_tool", "*", ...rules).action).toBe("deny");
  expect(evaluate("bash", "*", ...rules).action).toBe("deny");
});

test("(N1) an agent without MCP tools gets no execute", () => {
  expect("execute" in one("---\nname: a\ntools: Read, Bash\n---\nB").agent.a.permission).toBe(false);
  expect("execute" in one("---\nname: a\ndisallowedTools: Bash\n---\nB").agent.a.permission).toBe(false);
});

test("(N2) a user wildcard deny (scraper_*) carries into extractor; exact key not required", () => {
  const user = { "scraper_*": "deny" };
  const r = one("---\nname: a\ntools: mcp__scraper__get_page\n---\nB", { userPermission: user });
  expect(r.agent.a.permission.scraper_get_page).toBe("deny");
  const rules = [defaults("/h"), fromConfig(user, "/h"), fromConfig(r.agent.a.permission, "/h")];
  expect(evaluate("scraper_get_page", "*", ...rules).action).toBe("deny");
});

test("(N2) baseline \"*\":\"ask\" makes glob ask inside a Glob agent; a later exact key beats an earlier wildcard", () => {
  const r = one("---\nname: a\ntools: Glob, Grep\n---\nB", { userPermission: { "*": "ask", grep: "allow" } });
  expect(r.agent.a.permission.glob).toBe("ask");
  expect(r.agent.a.permission.grep).toBe("allow");
  const rules = [defaults("/h"), fromConfig({ "*": "ask" }, "/h"), fromConfig(r.agent.a.permission, "/h")];
  expect(evaluate("glob", "*", ...rules).action).toBe("ask");
  // reversed order: the wildcard comes last and wins
  expect(one("---\nname: a\ntools: Grep\n---\nB", { userPermission: { grep: "allow", "*": "ask" } }).agent.a.permission.grep).toBe("ask");
});

test("(collision) CC agents named like OC natives are skipped and reported", () => {
  h = makeHome(Object.fromEntries(["build", "plan", "general", "explore", "compaction", "title", "summary", "fine"].map((n) => [`.claude/agents/${n}.md`, `---\nname: ${n}\n---\nB`])));
  const r = collectAgents({ home: h.home, projectDir: h.projectDir });
  expect(Object.keys(r.agent)).toEqual(["fine"]);
  expect(r.unknown.map((u) => u.key).sort()).toEqual(["build", "compaction", "explore", "general", "plan", "summary", "title"].map((n) => `agent:${n}`));
});
