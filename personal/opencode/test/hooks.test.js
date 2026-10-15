import { describe, test, expect } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { collectHooks, matches, ifAllows } from "../core/hooks.js";
import { dispositionFor, loadRules, RULES } from "../core/dispositions.js";
import { enumerate } from "../core/enumerate.js";
import { pluginHookSources } from "../core/pluginhooks.js";
import { makeHome } from "./helpers.js";

const grp = (origin, matcher, handlers) => ({ matcher, origin, hooks: handlers.map((h) => ({ type: "command", origin, ...h })) });
const bash = (command) => ({ tool_name: "Bash", tool_input: { command } });
const file = (tool_name, file_path) => ({ tool_name, tool_input: { file_path } });

describe("matches (CC matcher semantics)", () => {
  test("absent, empty and * match everything", () => {
    expect(matches(undefined, "Bash")).toBe(true);
    expect(matches("*", "Bash")).toBe(true);
    expect(matches("", "Bash")).toBe(true);
  });
  test("plain names and |-lists are exact", () => {
    expect(matches("Edit|Write", "Write")).toBe(true);
    expect(matches("Edit|Write", "NotebookEdit")).toBe(false);
    expect(matches("Edit", "NotebookEdit")).toBe(false); // exact, not substring
    expect(matches("Bash", "Bash")).toBe(true);
    expect(matches("Edit, Write", "Write")).toBe(true);
  });
  test("anything else is an unanchored regex", () => {
    expect(matches("Edit.*", "NotebookEdit")).toBe(true);
    expect(matches("^Edit$", "Edit")).toBe(true);
    expect(matches("^Edit$", "NotebookEdit")).toBe(false);
    expect(matches("mcp__memory__.*", "mcp__memory__x")).toBe(true);
    expect(matches("mcp__memory__.*", "mcp__other__x")).toBe(false);
  });
  test("a * glob is a regex, not a glob (mcp__serena__* quirk)", () => {
    expect(matches("mcp__serena__*", "mcp__serena__find_symbol")).toBe(true);
    expect(matches("Grep|Read|mcp__serena__.*", "Read")).toBe(true);
  });
  test("an invalid regex never throws and does not match", () => {
    expect(matches("(", "Bash")).toBe(false);
  });
});

