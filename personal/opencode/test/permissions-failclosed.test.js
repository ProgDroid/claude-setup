import { describe, test, expect } from "bun:test";
import os from "node:os";
import path from "node:path";
import { toOcPermission } from "../core/permissions.js";
import * as OC from "./oc-matcher.js";

// Final fix round 2: fail-closed semantics (review I1, ruling R45). Effects are checked with the
// verbatim OC v1.19.0 matcher (test/oc-matcher.js) against the build and general agents' rulesets.

const tmp = os.tmpdir();
const HOME = path.join(tmp, "ccp-fc-home");
const WT = path.join(tmp, "ccp-fc-wt");
const opts = { home: HOME, worktree: WT };
const perms = (o = {}) => ({ allow: [], ask: [], deny: [], ...o });
const build = (permission, pattern, perm, home = HOME) => OC.evaluate(permission, pattern, ...OC.buildRuleset(perm, home)).action;
// The general subagent's ruleset (agent.ts: defaults, then todowrite deny, then the user ruleset).
const general = (permission, pattern, perm, home = HOME) =>
  OC.evaluate(permission, pattern, OC.defaults(home), OC.fromConfig({ todowrite: "deny" }, home), OC.fromConfig(perm, home)).action;
const BASELINE = () => ({
  read: { "**/.env": "deny", ".env": "deny", "**/.env.example": "allow", ".env.example": "allow" },
  edit: { "**/.claude/settings.json": "deny", ".claude/settings.json": "deny" },
  bash: { "*": "ask", "curl * | sh": "deny" },
});

