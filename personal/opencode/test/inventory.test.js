import { describe, test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { makeCcHome } from "./helpers.js";
import { buildInventory, PROBLEMS, codeModeOn, ccSkillsOff } from "../core/inventory.js";
import { selfProbe, EXPECTED_ARGS } from "../core/selfprobe.js";

const cleanups = [];
afterEach(() => {
  while (cleanups.length) cleanups.pop()();
});

const fakeHome = (settings) => {
  const h = makeCcHome(settings);
  cleanups.push(h.cleanup);
  return h;
};

describe("buildInventory (end-to-end fake home)", () => {
  test("derives every surface and reports unknowns and problems", () => {
    const h = fakeHome();
    const inv = buildInventory({
      home: h.home,
      projectDir: h.projectDir,
      worktree: h.projectDir,
      ocTools: ["bash", "read", "invalid", "brand_new_tool", "serena_find_symbol"],
      observedArgs: { read: ["filePath", "pathX"], bash: ["command"] },
      env: {},
    });
    expect(Object.keys(inv).sort()).toEqual(
      ["agent", "command", "degraded", "hooks", "instructions", "mcp", "merged", "permission", "plugins", "problems", "probeMismatches", "skillPaths", "unknown"].sort(),
    );
    // settings + plugins
    expect(inv.merged.env.CC_TEST_ENV).toBe("on");
    expect(inv.plugins.map((p) => p.key).sort()).toEqual(["semgrep@claude-plugins-official", "superpowers@superpowers-dev"]);
    // hooks carry their disposition; degraded is the semgrep SessionEnd rule
    const guard = inv.hooks.find((x) => x.command === "unclassified-guard");
    expect(guard).toMatchObject({ event: "PreToolUse", disposition: "bridge", classified: false });
    expect(inv.degraded.map((x) => x.command)).toEqual(["semgrep-end"]);
    expect(inv.degraded[0].reason).toBe("Best-effort on process exit");
    // permission: bash default ask, the CC allow, read deny twin forms, edit "*" the R45 ask, first
    expect(inv.permission.bash["*"]).toBe("ask");
    expect(inv.permission.bash["git status"]).toBe("allow");
    expect(inv.permission.read["**/.env"]).toBe("deny");
    expect(inv.permission.read[".env"]).toBe("deny");
    expect(Object.entries(inv.permission.edit)[0]).toEqual(["*", "ask"]);
    // MCP: serena context override
    expect(inv.mcp.serena.command).toContain("--context=agent");
    // agents (R36: per-agent deny-all first) and commands (R37: $0 -> $1)
    expect(Object.keys(inv.agent.rev.permission)[0]).toBe("*");
    expect(inv.agent.rev.permission["*"]).toBe("deny");
    expect(inv.command.hi.template).toContain("$1");
    // skills + rules
    expect(inv.skillPaths).toContain(h.semgrep);
    expect(inv.skillPaths).toContain(path.join(h.home, ".claude", "skills", "mine"));
    expect(inv.instructions).toEqual([path.join(h.home, ".claude", "rules", "style.md")]);
    // unknowns: an unknown settings key and an OC tool with no tool-map row (not invalid, not MCP)
    const keys = inv.unknown.map((u) => u.key);
    expect(keys).toContain("brandNewSetting");
    expect(keys).toContain("brand_new_tool");
    expect(keys).not.toContain("invalid");
    expect(keys).not.toContain("serena_find_symbol");
    // problems: both env flags, R35 verbatim, the self-probe mismatch (pathX), probe mismatches last
    expect(inv.problems).toContain(PROBLEMS.codeMode);
    expect(inv.problems).toContain(PROBLEMS.ccSkills);
    expect(inv.problems).toContain("OC grep/glob ignore read denies; CC Read denies do not protect file contents from OC search tools");
    expect(inv.probeMismatches).toHaveLength(1);
    expect(inv.probeMismatches[0]).toContain("pathX");
    expect(inv.problems.at(-1)).toBe(inv.probeMismatches[0]);
  });

  test("env flags set to \"1\" clear their problems; \"0\" does not", () => {
    const h = fakeHome();
    const ok = buildInventory({ home: h.home, projectDir: h.projectDir, env: { OPENCODE_EXPERIMENTAL_CODE_MODE: "1", OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "1" } });
    expect(ok.problems).not.toContain(PROBLEMS.codeMode);
    expect(ok.problems).not.toContain(PROBLEMS.ccSkills);
    const bad = buildInventory({ home: h.home, projectDir: h.projectDir, env: { OPENCODE_EXPERIMENTAL_CODE_MODE: "0", OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "0" } });
    expect(bad.problems).toContain(PROBLEMS.codeMode);
    expect(bad.problems).toContain(PROBLEMS.ccSkills);
  });

  test("R42: OPENCODE_EXPERIMENTAL implies Code Mode unless the explicit flag is set (runtime-flags.ts:10-14,48)", () => {
    expect(codeModeOn({ OPENCODE_EXPERIMENTAL: "1" })).toBe(true);
    expect(codeModeOn({ OPENCODE_EXPERIMENTAL: "true" })).toBe(true);
    expect(codeModeOn({ OPENCODE_EXPERIMENTAL: "1", OPENCODE_EXPERIMENTAL_CODE_MODE: "0" })).toBe(false); // explicit wins
    expect(codeModeOn({ OPENCODE_EXPERIMENTAL: "0", OPENCODE_EXPERIMENTAL_CODE_MODE: "1" })).toBe(true);
    expect(codeModeOn({ OPENCODE_EXPERIMENTAL_CODE_MODE: "" , OPENCODE_EXPERIMENTAL: "1" })).toBe(true); // empty = not set
    expect(codeModeOn({})).toBe(false);
    const h = fakeHome();
    const inv = buildInventory({ home: h.home, projectDir: h.projectDir, env: { OPENCODE_EXPERIMENTAL: "1", OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "1" } });
    expect(inv.problems).not.toContain(PROBLEMS.codeMode);
  });

  test("R42: OPENCODE_DISABLE_CLAUDE_CODE implies the skills disable (runtime-flags.ts:27-30)", () => {
    expect(ccSkillsOff({ OPENCODE_DISABLE_CLAUDE_CODE: "1" })).toBe(true);
    expect(ccSkillsOff({ OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "true" })).toBe(true);
    expect(ccSkillsOff({ OPENCODE_DISABLE_CLAUDE_CODE: "0" })).toBe(false);
    expect(ccSkillsOff({})).toBe(false);
    const h = fakeHome();
    const inv = buildInventory({ home: h.home, projectDir: h.projectDir, env: { OPENCODE_EXPERIMENTAL_CODE_MODE: "1", OPENCODE_DISABLE_CLAUDE_CODE: "1" } });
    expect(inv.problems).not.toContain(PROBLEMS.ccSkills);
  });

  test("the OC baseline is merged, never replaced (a baseline key survives)", () => {
    const h = fakeHome();
    const inv = buildInventory({ home: h.home, projectDir: h.projectDir, worktree: h.projectDir, baseline: { read: { "*.pem": "deny" }, external_directory: { "/x/*": "allow" } }, env: {} });
    expect(inv.permission.read["*.pem"]).toBe("deny");
    expect(inv.permission.external_directory["/x/*"]).toBe("allow");
    expect(inv.permission.read["**/.env"]).toBe("deny");
  });

  test("never throws: corrupt settings and a missing home give an inventory with unknowns", () => {
    const h = fakeHome();
    fs.writeFileSync(path.join(h.home, ".claude", "settings.json"), "{not json");
    let inv;
    expect(() => (inv = buildInventory({ home: h.home, projectDir: h.projectDir, env: {} }))).not.toThrow();
    expect(inv.unknown.some((u) => /unparseable JSON/.test(u.note))).toBe(true);
    const gone = path.join(h.home, "does-not-exist");
    const empty = buildInventory({ home: gone, projectDir: gone, env: {} });
    expect(empty.hooks).toEqual([]);
    expect(empty.plugins).toEqual([]);
  });

  test("ocTools defaults to none: no OC-tool unknowns without a previous session", () => {
    const h = fakeHome();
    const inv = buildInventory({ home: h.home, projectDir: h.projectDir, env: {} });
    expect(inv.unknown.filter((u) => u.where === "opencode")).toEqual([]);
    expect(inv.probeMismatches).toEqual([]);
  });
});

describe("selfProbe", () => {
  test("observed names inside the expected set -> no mismatch", () => {
    expect(selfProbe({ read: ["filePath", "offset"], bash: ["command", "workdir"], edit: ["filePath", "oldString", "newString"] })).toEqual([]);
  });
  test("a renamed arg (one the tool map does not expect) -> one problem string naming tool and arg", () => {
    const out = selfProbe({ read: ["path"], bash: ["command", "description"] });
    expect(out).toHaveLength(2);
    expect(out[0]).toContain("read");
    expect(out[0]).toContain("path");
    expect(out[1]).toContain("description");
  });
  test("tools with no expectation (MCP, pass-through, unknown) are not probed; bad input tolerated", () => {
    expect(selfProbe({ serena_find_symbol: ["x"], websearch: ["q"], brand_new: ["y"] })).toEqual([]);
    expect(selfProbe(null)).toEqual([]);
    expect(selfProbe({ read: "filePath" })).toEqual([]);
  });
  test("EXPECTED_ARGS mirrors the measured OC v1.19.0 schemas (v1-capabilities E8)", () => {
    expect(EXPECTED_ARGS.bash).toEqual(["command", "timeout", "workdir"]);
    expect(EXPECTED_ARGS.read).toEqual(["filePath", "offset", "limit"]);
    expect(EXPECTED_ARGS.apply_patch).toEqual(["patchText"]);
    expect(selfProbe({ x: ["a"] }, { x: ["b"] })).toHaveLength(1); // custom expectation honoured
  });
});