describe("ifAllows", () => {
  test("undefined and empty allow", () => {
    expect(ifAllows(undefined, bash("anything"))).toBe(true);
    expect(ifAllows("", bash("anything"))).toBe(true);
  });
  test("Bash(prefix:*) and Bash(prefix *)", () => {
    expect(ifAllows("Bash(git commit:*)", bash("git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("git commit"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("git status"))).toBe(false);
    expect(ifAllows("Bash(git commit *)", bash("git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit *)", bash("git status"))).toBe(false);
    expect(ifAllows("Bash(ls *)", bash("lsof -i"))).toBe(false); // word boundary
  });
  test("wildcards inside the pattern", () => {
    expect(ifAllows("Bash(git -C * commit *)", bash("git -C some/dir commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git -C * commit *)", bash("git -C some/dir status"))).toBe(false);
    expect(ifAllows("Bash(git -C * push*)", bash("git -C d push origin"))).toBe(true);
  });
  test("compound commands: any segment may match", () => {
    expect(ifAllows("Bash(git commit:*)", bash("cd a && git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("false || git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("echo hi; git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("echo hi | git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("echo hi |& git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("sleep 1 & git commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("echo a\ngit commit -m x"))).toBe(true);
    expect(ifAllows("Bash(git commit:*)", bash("cd a && git status"))).toBe(false);
  });
  test("a redirect's & does not start a segment", () => {
    expect(ifAllows("Bash(1)", bash("make 2>&1"))).toBe(false);
    expect(ifAllows("Bash(make *)", bash("make all 2>&1"))).toBe(true);
  });
  test("an operator inside quotes does not split", () => {
    expect(ifAllows("Bash(git push:*)", bash('echo "a && git push" ; true'))).toBe(false);
  });
  test("a different tool never allows", () => {
    expect(ifAllows("Bash(git commit:*)", file("Edit", "/a/b.ts"))).toBe(false);
  });
  test("bare Tool is tool_name equality", () => {
    expect(ifAllows("Bash", bash("x"))).toBe(true);
    expect(ifAllows("Edit", bash("x"))).toBe(false);
  });
  test("Tool(glob) over file_path, incl. Windows backslashes", () => {
    expect(ifAllows("Edit(**/*.ts)", file("Edit", "/proj/src/a.ts"))).toBe(true);
    expect(ifAllows("Edit(**/*.ts)", file("Edit", "/proj/src/a.js"))).toBe(false);
    expect(ifAllows("Edit(**/*.ts)", file("Edit", "C:\\proj\\src\\a.ts"))).toBe(true);
    expect(ifAllows("Edit(src/**)", file("Edit", "C:\\proj\\src\\deep\\a.ts"))).toBe(true);
    expect(ifAllows("Edit(src/**)", file("Edit", "C:\\proj\\lib\\a.ts"))).toBe(false);
    expect(ifAllows("Write(*.md)", file("Write", "C:\\proj\\notes\\a.md"))).toBe(true);
    expect(ifAllows("Write(*.md)", file("Write", "C:\\proj\\notes\\a.txt"))).toBe(false);
    // a relative glob matches at any depth (CC >= 2.1.214 anchors it to the cwd; over-matching is the safe side)
    expect(ifAllows("Edit(src/**)", file("Edit", "/proj/pkg/src/a.ts"))).toBe(true);
  });

  // The fail-open contract: false only when PROVABLY not a match.
  describe("fails open", () => {
    const P = "Bash(git commit:*)";
    test("leading VAR= assignments are stripped", () => {
      expect(ifAllows(P, bash("FOO=1 git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("A=1 B=2 git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("FOO=1 git status"))).toBe(false);
    });
    test("assignments with quoted or escaped values containing spaces are stripped", () => {
      expect(ifAllows(P, bash('GIT_AUTHOR_NAME="John Doe" git commit -m x'))).toBe(true);
      expect(ifAllows(P, bash("A='x y' git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("A=\"x\" B='y z' git commit"))).toBe(true);
      expect(ifAllows(P, bash("A=x\\ y git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash('A="x y" git status'))).toBe(false);
    });
    test("runs of whitespace do not defeat a match", () => {
      expect(ifAllows(P, bash("git  commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("  git \t commit"))).toBe(true);
      expect(ifAllows(P, bash("timeout  30   git  commit"))).toBe(true);
    });
    test("discriminating cases stay false/true", () => {
      expect(ifAllows(P, bash("git status"))).toBe(false);
      expect(ifAllows(P, bash("git status; git log"))).toBe(false);
      expect(ifAllows(P, bash('echo "git commit"'))).toBe(false);
      expect(ifAllows(P, bash('echo "git  commit"'))).toBe(false);
      expect(ifAllows(P, bash("git commit -m x"))).toBe(true);
    });
    test("documented wrappers are stripped, with their flags", () => {
      expect(ifAllows(P, bash("timeout 30 git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("timeout -k 5 30 git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("time git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("nice -n 5 git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("nohup git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("stdbuf -o L git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("command git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("builtin git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("noglob git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("timeout 30 nice FOO=1 git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("timeout 30 git status"))).toBe(false);
      expect(ifAllows("Bash(git push:*)", bash("timeout 60 git push"))).toBe(true);
      expect(ifAllows("Bash(git push:*)", bash("cd x && git commit -m y"))).toBe(false);
      expect(ifAllows(P, bash("cd x && git commit -m y"))).toBe(true);
    });
    test("command substitution and backticks run the hook", () => {
      expect(ifAllows(P, bash('echo "$(git commit -m x)"'))).toBe(true);
      expect(ifAllows(P, bash("echo $(git status)"))).toBe(true);
      expect(ifAllows(P, bash("echo `git commit -m x`"))).toBe(true);
    });
    test("subshells, groups and control-flow bodies are segments", () => {
      expect(ifAllows(P, bash("( git commit -m x )"))).toBe(true);
      expect(ifAllows(P, bash("(cd sub && git commit -m x)"))).toBe(true);
      expect(ifAllows(P, bash("{ git commit -m x; }"))).toBe(true);
      expect(ifAllows(P, bash("for i in 1; do git commit -m x; done"))).toBe(true);
      expect(ifAllows(P, bash("if true; then git commit -m x; fi"))).toBe(true);
      expect(ifAllows(P, bash("! git commit -m x"))).toBe(true);
      expect(ifAllows(P, bash("(cd sub && git status)"))).toBe(false);
    });
    test("unparseable commands run the hook", () => {
      expect(ifAllows(P, bash('echo "x && git commit -m y'))).toBe(true); // unterminated quote
      expect(ifAllows(P, bash("echo 'oops"))).toBe(true);
      expect(ifAllows(P, bash("git status &&"))).toBe(true); // dangling operator
      expect(ifAllows(P, bash("$CMD commit -m x"))).toBe(true); // command word is a variable
      expect(ifAllows(P, { tool_name: "Bash", tool_input: {} })).toBe(true); // no command field
    });
    test("an escaped ; does not split", () => {
      expect(ifAllows(P, bash("echo a\\; git commit -m x"))).toBe(false);
    });
    test("a bare-command match needs the trailing * to be the only wildcard", () => {
      expect(ifAllows("Bash(* --help *)", bash("npm --help"))).toBe(false);
      expect(ifAllows("Bash(* --help *)", bash("npm --help me"))).toBe(true);
    });
    test("unparseable if expressions run the hook", () => {
      expect(ifAllows("!!!", bash("x"))).toBe(true);
      expect(ifAllows("Bash(", bash("x"))).toBe(true);
      expect(ifAllows("<garbage>", file("Edit", "/a"))).toBe(true);
    });
    test("wildcard tool names (mcp__x__*) are decided on the name only", () => {
      expect(ifAllows("mcp__x__*", { tool_name: "mcp__x__do", tool_input: {} })).toBe(true);
      expect(ifAllows("mcp__x__*", { tool_name: "mcp__y__do", tool_input: {} })).toBe(false);
    });
    test("tools with no path field run the hook", () => {
      expect(ifAllows("WebFetch(domain:example.com)", { tool_name: "WebFetch", tool_input: { url: "https://example.com/a" } })).toBe(true);
      expect(ifAllows("Agent(Explore)", { tool_name: "Agent", tool_input: { subagent_type: "Explore" } })).toBe(true);
      expect(ifAllows("Edit(**/*.ts)", { tool_name: "Edit", tool_input: {} })).toBe(true);
    });
    test("anchored globs it cannot resolve run the hook", () => {
      expect(ifAllows("Read(~/x/**)", file("Read", "C:\\Scratch\\u\\x\\a"))).toBe(true);
      expect(ifAllows("Read(//c/**/.env)", file("Read", "C:\\a\\.env"))).toBe(true);
      expect(ifAllows("Edit(/src/**)", file("Edit", "C:\\proj\\src\\a.ts"))).toBe(true);
    });
    test("false only when the tool name provably differs", () => {
      expect(ifAllows("WebFetch(domain:example.com)", bash("x"))).toBe(false);
      expect(ifAllows("Read(~/x/**)", file("Edit", "/a"))).toBe(false);
      expect(ifAllows("???", bash("x"))).toBe(true);
    });
  });
});

describe("collectHooks", () => {
  const settingsHooks = {
    PreToolUse: [grp("settings:user", "Bash", [{ command: "a.sh", timeout: 5, if: "Bash(git commit:*)", statusMessage: "hi" }])],
    Stop: [grp("settings:user", "", [{ command: "b.sh", async: true }])],
  };

  test("carries every field, origin and event", () => {
    const [h, s] = collectHooks({ merged: { hooks: settingsHooks }, plugins: [] });
    const full = collectHooks({ merged: { hooks: { Stop: [grp("settings:user", "", [{ command: "c.sh", args: ["a"], shell: "bash", async: true, asyncRewake: true, rewakeMessage: "msg", rewakeSummary: "sum", onFailure: "ignore" }])] } }, plugins: [] })[0];
    expect(full).toMatchObject({ args: ["a"], shell: "bash", async: true, asyncRewake: true, rewakeMessage: "msg", rewakeSummary: "sum", onFailure: "ignore" });
    expect(h).toMatchObject({ origin: "settings:user", event: "PreToolUse", matcher: "Bash", type: "command", command: "a.sh", timeout: 5, if: "Bash(git commit:*)", statusMessage: "hi" });
    expect(h.pluginRoot).toBeUndefined();
    expect(s).toMatchObject({ event: "Stop", async: true });
    expect(h.id).toMatch(/^[0-9a-f]{12}$/);
  });

  test("ids are stable, and change when if (or anything hashed) changes", () => {
    const mk = (ifx) => collectHooks({ merged: { hooks: { PreToolUse: [grp("settings:user", "Bash", [{ command: "a.sh", if: ifx }])] } }, plugins: [] })[0].id;
    expect(mk("Bash(x:*)")).toBe(mk("Bash(x:*)"));
    expect(mk("Bash(x:*)")).not.toBe(mk("Bash(y:*)"));
    expect(mk(undefined)).not.toBe(mk("Bash(x:*)"));
    const a = collectHooks({ merged: { hooks: { Stop: [grp("settings:user", "", [{ command: "a.sh", args: ["1"] }])] } }, plugins: [] })[0].id;
    const b = collectHooks({ merged: { hooks: { Stop: [grp("settings:user", "", [{ command: "a.sh", args: ["2"] }])] } }, plugins: [] })[0].id;
    expect(a).not.toBe(b);
  });

  test("identical settings handlers collapse across scopes (lowest scope kept); plugin copies do not", () => {
    const t = makeHome({
      "plug/hooks/hooks.json": { hooks: { Stop: [{ hooks: [{ type: "command", command: "same.sh" }] }] } },
      "plug2/hooks/hooks.json": { hooks: { Stop: [{ hooks: [{ type: "command", command: "same.sh" }] }] } },
    });
    try {
      const merged = {
        hooks: {
          Stop: [grp("settings:user", "", [{ command: "same.sh" }]), grp("settings:project", "", [{ command: "same.sh" }]), grp("settings:project", "", [{ command: "other.sh" }])],
        },
      };
      const plugins = [
        { key: "p@m", installPath: path.join(t.home, "plug"), exists: true },
        { key: "q@m", installPath: path.join(t.home, "plug2"), exists: true },
      ];
      const hs = collectHooks({ merged, plugins });
      const s = hs.filter((h) => h.origin.startsWith("settings:"));
      expect(s.map((h) => [h.command, h.origin])).toEqual([["same.sh", "settings:user"], ["other.sh", "settings:project"]]);
      const p = hs.filter((h) => h.origin.startsWith("plugin:"));
      expect(p.map((h) => h.origin)).toEqual(["plugin:p@m", "plugin:q@m"]);
      expect(p[0].id).not.toBe(p[1].id);
    } finally {
      t.cleanup();
    }
  });

  test("plugin hooks: hooks.json, inline manifest hooks and manifest path are all collected, with pluginRoot", () => {
    const t = makeHome({
      "p1/hooks/hooks.json": { hooks: { SessionStart: [{ matcher: "startup", hooks: [{ type: "command", command: "x ${CLAUDE_PLUGIN_ROOT}/a", args: ["z"] }] }] } },
      "p2/.claude-plugin/plugin.json": { hooks: { Stop: [{ hooks: [{ type: "command", command: "inline" }] }] } },
      "p3/.claude-plugin/plugin.json": { hooks: ["./extra/h.json"] },
      "p3/extra/h.json": { hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "viapath" }] }] } },
      "p4/hooks/hooks.json": { hooks: { Stop: [{ hooks: [{ type: "command", command: "dup" }] }] } },
      "p4/.claude-plugin/plugin.json": { hooks: "./hooks/hooks.json" },
    });
    try {
      const mk = (n) => ({ key: `${n}@m`, name: n, installPath: path.join(t.home, n), exists: true });
      const hs = collectHooks({ merged: {}, plugins: [mk("p1"), mk("p2"), mk("p3"), mk("p4"), { key: "gone@m", installPath: path.join(t.home, "gone"), exists: false }] });
      expect(hs.map((h) => [h.origin, h.event, h.command])).toEqual([
        ["plugin:p1@m", "SessionStart", "x ${CLAUDE_PLUGIN_ROOT}/a"],
        ["plugin:p2@m", "Stop", "inline"],
        ["plugin:p3@m", "PreToolUse", "viapath"],
        ["plugin:p4@m", "Stop", "dup"], // same file reached twice, read once
      ]);
      expect(hs[0].pluginRoot).toBe(path.join(t.home, "p1"));
      expect(hs[0].args).toEqual(["z"]);
      expect(hs[0].matcher).toBe("startup");
    } finally {
      t.cleanup();
    }
  });

  test("malformed groups and handlers are skipped, never thrown", () => {
    const merged = { hooks: { Stop: [null, { hooks: "x" }, { hooks: [null, { type: "command", command: "ok.sh" }] }], Bad: "nope" } };
    expect(collectHooks({ merged, plugins: [] }).map((h) => h.command)).toEqual(["ok.sh"]);
    expect(collectHooks({})).toEqual([]);
  });

  test("shared reader and enumerate see the same sources", () => {
    const t = makeHome({
      "p3/.claude-plugin/plugin.json": { hooks: ["./extra/h.json"] },
      "p3/extra/h.json": { hooks: { Weird: [{ hooks: [{ type: "command", command: "v", novel: 1 }] }] } },
    });
    try {
      const p = { key: "p3@m", name: "p3", installPath: path.join(t.home, "p3"), exists: true };
      expect(pluginHookSources(p.installPath).length).toBe(1);
      expect(enumerate({ plugins: [p] }).map((u) => u.key)).toEqual(expect.arrayContaining(["hooks.event.Weird", "hooks.field.novel"]));
    } finally {
      t.cleanup();
    }
  });
});

describe("dispositionFor", () => {
  const e = (origin, event, command, extra = {}) => ({ origin, event, command, ...extra });
  const rows = [
    ["superpowers SessionStart", e("plugin:superpowers@superpowers-dev", "SessionStart", '"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start'), "skip", /superpowers OC adapter/],
    ["explanatory SessionStart", e("plugin:explanatory-output-style@claude-plugins-official", "SessionStart", 'bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/session-start.sh"'), "skip", /cosmetic/],
    ["serena activate", e("settings:user", "SessionStart", "serena-hooks activate --client=claude-code"), "skip", /hand-ported/],
    ["serena remind", e("settings:user", "PreToolUse", "serena-hooks remind --client=claude-code"), "skip", /hand-ported/],
    ["serena auto-approve", e("settings:user", "PreToolUse", "serena-hooks auto-approve --client=claude-code"), "skip", /hand-ported/],
    ["serena cleanup", e("settings:user", "Stop", "serena-hooks cleanup --client=claude-code"), "skip", /hand-ported/],
    ["serena by absolute exe path", e("settings:user", "Stop", '"C:\\tools\\bin\\serena-hooks.exe" cleanup'), "skip", /hand-ported/],
    ["job-state-nudge", e("plugin:personal@progdroid", "PostToolUse", 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/job-state-nudge.sh"'), "cc-only", /backgroundTaskId/],
    ["auto-commit", e("plugin:personal@progdroid", "Stop", 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/auto-commit.sh"'), "bridge", /cloud/],
    ["semgrep SessionEnd", e("plugin:semgrep@claude-plugins-official", "SessionEnd", '"${CLAUDE_PLUGIN_ROOT}/scripts/hook"', { args: ["claude", "SessionEnd"] }), "degraded", /exit/],
  ];
  for (const [name, entry, disp, reason] of rows) {
    test(name, () => {
      const d = dispositionFor(entry);
      expect(d.disposition).toBe(disp);
      expect(d.reason).toMatch(reason);
      expect(d.classified).toBe(true);
    });
  }
  test("semgrep's other events are NOT degraded (unclassified bridge)", () => {
    const d = dispositionFor(e("plugin:semgrep@claude-plugins-official", "PreToolUse", '"${CLAUDE_PLUGIN_ROOT}/scripts/hook"'));
    expect(d).toMatchObject({ disposition: "bridge", classified: false });
  });
  test("superpowers' other events are not skipped", () => {
    expect(dispositionFor(e("plugin:superpowers@superpowers-dev", "Stop", "x.sh")).disposition).toBe("bridge");
  });
  test("a script name only matches as a whole basename", () => {
    expect(dispositionFor(e("settings:user", "Stop", "bash not-auto-commit.sh.bak")).classified).toBe(false);
  });
  test("unknown hook -> bridge, unclassified", () => {
    const d = dispositionFor(e("settings:user", "PostToolUse", "format-code.sh"));
    expect(d.disposition).toBe("bridge");
    expect(d.classified).toBe(false);
    expect(typeof d.reason).toBe("string");
  });
  test("dispositions.json holds no machine paths or ids", () => {
    const raw = fs.readFileSync(path.join(import.meta.dir, "../core/dispositions.json"), "utf8");
    expect(raw).not.toMatch(/[A-Za-z]:[\\/]|\/Users\/|\/home\//);
    expect(raw).not.toMatch(/"id"/);
  });
});

describe("user-local dispositions file", () => {
  const e = (origin, event, command) => ({ origin, event, command });
  const withFile = (content) => {
    const t = makeHome({ "d/cc-parity-dispositions.json": content });
    return { t, env: { CC_PARITY_DISPOSITIONS: path.join(t.home, "d/cc-parity-dispositions.json") } };
  };

  test("a missing file is no error: shipped rules only", () => {
    const r = loadRules({ CC_PARITY_DISPOSITIONS: path.join(import.meta.dir, "no-such-dir", "x.json") });
    expect(r.problem).toBeNull();
    expect(r.rules).toEqual(RULES);
  });
  test("user rules are merged in and classify their hooks", () => {
    const { t, env } = withFile(JSON.stringify({ rules: [{ script: "guard-a.sh", disposition: "cc-only", reason: "needs transcript_path" }] }));
    try {
      const r = loadRules(env);
      expect(r.problem).toBeNull();
      expect(r.rules.length).toBe(RULES.length + 1);
      expect(dispositionFor(e("settings:user", "Stop", 'bash "/x/guard-a.sh"'), r.rules)).toMatchObject({ disposition: "cc-only", classified: true });
      // shipped rules still apply
      expect(dispositionFor(e("settings:user", "Stop", "serena-hooks cleanup"), r.rules).disposition).toBe("skip");
      // without the user's rules the hook is unclassified
      expect(dispositionFor(e("settings:user", "Stop", "bash guard-a.sh")).classified).toBe(false);
    } finally {
      t.cleanup();
    }
  });
  test("a user entry wins over a shipped rule with the same key", () => {
    const { t, env } = withFile(JSON.stringify({ rules: [{ script: "auto-commit.sh", disposition: "skip", reason: "mine" }] }));
    try {
      const r = loadRules(env);
      expect(r.rules.length).toBe(RULES.length);
      expect(dispositionFor(e("plugin:personal@x", "Stop", "bash auto-commit.sh"), r.rules)).toMatchObject({ disposition: "skip", reason: "mine" });
    } finally {
      t.cleanup();
    }
  });
  test("a user rule listed first wins over a shipped rule with a different key", () => {
    const { t, env } = withFile(JSON.stringify({ rules: [{ script: "serena-hooks", event: "Stop", disposition: "bridge", reason: "mine" }] }));
    try {
      const r = loadRules(env);
      expect(dispositionFor(e("settings:user", "Stop", "serena-hooks cleanup"), r.rules).reason).toBe("mine");
      expect(dispositionFor(e("settings:user", "PreToolUse", "serena-hooks pre"), r.rules).disposition).toBe("skip");
    } finally {
      t.cleanup();
    }
  });
  for (const [name, content] of [["malformed JSON", "{ not json"], ["wrong shape", '{"rules":"x"}'], ["rule without disposition", '{"rules":[{"script":"a"}]}']]) {
    test(`${name}: shipped rules only, a problem is reported`, () => {
      const { t, env } = withFile(content);
      try {
        const r = loadRules(env);
        expect(r.rules).toEqual(RULES);
        expect(r.problem).toMatch(/ignored/);
      } finally {
        t.cleanup();
      }
    });
  }
  test("buildInventory surfaces the malformed-file problem as an unknown item", async () => {
    const { buildInventory } = await import("../core/inventory.js");
    const { makeCcHome } = await import("./helpers.js");
    const { t, env } = withFile("{ nope");
    const h = makeCcHome();
    try {
      const inv = buildInventory({ home: h.home, projectDir: h.projectDir, env });
      expect(inv.unknown.some((u) => u.key === "dispositions" && /ignored/.test(u.note))).toBe(true);
    } finally {
      t.cleanup();
      h.cleanup();
    }
  });
});