describe("toOcPermission: untranslatable deny/ask rules fail CLOSED (I1)", () => {
  // The final review's probe, verbatim.
  const PROBE = {
    deny: ["WebSearch", "Task", "Grep", "NotebookEdit", "Read(/secrets/**)", "Read(!keep)", "Read([ab].key)", "mcp__srv*", "Agent(Explore)", "Bash"],
    ask: ["WebSearch", "Skill"],
  };
  // For each rule alone: OC calls that CC's rule covers, and the action OC must give each. At least
  // as strict as CC; `!x` has no superset and gets R35's whole-key ask.
  const COVERED = {
    WebSearch: [["websearch", "any query", "deny"]],
    Task: [["task", "general", "deny"], ["task", "explore", "deny"]],
    Grep: [["grep", "TODO", "deny"]],
    NotebookEdit: [["edit", "nb.ipynb", "deny"], ["edit", path.join("d", "nb.ipynb"), "deny"]],
    "Read(/secrets/**)": [["read", path.join("secrets", "a"), "deny"]],
    "Read(!keep)": [["read", "other.txt", "ask"], ["read", path.join("d", "x"), "ask"]],
    "Read([ab].key)": [["read", "a.key", "deny"], ["read", path.join("d", "b.key"), "deny"]],
    "mcp__srv*": [["srv_tool", "*", "deny"], ["srvx_tool", "*", "deny"]],
    "Agent(Explore)": [["task", "Explore", "deny"], ["task", "explore", "deny"]],
    Bash: [["bash", "ls", "deny"]],
  };
  const ASK_COVERED = { WebSearch: [["websearch", "q", "ask"]], Skill: [["skill", "any-skill", "ask"]] };

  test("the review's probe: every rule yields a deny or ask at least as strict as CC, schema-valid", () => {
    const { permission, unknown } = toOcPermission(PROBE, {}, opts);
    expect(OC.schemaErrors(permission)).toEqual([]);
    expect("*" in permission).toBe(false);
    for (const cases of Object.values(COVERED)) {
      for (const [p, pat, want] of cases) expect([p, pat, build(p, pat, permission)]).toEqual([p, pat, want]);
    }
    expect(build("skill", "any-skill", permission)).toBe("ask");
    // Exact translations need no note; every lossy one is still reported.
    const reported = new Set(unknown.map((u) => u.key));
    for (const k of ["Read(/secrets/**)", "Read(!keep)", "Read([ab].key)", "mcp__srv*"]) expect(reported.has(k)).toBe(true);
  });
  for (const [rule, cases] of Object.entries(COVERED)) {
    test(`deny ${rule} on its own is at least as strict as CC`, () => {
      const { permission } = toOcPermission(perms({ deny: [rule] }), {}, opts);
      for (const [p, pat, want] of cases) expect([p, pat, build(p, pat, permission)]).toEqual([p, pat, want]);
    });
  }
  for (const [rule, cases] of Object.entries(ASK_COVERED)) {
    test(`ask ${rule} on its own asks`, () => {
      const { permission, unknown } = toOcPermission(perms({ ask: [rule] }), {}, opts);
      expect(unknown).toEqual([]); // translated exactly: R45's default ask alone must not pass this
      for (const [p, pat, want] of cases) expect([p, pat, build(p, pat, permission)]).toEqual([p, pat, want]);
    });
  }
  test("bare tools map to OC keys checked against OC source, for allow, ask and deny", () => {
    const map = { WebSearch: "websearch", Task: "task", Agent: "task", Grep: "grep", Glob: "glob", NotebookEdit: "edit", Skill: "skill", TodoWrite: "todowrite", LSP: "lsp" };
    for (const kind of ["allow", "ask", "deny"]) {
      for (const [cc, oc] of Object.entries(map)) {
        const { permission, unknown } = toOcPermission(perms({ [kind]: [cc] }), {}, opts);
        expect(OC.schemaErrors(permission)).toEqual([]);
        const v = permission[oc];
        // A bare allow on a path tool (NotebookEdit -> edit) would be an allow-all: never emitted.
        const want = kind === "allow" && oc === "edit" ? "ask" : kind;
        expect([cc, kind, typeof v === "string" ? v : v["*"]]).toEqual([cc, kind, want]);
        if (!(kind === "allow" && oc === "edit")) expect(unknown).toEqual([]);
      }
    }
  });
  test("Task(X)/Agent(X): the name, its lower-case twin and CC's general-purpose -> OC general", () => {
    const { permission } = toOcPermission(perms({ deny: ["Agent(Explore)", "Task(general-purpose)"] }), {}, opts);
    expect(permission.task).toMatchObject({ Explore: "deny", explore: "deny", "general-purpose": "deny", general: "deny" });
    expect(build("task", "general", permission)).toBe("deny");
    expect(build("task", "my-agent", permission)).toBe("allow"); // R49: CC runs uncovered subagents without a prompt
    const a = toOcPermission(perms({ allow: ["Agent(my-agent)"] }), {}, opts);
    expect(a.permission.task).toEqual({ "my-agent": "allow" });
    expect("task" in toOcPermission(perms({ allow: ["Agent(my-*)"] }), {}, opts).permission).toBe(false);
  });
  test("tools with no per-pattern OC form: a deny/ask is a whole-key superset, an allow is unknown", () => {
    for (const [rule, oc] of [["Grep(TODO)", "grep"], ["Glob(**/*.ts)", "glob"], ["WebSearch(x)", "websearch"], ["TodoWrite(x)", "todowrite"], ["LSP(x)", "lsp"]]) {
      const d = toOcPermission(perms({ deny: [rule] }), {}, opts);
      expect([rule, d.permission[oc] === "deny" || d.permission[oc]?.["*"] === "deny"]).toEqual([rule, true]);
      expect(d.unknown.map((u) => u.key)).toEqual([rule]);
      const a = toOcPermission(perms({ allow: [rule] }), {}, opts);
      expect([rule, a.permission[oc] === "allow" || a.permission[oc]?.["*"] === "allow"]).toEqual([rule, false]);
      expect(a.unknown.map((u) => u.key)).toEqual([rule]);
    }
  });
  test("Skill(x): the name as given plus its plugin-less tail", () => {
    const { permission } = toOcPermission(perms({ deny: ["Skill(superpowers:brainstorming)"] }), {}, opts);
    expect(permission.skill).toMatchObject({ "superpowers:brainstorming": "deny", brainstorming: "deny" });
  });
  test("AskUserQuestion / ExitPlanMode: OC gates them by visibility only; a deny is a deny, an ask or allow emits no rule and is reported (m1)", () => {
    const d = toOcPermission(perms({ deny: ["ExitPlanMode"] }), {}, opts);
    expect(d.permission.plan_exit).toBe("deny");
    expect(d.unknown).toEqual([]);
    // m1: an ask must not become a deny. OC's plan_exit asks the user itself (plan.ts) and the
    // question tool is a prompt by nature, so the ask emits nothing and is reported.
    const q = toOcPermission(perms({ ask: ["AskUserQuestion", "ExitPlanMode"] }), {}, opts);
    expect("question" in q.permission || "plan_exit" in q.permission).toBe(false);
    expect(q.unknown.map((u) => u.key)).toEqual(["AskUserQuestion", "ExitPlanMode"]);
    expect(q.unknown.every((u) => u.note.startsWith("not translated to OC: "))).toBe(true);
    expect(OC.evaluate("plan_exit", "*", ...OC.planRuleset(q.permission, HOME)).action).toBe("allow"); // plan keeps its exit
    const a = toOcPermission(perms({ allow: ["AskUserQuestion", "ExitPlanMode"] }), {}, opts);
    expect("question" in a.permission || "plan_exit" in a.permission).toBe(false);
    expect(a.unknown.map((u) => u.key)).toEqual(["AskUserQuestion", "ExitPlanMode"]);
    // the built-in denies stay for subagents
    expect(general("question", "*", a.permission)).toBe("deny");
    expect(general("plan_exit", "*", a.permission)).toBe("deny");
  });
  test("an MCP ALLOW whose OC key matches a built-in permission is unknown (it would lift plan_enter's deny)", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["mcp__plan__*", "mcp__plan__enter"] }), {}, opts);
    expect("plan_*" in permission || "plan_enter" in permission).toBe(false);
    expect(unknown.map((u) => u.key)).toEqual(["mcp__plan__*", "mcp__plan__enter"]);
    expect(general("plan_enter", "*", permission)).toBe("deny");
  });
  test("an MCP ASK whose key matches a default-deny built-in is upgraded to deny, so it cannot lift it", () => {
    const { permission, unknown } = toOcPermission(perms({ ask: ["mcp__pl*", "mcp__plan__*"] }), {}, opts);
    expect("pl*_*" in permission).toBe(false); // m2: the glob key would hit plan_enter/plan_exit; no server configured
    expect(permission["plan_*"]).toBe("deny");
    expect(general("plan_enter", "*", permission)).toBe("deny");
    expect(general("plan_exit", "*", permission)).toBe("deny");
    expect([...new Set(unknown.map((u) => u.key))]).toEqual(["mcp__pl*", "mcp__plan__*"]);
  });
  test("a deny on a ?-glob MCP tool keeps the ? (sanitising it to _ would narrow the deny)", () => {
    const { permission } = toOcPermission(perms({ deny: ["mcp__s__t?"] }), {}, opts);
    expect(permission["s_t?"]).toBe("deny");
    expect(build("s_tx", "*", permission)).toBe("deny");
  });
});

