import { describe, test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { toOcPermission } from "../core/permissions.js";
import { promptingSkills } from "../core/skills.js";
import { buildInventory } from "../core/inventory.js";
import { makeHome } from "./helpers.js";
import * as OC from "./oc-matcher.js";

// Round 4, R49: a key CC's rules leave uncovered gets CC 2.1.300's OWN default for the mapped
// tool (its checkPermissions; table in docs/v1-capabilities.md), not a blanket ask:
// - Agent/Task needs no permission outside auto mode -> no task key (OC's default);
// - Skill asks only for a skill whose definition carries a non-"safe" property (non-empty
//   allowed-tools, disallowed-tools or hooks) -> a per-skill ask, every other skill runs;
// - Edit, WebFetch, WebSearch and MCP tools ask (unchanged, covered by permissions-failclosed).

const tmp = os.tmpdir();
const opts = { home: path.join(tmp, "ccp-r49-home"), worktree: path.join(tmp, "ccp-r49-wt") };
const perms = (o = {}) => ({ allow: [], ask: [], deny: [], ...o });
const build = (permission, pattern, perm) => OC.evaluate(permission, pattern, ...OC.buildRuleset(perm, opts.home)).action;

let h;
afterEach(() => h && h.cleanup());

describe("R49: task follows CC's Agent tool, which needs no permission outside auto mode", () => {
  test("no CC Task/Agent rule: no task key, so OC's default applies", () => {
    const { permission } = toOcPermission(perms(), {}, opts);
    expect("task" in permission).toBe(false);
    expect(build("task", "general", permission)).toBe("allow");
  });
  test("CC Agent(X) allow and deny are still emitted, with no '*':'ask' added", () => {
    expect(toOcPermission(perms({ allow: ["Agent(my-agent)"] }), {}, opts).permission.task).toEqual({ "my-agent": "allow" });
    const d = toOcPermission(perms({ deny: ["Task(general-purpose)"] }), {}, opts).permission;
    expect(build("task", "general", d)).toBe("deny");
    expect(build("task", "my-agent", d)).toBe("allow");
    const a = toOcPermission(perms({ ask: ["Task"] }), {}, opts).permission;
    expect(a.task).toEqual({ "*": "ask" });
  });
});

describe("R49: skill follows CC's Skill tool (asks only for a skill with non-safe properties)", () => {
  test("skillAsks become per-skill asks; other skills keep OC's default", () => {
    const { permission } = toOcPermission(perms(), {}, { ...opts, skillAsks: ["guarded", "other-guarded"] });
    expect(permission.skill).toEqual({ guarded: "ask", "other-guarded": "ask" });
    expect(build("skill", "guarded", permission)).toBe("ask");
    expect(build("skill", "plain", permission)).toBe("allow");
  });
  test("a CC rule for the skill wins over the default ask: allow, deny, and an ask stays ask", () => {
    const o = { ...opts, skillAsks: ["guarded"] };
    expect(toOcPermission(perms({ allow: ["Skill(guarded)"] }), {}, o).permission.skill).toEqual({ guarded: "allow" });
    expect(build("skill", "guarded", toOcPermission(perms({ deny: ["Skill(guarded)"] }), {}, o).permission)).toBe("deny");
    expect(build("skill", "guarded", toOcPermission(perms({ ask: ["Skill(guarded)"] }), {}, o).permission)).toBe("ask");
    // a CC deny-all on Skill still covers it
    expect(build("skill", "guarded", toOcPermission(perms({ deny: ["Skill"] }), {}, o).permission)).toBe("deny");
  });
  test("a baseline setting wins, as for every R45 default: a bare action, a '*' or the name itself", () => {
    const o = { ...opts, skillAsks: ["guarded"] };
    expect(toOcPermission(perms(), { skill: "allow" }, o).permission.skill).toBe("allow");
    expect(toOcPermission(perms(), { skill: { "*": "allow" } }, o).permission.skill).toEqual({ "*": "allow" });
    expect(toOcPermission(perms(), { skill: { guarded: "allow" } }, o).permission.skill).toEqual({ guarded: "allow" });
    // control: an unrelated baseline skill key does not suppress it
    expect(toOcPermission(perms(), { skill: { x: "deny" } }, o).permission.skill).toEqual({ guarded: "ask", x: "deny" });
  });
  test("no skillAsks: no skill key at all", () => {
    expect("skill" in toOcPermission(perms(), {}, opts).permission).toBe(false);
    expect("skill" in toOcPermission(perms(), {}, { ...opts, skillAsks: [] }).permission).toBe(false);
  });
});

describe("promptingSkills: CC's non-safe skill properties, read from SKILL.md frontmatter", () => {
  const skill = (root, dir, fm) => {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
    fs.writeFileSync(path.join(root, dir, "SKILL.md"), `---\n${fm}\n---\nbody\n`);
  };
  test("allowed-tools (string or list), disallowed-tools, disallowedTools and hooks ask; empty values and plain skills do not", () => {
    h = makeHome();
    const r = h.projectDir;
    skill(r, "plain", "name: plain\ndescription: d");
    skill(r, "at-str", "name: at-str\nallowed-tools: Bash(git status:*), Read");
    skill(r, "at-list", "name: at-list\nallowed-tools:\n  - Read\n  - Edit");
    skill(r, "at-empty", 'name: at-empty\nallowed-tools: ""');
    skill(r, "at-none", "name: at-none\nallowed-tools:");
    skill(r, "at-brackets", "name: at-brackets\nallowed-tools: []");
    skill(r, "dt", "name: dt\ndisallowed-tools: Bash");
    skill(r, "dt2", "name: dt2\ndisallowedTools: [Bash]");
    skill(r, "hk", "name: hk\nhooks:\n  PreToolUse:\n    - matcher: Bash\n      hooks:\n        - type: command\n          command: x");
    skill(r, "hk-empty", "name: hk-empty\nhooks: {}");
    skill(r, "noname", "description: OC loads no skill without a name\nallowed-tools: Read");
    skill(r, path.join("deep", "a", "b"), "name: deep-one\nallowed-tools: Read");
    const names = promptingSkills([r]).map((s) => s.name).sort();
    expect(names).toEqual(["at-list", "at-str", "deep-one", "dt", "dt2", "hk"]);
  });
  test("a quoted name is unquoted; an unreadable or frontmatter-less file asks nothing; missing paths are skipped", () => {
    h = makeHome();
    const r = h.projectDir;
    skill(r, "q", "name: \"quoted-name\"\nallowed-tools: Read");
    fs.mkdirSync(path.join(r, "nofm"));
    fs.writeFileSync(path.join(r, "nofm", "SKILL.md"), "no frontmatter\n");
    expect(promptingSkills([r, path.join(r, "missing")]).map((s) => s.name)).toEqual(["quoted-name"]);
  });
});

describe("R49 end to end: the inventory emits a skill ask for a CC skill that declares allowed-tools", () => {
  test("user skill with allowed-tools -> skill.<name>: ask; a plain user skill -> nothing; no task key", () => {
    h = makeHome({
      ".claude/skills/guarded/SKILL.md": "---\nname: guarded\ndescription: d\nallowed-tools: Bash(git *)\n---\nB\n",
      ".claude/skills/plain/SKILL.md": "---\nname: plain\ndescription: d\n---\nB\n",
    });
    const inv = buildInventory({ home: h.home, projectDir: h.projectDir, worktree: h.projectDir, env: {} });
    expect(inv.permission.skill).toEqual({ guarded: "ask" });
    expect("task" in inv.permission).toBe(false);
  });
});

// Round 5 m-2: YAML shapes OC's parser reads that the line parser used to miss (fail-open), and a
// pin on the fail-closed branch for a guarded field the line parser cannot read (MU-A survived).
describe("promptingSkills: YAML edge shapes (R51 m-2)", () => {
  const skill = (root, dir, fm) => {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
    fs.writeFileSync(path.join(root, dir, "SKILL.md"), `---\n${fm}\n---\nbody\n`);
  };
  const names = (r) => promptingSkills([r]).map((s) => s.name).sort();
  test("an unparseable guarded value fails CLOSED (flow map, anchor, tag); an empty literal does not ask", () => {
    h = makeHome();
    const r = h.projectDir;
    skill(r, "hk-flow", "name: hk-flow\nhooks: {PreToolUse: [{matcher: Bash, hooks: [{type: command, command: x}]}]}");
    skill(r, "at-anchor", "name: at-anchor\nallowed-tools: &tools Read");
    skill(r, "dt-tag", "name: dt-tag\ndisallowed-tools: !!str Bash");
    skill(r, "hk-empty", "name: hk-empty\nhooks: {}");
    skill(r, "hk-empty-c", "name: hk-empty-c\nhooks: {} # none yet");
    // YAML allows a space before the colon; the raw lookup must read \s there, not the letter s
    skill(r, "hk-empty-sp", "name: hk-empty-sp\nhooks : {}");
    expect(names(r)).toEqual(["at-anchor", "dt-tag", "hk-flow"]);
  });
  test("a quoted guarded key is read as the key (YAML), so the skill asks", () => {
    h = makeHome();
    const r = h.projectDir;
    skill(r, "qk", 'name: qk\n"allowed-tools": Read');
    skill(r, "qk2", "name: qk2\n'hooks': x");
    skill(r, "qk-empty", 'name: qk-empty\n"allowed-tools": []');
    expect(names(r)).toEqual(["qk", "qk2"]);
  });
  test("inline comments: the name is read without its comment; a comment-only value is empty; # inside quotes stays", () => {
    h = makeHome();
    const r = h.projectDir;
    skill(r, "c1", "name: b # the real name is b\nallowed-tools: Read # needs read");
    skill(r, "c2", "name: c2\nallowed-tools: # none");
    skill(r, "c3", 'name: "a # b" # comment\nallowed-tools: [] # nothing');
    skill(r, "c4", 'name: "d # e"\nallowed-tools: Read');
    expect(names(r)).toEqual(["b", "d # e"]);
  });
  test("a frontmatter line the parser cannot read that names a guarded field asks (fail closed)", () => {
    h = makeHome();
    const r = h.projectDir;
    skill(r, "cx", "name: cx\n? allowed-tools\n: Read");
    skill(r, "cx-other", "name: cx-other\n? metadata\n: x");
    expect(names(r)).toEqual(["cx"]);
  });
});