describe("toOcPermission: uncovered calls ask (R45)", () => {
  test('edit "*":"ask" is FIRST within edit, ahead of CC allows and the baseline', () => {
    const { permission } = toOcPermission(perms({ allow: ["Edit(src/**)"] }), BASELINE(), opts);
    expect(Object.keys(permission.edit)[0]).toBe("*");
    expect(permission.edit["*"]).toBe("ask");
    expect(build("edit", path.join("src", "a.ts"), permission)).toBe("allow");
    expect(build("edit", path.join("lib", "a.ts"), permission)).toBe("ask");
    expect(build("edit", path.join(".claude", "settings.json"), permission)).toBe("deny");
  });
  test("webfetch / websearch ask when neither side sets them; task gets nothing (R49)", () => {
    const { permission } = toOcPermission(perms(), {}, opts);
    expect(permission.webfetch).toBe("ask");
    expect(permission.websearch).toBe("ask");
    expect("task" in permission).toBe(false);
    for (const [p, pat] of [["webfetch", "https://x"], ["websearch", "q"]]) expect(build(p, pat, permission)).toBe("ask");
    expect(build("task", "general", permission)).toBe("allow");
  });
  test("a baseline setting wins over the default ask (R34), and CC's stricter-of rule still applies (R35)", () => {
    const base = { webfetch: "allow", websearch: "deny", task: { general: "allow" }, edit: { "*": "allow" } };
    const { permission } = toOcPermission(perms(), base, opts);
    expect(permission.webfetch).toBe("allow");
    expect(permission.websearch).toBe("deny");
    expect(permission.task).toEqual({ general: "allow" }); // R49: no "*":"ask" added
    expect(permission.edit["*"]).toBe("allow");
    const cc = toOcPermission(perms({ allow: ["WebFetch"], ask: ["WebSearch"] }), {}, opts).permission;
    expect(cc.webfetch).toBe("allow"); // CC set it
    expect(cc.websearch).toBe("ask");
    expect(toOcPermission(perms({ allow: ["WebFetch"] }), { webfetch: "ask" }, opts).permission.webfetch).toBe("ask");
  });
  test("each configured MCP server gets <srv>_*:ask BEFORE that server's CC allows", () => {
    const { permission } = toOcPermission(perms({ allow: ["mcp__srv-a__q"], deny: ["mcp__b__x"] }), {}, { ...opts, mcpServers: ["srv-a", "b", "plugin:qmd:qmd"] });
    const keys = Object.keys(permission);
    for (const s of ["srv-a_*", "b_*", "plugin_qmd_qmd_*"]) expect([s, permission[s]]).toEqual([s, "ask"]);
    expect(keys.indexOf("srv-a_*")).toBeLessThan(keys.indexOf("srv-a_q"));
    expect(build("srv-a_q", "*", permission)).toBe("allow");
    expect(build("srv-a_other", "*", permission)).toBe("ask");
    expect(build("b_x", "*", permission)).toBe("deny");
    expect(build("plugin_qmd_qmd_get", "*", permission)).toBe("ask");
  });
  test("a baseline or CC key for the whole server is kept, never overwritten by the default ask", () => {
    const b = toOcPermission(perms(), { "srv_*": "deny" }, { ...opts, mcpServers: ["srv"] }).permission;
    expect(b["srv_*"]).toBe("deny");
    const c = toOcPermission(perms({ allow: ["mcp__srv"] }), {}, { ...opts, mcpServers: ["srv"] }).permission;
    expect(c["srv_*"]).toBe("allow");
  });
  test("a server named like a default-deny built-in gets a deny, never an ask that lifts plan_enter", () => {
    const { permission, unknown } = toOcPermission(perms(), {}, { ...opts, mcpServers: ["plan"] });
    expect(permission["plan_*"]).toBe("deny");
    expect(general("plan_enter", "*", permission)).toBe("deny");
    expect(unknown.map((u) => u.key)).toEqual(["plan"]);
  });
  test('never a top-level "*" for any input; question / plan_enter / plan_exit stay denied for subagents', () => {
    const RULES = ["Bash", "Read", "Edit", "WebFetch", "WebSearch", "Task", "Agent(x)", "Grep", "Glob", "Skill", "TodoWrite", "LSP", "NotebookEdit",
      "AskUserQuestion", "ExitPlanMode", "mcp__*", "mcp__s*", "mcp__s", "mcp__s__*", "mcp__plan__*", "Read(!x)", "Read([a].x)", "Read(/x)", "*"];
    for (const kind of ["allow", "ask", "deny"]) {
      for (const base of [{}, BASELINE()]) {
        const { permission } = toOcPermission(perms({ [kind]: RULES }), base, { ...opts, mcpServers: ["s", "plan", "doom"] });
        expect("*" in permission).toBe(false);
        expect(OC.schemaErrors(permission)).toEqual([]);
        for (const p of ["question", "plan_enter", "plan_exit"]) expect([kind, p, general(p, "*", permission)]).toEqual([kind, p, "deny"]);
      }
    }
  });
});

// Round 4 m2: OC matches a top-level key against EVERY permission name, so a server-glob key like
// `*_*` also hits external_directory, plan_enter, plan_exit and doom_loop. A glob is expanded into
// per-server keys for the configured servers it matches; the raw glob key is emitted only when it
// hits no OC built-in.
describe("m2: an MCP server glob never reaches OC's built-in permissions", () => {
  const buildRs = (permission) => OC.buildRuleset(permission, HOME);
  const act = (rs, p, pat) => OC.evaluate(p, pat, ...rs).action;
  const BUILTIN_CASES = [["external_directory", path.join(tmp, "outside", "x")], ["doom_loop", "*"], ["plan_enter", "*"], ["question", "*"]];
  test("deny mcp__*: one deny per configured server, no `*_*`; the build agent's built-ins are untouched", () => {
    const none = buildRs({});
    for (const kind of ["deny", "ask"]) {
      const { permission, unknown } = toOcPermission(perms({ [kind]: ["mcp__*"] }), {}, { ...opts, mcpServers: ["a", "srv-b"] });
      expect("*_*" in permission).toBe(false);
      expect([kind, permission["a_*"], permission["srv-b_*"]]).toEqual([kind, kind, kind]);
      expect(act(buildRs(permission), "a_tool", "*")).toBe(kind);
      for (const [p, pat] of BUILTIN_CASES) expect([kind, p, act(buildRs(permission), p, pat)]).toEqual([kind, p, act(none, p, pat)]);
      expect([...new Set(unknown.map((u) => u.key))]).toEqual(["mcp__*"]);
    }
  });
  test("a glob whose raw key hits no built-in is still emitted raw, beside the per-server keys", () => {
    const { permission } = toOcPermission(perms({ deny: ["mcp__srv*"] }), {}, { ...opts, mcpServers: ["srv1", "other"] });
    expect(permission["srv*_*"]).toBe("deny");
    expect(permission["srv1_*"]).toBe("deny");
    expect(permission["other_*"]).toBe("ask"); // R45 only: the glob does not match it
  });
  test("a glob that hits a built-in and matches no configured server emits nothing and is reported as not translated", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["mcp__*"] }), {}, opts);
    expect(Object.keys(permission).filter((k) => k.includes("*"))).toEqual([]);
    expect(unknown).toHaveLength(1);
    expect(unknown[0].note).toStartWith("not translated to OC: ");
  });
  test("an expanded key that collides with a default-deny built-in keeps the exact-name rule (ask -> deny)", () => {
    const { permission } = toOcPermission(perms({ ask: ["mcp__pl*"] }), {}, { ...opts, mcpServers: ["plx", "plan"] });
    expect("pl*_*" in permission).toBe(false);
    expect(permission["plx_*"]).toBe("ask");
    expect(permission["plan_*"]).toBe("deny");
    expect(general("plan_enter", "*", permission)).toBe("deny");
    // the R45 server asks give the same values for an ASK; a DENY tells the expansion apart
    const d = toOcPermission(perms({ deny: ["mcp__pl*"] }), {}, { ...opts, mcpServers: ["plx", "plan"] }).permission;
    expect([d["plx_*"], d["plan_*"], "pl*_*" in d]).toEqual(["deny", "deny", false]);
  });
});
