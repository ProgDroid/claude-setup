import { describe, test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { makeCcHome } from "./helpers.js";
import { createV1, newPartId, READ_ONLY_AGENTS, LINE_MAX, GROUP_SEP, hookName, shortName } from "../v1/plugin.js";
import { stateStore } from "../core/state.js";
import { projectKey } from "../core/mcp.js";
import { UNTRUSTED_NOTE } from "../core/settings.js";
import { PATCH_BLOCK_REASON } from "../core/toolmap.js";
import { parseChangelog, hookDigest, knownSet } from "../core/releasenotes.js";
import { evaluate, fromConfig, defaults, planRuleset } from "./oc-matcher.js";
import * as adapter from "../adapter.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const cleanups = [];
afterEach(() => {
  while (cleanups.length) cleanups.pop()();
});

const HOOKS = {
  PreToolUse: [
    { matcher: "Bash", hooks: [{ type: "command", command: "deny-rm", if: "Bash(rm *)" }] },
    { matcher: "Bash", hooks: [{ type: "command", command: "guard-commit", if: "Bash(git commit *)" }] },
    { matcher: "Edit|Write", hooks: [{ type: "command", command: "edit-guard" }] },
    { matcher: "mcp__serena__.*", hooks: [{ type: "command", command: "serena-pre" }] },
    { matcher: "Glob", hooks: [{ type: "command", command: "async-hook", async: true }] },
    { matcher: "*", hooks: [{ type: "command", command: "serena-hooks pre" }, { type: "command", command: "job-state-nudge.sh" }] },
  ],
  PostToolUse: [{ matcher: "Bash|mcp__serena__.*", hooks: [{ type: "command", command: "post-ctx" }] }],
  SessionStart: [{ hooks: [{ type: "command", command: "ss-ctx" }] }],
  Stop: [{ hooks: [{ type: "command", command: "stop-hook" }] }],
  UserPromptSubmit: [{ hooks: [{ type: "command", command: "ups" }] }],
  PreCompact: [{ hooks: [{ type: "command", command: "precompact" }] }],
};
const json = (o) => JSON.stringify(o);
const RESULTS = {
  "deny-rm": { status: 2, stderr: "no rm allowed" },
  "post-ctx": { stdout: json({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: "POST-CTX" } }) },
  "ss-ctx": { stdout: "SS-CONTEXT" },
  ups: { stdout: "UPS-CONTEXT" },
  precompact: { stdout: json({ hookSpecificOutput: { additionalContext: "PC-CTX" } }) },
};

function fakeClient(parents = {}) {
  const calls = {};
  return {
    calls,
    session: {
      get: async ({ path: { id } }) => {
        calls[id] = (calls[id] ?? 0) + 1;
        await Promise.resolve();
        return { data: { id, ...(parents[id] ? { parentID: parents[id] } : {}) } };
      },
    },
  };
}

// One fake CC home + state file shared by every session (createV1 call) made from it.
function harness({ settings = { hooks: HOOKS }, parents = {}, results = {}, env = {}, cc = {}, seedState } = {}) {
  const h = makeCcHome(settings);
  cleanups.push(h.cleanup);
  const stateFile = path.join(h.home, "scratch", "state.json");
  if (seedState) {
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.writeFileSync(stateFile, json(seedState));
  }
  const spawned = [];
  const logs = [];
  const all = { ...RESULTS, ...results };
  // Fake runner.runHook: records every spawn; an async entry reports a failure via onDetached.
  const runHook = async (e, input, opts) => {
    spawned.push({ command: e.command, event: e.event, input, opts, entry: e });
    if (e.async) {
      opts?.onDetached?.({ status: 1, stdout: "", stderr: "", timedOut: false, detached: true, failed: true });
      return { status: 0, stdout: "", stderr: "", timedOut: false, detached: true };
    }
    const r = all[e.command];
    return { status: 0, stdout: "", stderr: "", timedOut: false, ...(typeof r === "function" ? r(input, e) : r || {}) };
  };
  const client = fakeClient(parents);
  const make = (over = {}, dir = h.projectDir) =>
    createV1(
      { client, directory: dir, worktree: dir },
      {
        home: h.home,
        env,
        stateFile,
        runHook,
        log: (m) => logs.push(String(m)),
        ccVersion: () => cc.cur ?? null,
        ocVersion: () => "1.19.0",
        fetchChangelog: async () => cc.md ?? null,
        onExit: () => {},
        flushMs: 5,
        ...over,
      },
    );
  const disk = () => stateStore(stateFile);
  const cmds = (event) => spawned.filter((s) => !event || s.event === event).map((s) => s.command);
  return { h, stateFile, spawned, logs, client, make, disk, cmds };
}

let msgN = 0;
const msg = (sessionID, text = "hello") => {
  const n = ++msgN;
  return [
    { sessionID },
    { message: { id: `msg_${n}`, sessionID, role: "user" }, parts: [{ id: `prt_u${n}`, type: "text", text, sessionID, messageID: `msg_${n}` }] },
  ];
};
const parityOf = (out) => out.parts.filter((p) => typeof p.text === "string" && p.text.includes("CC parity: "));
const say = async (v1, sid, text) => {
  const [i, o] = msg(sid, text);
  await v1["chat.message"](i, o);
  return o;
};

describe("config", () => {
  test("merges the permission baseline (a baseline key survives); edit \"*\" asks first (R45); surfaces appended and deduped", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = {
      permission: { read: { "*.pem": "deny" }, bash: { "rm -rf *": "deny" } },
      skills: { paths: ["/pre/skills"] },
      mcp: { mine: { type: "local", command: ["x"] } },
      instructions: ["/pre/rules.md"],
      command: { pre: { template: "p" } },
    };
    await v1.config(cfg);
    expect(cfg.permission.read["*.pem"]).toBe("deny");
    expect(cfg.permission.bash["rm -rf *"]).toBe("deny");
    expect(cfg.permission.bash["git status"]).toBe("allow");
    expect(cfg.permission.edit["src/**"]).toBe("allow");
    expect(Object.entries(cfg.permission.edit)[0]).toEqual(["*", "ask"]);
    expect(cfg.skills.paths[0]).toBe("/pre/skills");
    expect(cfg.skills.paths).toContain(H.h.semgrep);
    expect(cfg.mcp.mine).toBeDefined();
    expect(cfg.mcp.serena.command).toContain("--context=agent");
    expect(cfg.instructions[0]).toBe("/pre/rules.md");
    expect(cfg.instructions).toContain(path.join(H.h.home, ".claude", "rules", "style.md"));
    expect(cfg.agent.rev.permission["*"]).toBe("deny");
    expect(cfg.command.pre.template).toBe("p");
    expect(cfg.command.hi).toBeDefined();
    const n = cfg.skills.paths.length;
    await v1.config(cfg); // a second call appends nothing new
    expect(cfg.skills.paths.length).toBe(n);
    expect(new Set(cfg.instructions).size).toBe(cfg.instructions.length);
  });

  test("R36: agents get the toOcPermission output layered on the baseline (a baseline \"*\" carries in)", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = { permission: { grep: "ask" } };
    await v1.config(cfg);
    // rev allows Grep; the user's effective grep rule is the baseline's "ask"
    expect(cfg.agent.rev.permission.grep).toBe("ask");
  });

  test("R34: a CC Edit allow cannot loosen the plan or explore agents' edit deny (OC matcher copy)", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    const home = H.h.home;
    // control: without the re-assertion the CC allow (src/**) wins for plan -> discriminating
    expect(evaluate("edit", "src/a.ts", ...planRuleset(cfg.permission, home)).action).toBe("allow");
    const plan = [...planRuleset(cfg.permission, home), fromConfig(cfg.agent.plan.permission, home)];
    expect(evaluate("edit", "src/a.ts", ...plan).action).toBe("deny");
    expect(evaluate("edit", path.join(".opencode", "plans", "x.md"), ...plan).action).toBe("allow");
    const exploreBase = [defaults(home), fromConfig({ "*": "deny", read: "allow", grep: "allow" }, home), fromConfig(cfg.permission, home)];
    expect(evaluate("edit", "src/a.ts", ...exploreBase).action).toBe("allow");
    expect(evaluate("edit", "src/a.ts", ...exploreBase, fromConfig(cfg.agent.explore.permission, home)).action).toBe("deny");
    for (const a of READ_ONLY_AGENTS) expect(Object.keys(cfg.agent[a].permission.edit)[0]).toBe("*");
  });

  test("R34: a user's own OC agent-level edit rule is kept and still wins after the re-assertion", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = { agent: { plan: { permission: { edit: { "docs/**": "allow" } }, model: "m" } } };
    await v1.config(cfg);
    expect(cfg.agent.plan.model).toBe("m");
    const e = cfg.agent.plan.permission.edit;
    expect(e["*"]).toBe("deny");
    expect(Object.keys(e).at(-1)).toBe("docs/**");
    const plan = [...planRuleset(cfg.permission, H.h.home), fromConfig(cfg.agent.plan.permission, H.h.home)];
    expect(evaluate("edit", "docs/a.md", ...plan).action).toBe("allow");
    expect(evaluate("edit", "src/a.ts", ...plan).action).toBe("deny");
  });

  test("superpowers adapter missing -> a problem in the parity line, never a throw", async () => {
    const H = harness();
    let v1;
    await expect((async () => (v1 = await H.make()))()).resolves.toBeDefined();
    await v1.config({});
    const out = await say(v1, "ses_a");
    expect(parityOf(out)[0].text).toContain("4 problems"); // the 4th name folds into "+1"
    expect(H.logs.some((l) => l.startsWith("  parity [problem] superpowers 7.0.0 OC adapter unavailable"))).toBe(true);
    expect(H.logs.join("\n")).toContain("superpowers 7.0.0 OC adapter unavailable");
  });

  test("superpowers adapter present -> its config runs after ours and messages.transform is delegated", async () => {
    const H = harness();
    H.h.w(path.join(H.h.sp, ".opencode", "plugins", "superpowers.js"), [
      "export const SuperpowersPlugin = async ({ directory }) => ({",
      "  config: async (c) => { c.skills = c.skills || {}; c.skills.paths = c.skills.paths || []; c.skills.paths.push('SP-MARK:' + typeof directory); },",
      "  'experimental.chat.messages.transform': async (_i, o) => { o.messages.push('SP-TRANSFORM'); },",
      "});",
      "export default { id: 'superpowers', server: SuperpowersPlugin };",
    ].join("\n"));
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    expect(cfg.skills.paths.at(-1)).toBe("SP-MARK:string");
    expect(cfg.skills.paths).toContain(H.h.semgrep);
    const o = { messages: [] };
    await v1["experimental.chat.messages.transform"]({}, o);
    expect(o.messages).toEqual(["SP-TRANSFORM"]);
    const out = await say(v1, "ses_a");
    expect(parityOf(out)[0].text).not.toContain("superpowers");
  });

  test("a superpowers adapter whose factory throws -> a problem and a log line, no throw", async () => {
    const H = harness();
    H.h.w(path.join(H.h.sp, ".opencode", "plugins", "superpowers.js"), "export const SuperpowersPlugin = async () => { throw new Error('sp-boom'); };\n");
    const v1 = await H.make();
    await v1.config({});
    const o = { messages: [] };
    await v1["experimental.chat.messages.transform"]({}, o);
    expect(o.messages).toEqual([]);
    expect(parityOf(await say(v1, "ses_a"))[0].text).toContain("4 problems");
    expect(H.logs.some((l) => l.startsWith("  parity [problem] superpowers 7.0.0 OC adapter unavailable"))).toBe(true);
    expect(H.logs.join("\n")).toContain("sp-boom");
  });
});

describe("tool.execute.before", () => {
  test("blocks on deny (exit 2 -> a throw carrying stderr)", async () => {
    const H = harness();
    const v1 = await H.make();
    await expect(v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c1" }, { args: { command: "rm -rf build" } })).rejects.toThrow("no rm allowed");
  });

  test("a JSON permissionDecision deny and ask both block", async () => {
    for (const d of ["deny", "ask"]) {
      const H = harness({ results: { "edit-guard": { stdout: json({ hookSpecificOutput: { permissionDecision: d, permissionDecisionReason: "R-" + d } }) } } });
      const v1 = await H.make();
      await expect(v1["tool.execute.before"]({ tool: "edit", sessionID: "s", callID: "c" }, { args: { filePath: "/p/a.ts", oldString: "a", newString: "b" } })).rejects.toThrow("R-" + d);
    }
  });

  test("skips non-matching hooks without spawning", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1["tool.execute.before"]({ tool: "read", sessionID: "s", callID: "c" }, { args: { filePath: "/p/a.ts" } });
    expect(H.spawned).toEqual([]);
  });

  test("an `if`-filtered hook is not spawned for `git status`, and is spawned for `git commit`", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c1" }, { args: { command: "git status" } });
    expect(H.cmds("PreToolUse")).toEqual([]);
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c2" }, { args: { command: "git commit -m x" } });
    expect(H.cmds("PreToolUse")).toEqual(["guard-commit"]);
    expect(H.spawned[0].input.tool_name).toBe("Bash");
    expect(H.spawned[0].input.tool_input).toEqual({ command: "git commit -m x" });
    expect(H.spawned[0].input.tool_use_id).toBe("c2");
  });

  test("skip / cc-only hooks never run, even with a match-all matcher", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1["tool.execute.before"]({ tool: "edit", sessionID: "s", callID: "c" }, { args: { filePath: "/p/a.ts", oldString: "a", newString: "b" } });
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args: { command: "git commit -m y" } });
    await v1["tool.execute.after"]({ tool: "bash", sessionID: "s", callID: "c", args: { command: "ls" } }, { title: "", output: "x", metadata: {} });
    await v1.event({ event: { type: "session.idle", properties: { sessionID: "ses_top" } } });
    expect(H.cmds()).toContain("edit-guard");
    expect(H.cmds()).not.toContain("serena-hooks pre");
    expect(H.cmds()).not.toContain("job-state-nudge.sh");
  });

  test("an MCP tool reaches an mcp__serena__.* hook under its CC name", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1.config({});
    await v1["tool.execute.before"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c" }, { args: { name_path: "X" } });
    expect(H.cmds("PreToolUse")).toEqual(["serena-pre"]);
    expect(H.spawned[0].input.tool_name).toBe("mcp__serena__find_symbol");
    expect(H.spawned[0].input.tool_input).toEqual({ name_path: "X" });
  });

  test("bash workdir becomes the hook cwd (R6)", async () => {
    const H = harness();
    const v1 = await H.make();
    const wd = path.join(H.h.projectDir, "sub");
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args: { command: "git commit -m z", workdir: wd } });
    expect(H.spawned[0].input.cwd).toBe(wd);
    expect(H.spawned[0].opts.cwd).toBe(wd);
  });

  test("R32: an unrepresentable apply_patch blocks deliberately, spawns nothing, and is counted", async () => {
    const H = harness();
    const v1 = await H.make();
    await expect(
      v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, { args: { patchText: "*** Begin Patch\n*** Frobnicate File: a\n*** End Patch" } }),
    ).rejects.toThrow(PATCH_BLOCK_REASON);
    expect(H.spawned).toEqual([]);
    await v1.dispose();
    expect(H.disk().failures.list().map((f) => f.hookId)).toContain("apply_patch");
    expect(H.logs.join("\n")).toContain(PATCH_BLOCK_REASON);
  });

  test("updatedInput is applied IN PLACE to output.args (OC executes the original args object)", async () => {
    const H = harness({ results: { "guard-commit": { stdout: json({ hookSpecificOutput: { updatedInput: { command: "git commit -m fixed" } } }) } } });
    const v1 = await H.make();
    const output = { args: { command: "git commit -m bad", timeout: 5 } };
    const ref = output.args;
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, output);
    expect(output.args).toBe(ref);
    // CC replaces the input (R51 I-1/m-6): the hook returned no timeout, so the optional arg goes
    expect(ref).toEqual({ command: "git commit -m fixed" });
  });

  test("records each tool's arg names into state.observed.args (built-in and MCP)", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1.config({});
    await v1["tool.execute.before"]({ tool: "read", sessionID: "s", callID: "c" }, { args: { filePath: "/x", weird: 1 } });
    await v1["tool.execute.before"]({ tool: "read", sessionID: "s", callID: "c" }, { args: { filePath: "/x", offset: 2 } });
    await v1["tool.execute.before"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c" }, { args: { name_path: "X" } });
    await v1.dispose();
    expect(H.disk().observed.args.get("read").sort()).toEqual(["filePath", "offset", "weird"]);
    expect(H.disk().observed.args.get("serena_find_symbol")).toEqual(["name_path"]);
  });

  test("R26: a detached (async) hook's failure reaches state.failures through onDetached", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1["tool.execute.before"]({ tool: "glob", sessionID: "s", callID: "c" }, { args: { pattern: "*.ts" } });
    expect(H.cmds("PreToolUse")).toEqual(["async-hook"]);
    await v1.dispose();
    const id = H.spawned[0].entry.id;
    expect(H.disk().failures.list().map((f) => f.hookId)).toContain(id);
  });

  // Final review Minor 1 (was pinned non-blocking by mutation M12): a matched guard whose run fails
  // must not let the tool through unguarded.
  test("an internal error after a PreToolUse entry MATCHED (the runner throws) blocks, and is logged and counted", async () => {
    const H = harness();
    const v1 = await H.make({ runHook: async () => { throw new Error("kaboom"); } });
    await expect(v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args: { command: "git commit -m x" } })).rejects.toThrow("failed closed");
    expect(H.logs.join("\n")).toContain("kaboom");
    await v1.dispose();
    expect(H.disk().failures.list().map((f) => f.hookId)).toContain("adapter:tool.execute.before");
  });
});

describe("tool.execute.after", () => {
  test("appends PostToolUse context to output.output, with a CC-shaped tool_response", async () => {
    const H = harness();
    const v1 = await H.make();
    const out = { title: "", output: "hello\n\n<shell_metadata>\nUser aborted the command\n</shell_metadata>", metadata: {} };
    await v1["tool.execute.after"]({ tool: "bash", sessionID: "s", callID: "c", args: { command: "echo hello" } }, out);
    expect(out.output).toContain("POST-CTX");
    expect(out.output.startsWith("hello")).toBe(true);
    const post = H.spawned.find((s) => s.event === "PostToolUse");
    expect(post.input.tool_response).toMatchObject({ stdout: "hello", interrupted: true });
  });

  test("MCP: context is appended to output.content as a text item (R8)", async () => {
    const H = harness();
    const v1 = await H.make();
    await v1.config({});
    const out = { content: [{ type: "text", text: "r" }], structuredContent: {}, isError: false };
    await v1["tool.execute.after"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c", args: { name_path: "X" } }, out);
    expect(out.output).toBeUndefined();
    expect(out.content.at(-1)).toEqual({ type: "text", text: "POST-CTX" });
    expect(H.spawned.find((s) => s.event === "PostToolUse").input.tool_response).toEqual([{ type: "text", text: "r" }]);
  });

  test("non-matching tools spawn nothing; a PreToolUse additionalContext is carried to the result", async () => {
    const H = harness({ results: { "guard-commit": { stdout: json({ hookSpecificOutput: { additionalContext: "PRE-CTX" } }) } } });
    const v1 = await H.make();
    const r = { title: "", output: "x", metadata: {} };
    await v1["tool.execute.after"]({ tool: "read", sessionID: "s", callID: "c0", args: { filePath: "/p" } }, r);
    expect(H.spawned).toEqual([]);
    expect(r.output).toBe("x");
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c9" }, { args: { command: "git commit -m q" } });
    const out = { title: "", output: "done", metadata: {} };
    await v1["tool.execute.after"]({ tool: "bash", sessionID: "s", callID: "c9", args: { command: "git commit -m q" } }, out);
    expect(out.output).toContain("PRE-CTX");
    expect(out.output).toContain("POST-CTX");
  });
});

describe("delivery (chat.message)", () => {
  test("first message: exactly one pushed part holding SessionStart context + the parity line", async () => {
    const H = harness();
    const v1 = await H.make();
    const out = await say(v1, "ses_a");
    const pushed = out.parts.filter((p) => p.id !== out.parts[0].id);
    const parity = parityOf(out);
    expect(parity).toHaveLength(1);
    const p = parity[0];
    expect(p.id).toMatch(/^prt_[0-9a-f]{12}[0-9A-Za-z]{14}$/);
    expect(p).toMatchObject({ type: "text", synthetic: true, sessionID: "ses_a", messageID: out.message.id });
    expect(p.text.startsWith("SS-CONTEXT")).toBe(true);
    expect(p.text).toContain("brandNewSetting");
    expect(p.text).toContain("hooks bridged unreviewed (deny-rm@PreToolUse");
    expect(p.text).not.toMatch(/[0-9a-f]{12}/); // hooks are named, never by id (R42)
    expect(p.text).toContain("1 hook degraded (semgrep:semgrep-end@SessionEnd)");
    expect(p.text).toContain("grep/glob ignore read denies");
    expect(p.text).toMatch(/full list: .*cc-parity\.log$/);
    expect(H.cmds("SessionStart")).toEqual(["ss-ctx"]);
    // UserPromptSubmit runs for the message too, in its own part
    expect(pushed.some((x) => x.text.includes("UPS-CONTEXT") && !x.text.includes("CC parity"))).toBe(true);
    expect(H.spawned.find((s) => s.event === "UserPromptSubmit").input.prompt).toBe("hello");
  });

  test("the second message gets no parity text; UserPromptSubmit still runs", async () => {
    const H = harness();
    const v1 = await H.make();
    await say(v1, "ses_a");
    const out2 = await say(v1, "ses_a", "again");
    expect(parityOf(out2)).toHaveLength(0);
    expect(out2.parts.some((p) => p.text.includes("UPS-CONTEXT"))).toBe(true);
    expect(H.cmds("SessionStart")).toEqual(["ss-ctx"]);
    expect(H.client.calls.ses_a).toBe(1); // isTopLevel is cached per session
  });

  test("a child session's first message gets nothing (no SessionStart, no parity, no UPS)", async () => {
    const H = harness({ parents: { ses_child: "ses_a" } });
    const v1 = await H.make();
    const out = await say(v1, "ses_child");
    expect(out.parts).toHaveLength(1);
    expect(H.spawned).toEqual([]);
    // and the items are still delivered to the next top-level session
    expect(parityOf(await say(v1, "ses_a"))).toHaveLength(1);
  });

  test("an item is marked seen only after the push: a throw while building the part leaves it unseen", async () => {
    const H = harness();
    const v1 = await H.make({ partId: () => { throw new Error("part-boom"); } });
    let out;
    await expect((async () => (out = await say(v1, "ses_a")))()).resolves.toBeDefined();
    expect(parityOf(out)).toHaveLength(0);
    expect(H.logs.join("\n")).toContain("part-boom");
    await v1.dispose();
    const v2 = await H.make();
    expect(parityOf(await say(v2, "ses_b"))[0].text).toContain("brandNewSetting");
  });

  test("delivered items are not repeated in the next session; no items -> no line", async () => {
    const H = harness({ settings: {} });
    const v1 = await H.make();
    expect(parityOf(await say(v1, "ses_a"))).toHaveLength(1);
    await v1.dispose();
    const v2 = await H.make();
    const out = await say(v2, "ses_b");
    expect(parityOf(out)).toHaveLength(0);
    expect(out.parts).toHaveLength(1); // no SessionStart hooks, no UPS, nothing to push
  });

  test("a hook failure (exit 1) appears in the next session's parity line, once", async () => {
    const H = harness({ results: { "edit-guard": { status: 1, stderr: "broke" } } });
    const s1 = await H.make();
    await say(s1, "ses_1");
    await s1["tool.execute.before"]({ tool: "edit", sessionID: "ses_1", callID: "c" }, { args: { filePath: "/p/a", oldString: "a", newString: "b" } });
    await s1.dispose();
    const id = H.spawned.find((s) => s.command === "edit-guard").entry.id;
    const s2 = await H.make();
    const line = parityOf(await say(s2, "ses_2"))[0].text;
    expect(line).toContain("1 hook failure (edit-guard@PreToolUse)");
    expect(line).not.toContain(id);
    expect(H.logs.some((l) => l.includes(`failure ${id} edit-guard@PreToolUse`) && l.includes("exit 1: broke"))).toBe(true);
    await s2.dispose();
    const s3 = await H.make();
    const out3 = await say(s3, "ses_3");
    expect(parityOf(out3).map((p) => p.text).join("")).not.toContain("hook failure");
  });

  test("tool.definition feeds an unknown OC tool into the NEXT session's parity line", async () => {
    const H = harness({ settings: {} });
    const s1 = await H.make();
    expect(parityOf(await say(s1, "ses_1"))[0].text).not.toContain("brand_new_oc_tool");
    await s1["tool.definition"]({ toolID: "brand_new_oc_tool" }, { description: "", parameters: {} });
    await s1["tool.definition"]({ toolID: "bash" }, { description: "", parameters: {} });
    await s1.dispose();
    expect(H.disk().observed.tools.list().sort()).toEqual(["bash", "brand_new_oc_tool"]);
    const s2 = await H.make();
    const line = parityOf(await say(s2, "ses_2"))[0].text;
    expect(line).toContain("brand_new_oc_tool");
    expect(line).not.toMatch(/\bbash\b.*no tool-map row/);
  });

  test("self-probe: an arg name observed last session that the tool map does not expect is reported", async () => {
    const H = harness({ settings: {} });
    const s1 = await H.make();
    await say(s1, "ses_1");
    await s1["tool.execute.before"]({ tool: "read", sessionID: "ses_1", callID: "c" }, { args: { path: "/renamed" } });
    await s1.dispose();
    const s2 = await H.make();
    const line = parityOf(await say(s2, "ses_2"))[0].text;
    expect(line).toContain("1 OC arg drift (read.path)");
    expect(H.logs.join("\n")).toMatch(/self-probe: OC tool read sent arg "path"/);
    expect(H.disk().versions.oc).toBe("1.19.0");
  });

  test("concurrent first messages in one session (a noReply prompt racing the user's) -> one parity part", async () => {
    const H = harness();
    const v1 = await H.make();
    const [i1, o1] = msg("ses_a", "nudge");
    const [i2, o2] = msg("ses_a", "user");
    await Promise.all([v1["chat.message"](i1, o1), v1["chat.message"](i2, o2)]);
    expect(parityOf(o1).length + parityOf(o2).length).toBe(1);
    expect(H.cmds("SessionStart")).toEqual(["ss-ctx"]);
  });

  test("a prompt made only of synthetic parts is neither delivered to nor UPS-hooked", async () => {
    const H = harness();
    const v1 = await H.make();
    const [i, o] = msg("ses_a", "continue");
    o.parts[0].synthetic = true;
    await v1["chat.message"](i, o);
    expect(o.parts).toHaveLength(1);
    expect(H.spawned).toEqual([]);
  });

  test("a UserPromptSubmit block never throws: the model is told the prompt was blocked", async () => {
    const H = harness({ settings: {}, results: {} });
    H.h.w(".claude/settings.json", { hooks: { UserPromptSubmit: [{ hooks: [{ type: "command", command: "ups-block" }] }] } });
    const v1 = await H.make({ runHook: async () => ({ status: 2, stdout: "", stderr: "no secrets in prompts", timedOut: false }) });
    let out;
    await expect((async () => (out = await say(v1, "ses_a")))()).resolves.toBeDefined();
    const blocked = out.parts.find((p) => p.text.includes("no secrets in prompts"));
    expect(blocked.text).toContain("UserPromptSubmit hook blocked this prompt");
  });

  test("kind-3: one digest item per CC version change, recorded only after delivery (stored version semver-normalised)", async () => {
    const md = fs.readFileSync(path.join(here, "fixtures", "changelog-sample.md"), "utf8");
    const H = harness({ settings: {}, cc: { cur: "2.1.5", md }, seedState: { versions: { cc: "2.1.0 (Claude Code)" } } });
    const s1 = await H.make();
    await s1.config({});
    expect(H.disk().versions.cc).toBe("2.1.0 (Claude Code)");
    const digest = hookDigest(parseChangelog(md), "2.1.0", "2.1.5", knownSet());
    expect(digest).not.toBeNull();
    const line = parityOf(await say(s1, "ses_1"))[0].text;
    expect(line).toContain("1 CC changelog digest (2.1.0->2.1.5: ");
    expect(H.logs.join("\n")).toContain(digest);
    await s1.dispose();
    expect(H.disk().versions.cc).toBe("2.1.5");
    const s2 = await H.make();
    expect(parityOf(await say(s2, "ses_2"))).toHaveLength(0);
  });

  test("kind-3: a failed changelog fetch records nothing, so the range is retried", async () => {
    const H = harness({ settings: {}, cc: { cur: "2.1.5", md: null }, seedState: { versions: { cc: "2.1.0" } } });
    const s1 = await H.make();
    await say(s1, "ses_1");
    await s1.dispose();
    expect(H.disk().versions.cc).toBe("2.1.0");
  });

  test("kind-3: first run (nothing stored) records the current CC version with no item", async () => {
    const H = harness({ settings: {}, cc: { cur: "2.1.5", md: "## 2.1.5\n- Added `newHookThing` hook\n" } });
    const s1 = await H.make();
    const line = parityOf(await say(s1, "ses_1"))[0].text;
    expect(line).not.toContain("changelog");
    await s1.dispose();
    expect(H.disk().versions.cc).toBe("2.1.5");
  });
});

describe("event, compaction, shell.env, dispose", () => {
  test("Stop runs on session.idle for a top-level session and is skipped for children", async () => {
    const H = harness({ parents: { ses_child: "ses_a" } });
    const v1 = await H.make();
    await v1.event({ event: { type: "session.idle", properties: { sessionID: "ses_child" } } });
    expect(H.cmds("Stop")).toEqual([]);
    await v1.event({ event: { type: "session.idle", properties: { sessionID: "ses_a" } } });
    expect(H.cmds("Stop")).toEqual(["stop-hook"]);
    expect(H.spawned[0].input.stop_hook_active).toBe(false);
    await v1.event({ event: { type: "session.created", properties: { info: { id: "ses_z" } } } });
    expect(H.cmds()).toEqual(["stop-hook"]); // no injection, no hooks on other events
  });

  test("R24: a Stop decision:block is logged as not honoured", async () => {
    const H = harness({ results: { "stop-hook": { stdout: json({ decision: "block", reason: "keep going" }) } } });
    const v1 = await H.make();
    await v1.event({ event: { type: "session.idle", properties: { sessionID: "ses_a" } } });
    expect(H.logs.join("\n")).toContain("not honoured: Stop decision:block");
  });

  test("PreCompact context goes to output.context", async () => {
    const H = harness();
    const v1 = await H.make();
    const out = { context: [] };
    await v1["experimental.session.compacting"]({ sessionID: "ses_a" }, out);
    expect(out.context).toEqual(["PC-CTX"]);
  });

  test("shell.env adds the merged settings env and prepends each enabled, existing plugin's bin/ to PATH (R17)", async () => {
    const H = harness();
    const v1 = await H.make();
    const out = { env: {} };
    await v1["shell.env"]({ cwd: H.h.projectDir, sessionID: "s", callID: "c" }, out);
    expect(out.env.CC_TEST_ENV).toBe("on");
    const key = Object.keys(process.env).find((k) => k.toLowerCase() === "path") ?? "PATH";
    expect(out.env[key].split(path.delimiter)[0]).toBe(path.join(H.h.semgrep, "bin"));
    expect(out.env[key]).not.toContain(path.join(H.h.sp, "bin"));
    expect(out.env[key].endsWith(process.env[key] ?? "")).toBe(true);
    const again = { env: { [key]: "/other" } };
    await v1["shell.env"]({ cwd: H.h.projectDir }, again);
    expect(again.env[key]).toBe(path.join(H.h.semgrep, "bin") + path.delimiter + "/other");
  });

  test("dispose runs SessionEnd for started top-level sessions (best effort) and flushes", async () => {
    const H = harness();
    const v1 = await H.make();
    await say(v1, "ses_a");
    await v1.dispose();
    const end = H.spawned.filter((s) => s.event === "SessionEnd");
    expect(end.map((s) => s.command)).toEqual(["semgrep-end"]);
    expect(end[0].input.reason).toBe("other");
    expect(fs.existsSync(H.stateFile)).toBe(true);
  });
});

describe("R42: one compact parity line, full list in cc-parity.log", () => {
  // Shaped like the reviewer's real-home case: 28 unclassified hooks, 8 notTranslated notes (each
  // holding "; "), problems, a degraded hook, and an unknown whose name holds " | ".
  function realShapedHarness() {
    const pre = Array.from({ length: 28 }, (_, i) => ({ matcher: i % 2 ? "Bash" : "Edit|Write", hooks: [{ type: "command", command: `bash ~/.claude/hooks/guard-${i}.sh` }] }));
    const H = harness({
      settings: {
        hooks: { PreToolUse: pre },
        env: { CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1", CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "70", ENABLE_LSP_TOOL: "1", ENABLE_LSP_TOOLS: "1" },
        autoCompactWindow: 1,
        effortLevel: "high",
        modelSettings: {},
        permissions: { allow: ["Read([ab] | x)"] },
      },
    });
    H.h.w(".claude.json", { claudeAiMcpEverConnected: true, projects: { "/elsewhere": { hasTrustDialogAccepted: true } }, mcpServers: {} });
    return H;
  }

  test("(a) the line is <= 500 chars, grouped with the right counts, and splits unambiguously on \" | \"", async () => {
    const H = realShapedHarness();
    const v1 = await H.make();
    await v1.config({});
    const out = await say(v1, "ses_a");
    const line = parityOf(out)[0].text;
    expect(line.length).toBeLessThanOrEqual(LINE_MAX);
    expect(line.includes("\n")).toBe(false);
    const groups = line.slice("CC parity: ".length).split(GROUP_SEP);
    expect(groups.at(-1)).toMatch(/^full list: .*cc-parity\.log$/);
    const body = groups.slice(0, -1);
    for (const g of body) expect(g).toMatch(/^\d+ [A-Za-z ]+( \(.*\))?$/);
    const count = (label) => Number(body.find((g) => new RegExp(`^\\d+ ${label}\\b`).test(g))?.split(" ")[0]);
    expect(count("not translated")).toBe(8);
    expect(count("hooks bridged unreviewed")).toBe(28);
    expect(count("hook degraded")).toBe(1);
    expect(count("problems")).toBe(4); // code mode, CC skills, R35, superpowers
    expect(body.find((g) => g.startsWith("28 hooks"))).toMatch(/\(guard-0\.sh@PreToolUse, guard-1\.sh@PreToolUse.*\+2[0-9]\)/);
    expect(line).toContain("[ab]|x"); // the " | " inside a rule name was collapsed
    // splitting is unambiguous: the groups' counts add up to the logged item count
    const logged = H.logs.filter((l) => l.startsWith("  parity [")).length;
    expect(body.reduce((s, g) => s + Number(g.split(" ")[0]), 0)).toBe(logged);
  });

  test("(b) cc-parity.log holds every item, one per line, ids included, under a header", async () => {
    const H = realShapedHarness();
    const v1 = await H.make();
    await v1.config({});
    await say(v1, "ses_a");
    const header = H.logs.findIndex((l) => /^CC parity delivered to ses_a: \d+ items; line \(\d+ chars\): CC parity: /.test(l));
    expect(header).toBeGreaterThanOrEqual(0);
    const items = H.logs.slice(header + 1).filter((l) => l.startsWith("  parity ["));
    expect(Number(/: (\d+) items/.exec(H.logs[header])[1])).toBe(items.length);
    const bridged = items.filter((l) => l.startsWith("  parity [bridged]"));
    expect(bridged).toHaveLength(28);
    for (let i = 0; i < 28; i++) expect(bridged.some((l) => l.includes(`guard-${i}.sh@PreToolUse`) && /[0-9a-f]{12}/.test(l))).toBe(true);
    const nt = items.filter((l) => l.startsWith("  parity [notTranslated]"));
    expect(nt).toHaveLength(8);
    for (const k of ["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "ENABLE_LSP_TOOL", "ENABLE_LSP_TOOLS", "autoCompactWindow", "effortLevel", "modelSettings", "claudeAiMcpEverConnected"]) {
      expect(nt.some((l) => l.includes(k))).toBe(true);
    }
    expect(items.some((l) => l.includes("OC grep/glob ignore read denies; CC Read denies do not protect"))).toBe(true);
  });

  test("(c) no hook appears by id in the line; items are still seen after delivery", async () => {
    const H = realShapedHarness();
    const v1 = await H.make();
    await v1.config({});
    const line = parityOf(await say(v1, "ses_a"))[0].text;
    const ids = H.logs.filter((l) => l.startsWith("  parity [bridged]")).map((l) => /\b([0-9a-f]{12})\b/.exec(l)[1]);
    expect(ids).toHaveLength(28);
    for (const id of ids) expect(line).not.toContain(id);
    expect(line).not.toMatch(/[0-9a-f]{12}/);
    await v1.dispose();
    const v2 = await H.make();
    expect(parityOf(await say(v2, "ses_b"))).toHaveLength(0);
  });

  test("hookName N1: a quoted path with a space stays one token (the home-path-with-a-space case)", () => {
    expect(hookName({ command: 'bash "D:/Home Dir/A B/.claude/hooks/reindex-a.sh"', event: "PostToolUse" })).toBe("reindex-a.sh@PostToolUse");
    expect(hookName({ command: '"D:/Home Dir/A B/.claude/hooks/mirror-a.sh" --quiet', event: "SessionStart" })).toBe("mirror-a.sh@SessionStart");
    expect(hookName({ command: "bash 'D:/Home Dir/A B/x y/z.sh'", event: "Stop" })).toBe("z.sh@Stop");
  });

  test("hookName: an unquoted path -> the basename of the first token", () => {
    expect(hookName({ command: "~/.claude/hooks/format-code.sh --fix", event: "PostToolUse" })).toBe("format-code.sh@PostToolUse");
    expect(hookName({ command: "${CLAUDE_PLUGIN_ROOT}/scripts/hook SessionStart", event: "SessionStart" })).toBe("hook@SessionStart");
    expect(hookName({ command: "serena-hooks activate --client=claude-code", event: "SessionStart" })).toBe("serena-hooks@SessionStart");
    expect(hookName({ command: "", event: "Stop" })).toBe("hook@Stop");
  });

  test("hookName: an interpreter first -> the basename of its script argument", () => {
    expect(hookName({ command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/check.sh" --x', event: "Stop" })).toBe("check.sh@Stop");
    expect(hookName({ command: "py -3 C:\\x\\tool.py", event: "PreToolUse" })).toBe("tool.py@PreToolUse");
    expect(hookName({ command: 'powershell -NoProfile -ExecutionPolicy Bypass -File "C:\\a b\\guard.ps1"', event: "PreToolUse" })).toBe("guard.ps1@PreToolUse");
    expect(hookName({ command: "uv run hooks/lint.py", event: "PostToolUse" })).toBe("lint.py@PostToolUse");
    expect(hookName({ command: "FOO=1 node ./s.js", event: "Stop" })).toBe("s.js@Stop");
    expect(hookName({ command: "bash", event: "Stop" })).toBe("bash@Stop"); // nothing after it: the interpreter itself
  });

  test("hookName: exec form with args -> the command's basename, or an interpreter's script arg", () => {
    expect(hookName({ command: "/opt/p/scripts/hook", args: ["claude", "x"], event: "SessionEnd" })).toBe("hook@SessionEnd");
    expect(hookName({ command: "C:/Program Files/x/run-me.exe", args: ["--a"], event: "Stop" })).toBe("run-me.exe@Stop");
    expect(hookName({ command: "node", args: ["C:/a b/s.js", "--x"], event: "PreToolUse" })).toBe("s.js@PreToolUse");
  });

  test("hookName: plugin hooks are <plugin>:<basename>@<event>; settings hooks are not prefixed", () => {
    expect(hookName({ command: "${CLAUDE_PLUGIN_ROOT}/scripts/hook", args: ["claude", "x"], event: "SessionEnd", origin: "plugin:semgrep@claude-plugins-official" })).toBe("semgrep:hook@SessionEnd");
    expect(hookName({ command: "bash ~/.claude/hooks/x.sh", event: "Stop", origin: "settings:user" })).toBe("x.sh@Stop");
  });

  test("shortName: a name can never hold the group separator; head or tail truncation", () => {
    expect(shortName("a | b |c|  d")).toBe("a|b|c|d");
    expect(shortName("x\n | y")).not.toContain(GROUP_SEP);
    expect(shortName("y".repeat(50), 10)).toBe("yyyyyyy...");
    expect(shortName("command:commit-commands:clean_gone", 20, true)).toBe("...mmands:clean_gone");
    expect(shortName("command:commit-commands:clean_gone", 20, true)).toHaveLength(20);
  });

  test("unknown names keep their tail in the line, so similar keys stay distinguishable", async () => {
    const H = harness({ settings: { commitCommandsCleanGoneAndMoreKeyTail_clean_gone: 1 } });
    const v1 = await H.make();
    const line = parityOf(await say(v1, "ses_a"))[0].text;
    const g = line.split(GROUP_SEP).find((x) => /^(CC parity: )?\d+ unknown/.test(x));
    expect(g).toContain("...GoneAndMoreKeyTail_clean_gone"); // the last 29 chars of the key
    expect(g).not.toContain("commitCommands"); // the head is what was cut
  });

  test("N2: seen is conditional on the log write: a failed full-list write leaves the items unseen", async () => {
    const H = harness({ settings: {} });
    const lines = [];
    const s1 = await H.make({ log: (m) => { lines.push(String(m)); return !String(m).startsWith("  parity ["); } });
    expect(parityOf(await say(s1, "ses_1"))[0].text).toContain("brandNewSetting");
    expect(lines.some((l) => l.startsWith("cc-parity.log write failed"))).toBe(true);
    await s1.dispose();
    const s2 = await H.make();
    const line2 = parityOf(await say(s2, "ses_2"))[0].text;
    expect(line2).toContain("brandNewSetting"); // repeated, not lost
    await s2.dispose();
    const s3 = await H.make();
    expect(parityOf(await say(s3, "ses_3"))).toHaveLength(0); // logged fine in s2, so now seen
  });
});

describe("I2: apply_patch fan-out through PreToolUse", () => {
  const patch = (...ops) => ["*** Begin Patch", ...ops, "*** End Patch"].join("\n");

  test("a deny on a NON-last fanned-out call blocks the whole patch, and every call's hooks run", async () => {
    const H = harness();
    const v1 = await H.make();
    const p = patch("*** Delete File: b.txt", "*** Add File: a.txt", "+hello");
    await expect(v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, { args: { patchText: p } })).rejects.toThrow("no rm allowed");
    expect(H.cmds("PreToolUse")).toEqual(["deny-rm", "edit-guard"]);
    expect(H.spawned[0].input.tool_input.command).toMatch(/^rm -- .*b\.txt'?$/);
    expect(H.spawned[1].input.tool_input.file_path).toBe(path.join(H.h.projectDir, "a.txt"));
  });

  test("every fanned-out call gets its PreToolUse hooks (three hunks -> three Edit hook runs)", async () => {
    const H = harness();
    const v1 = await H.make();
    const p = patch("*** Update File: src/x.ts", "@@", "-a", "+A", "@@", "-b", "+B", "@@", "-c", "+C");
    await v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, { args: { patchText: p } });
    const edits = H.spawned.filter((s) => s.command === "edit-guard");
    expect(edits).toHaveLength(3);
    expect(edits.map((s) => s.input.tool_input.old_string)).toEqual(["a", "b", "c"]);
    for (const s of edits) expect(s.input.tool_input.file_path).toBe(path.join(H.h.projectDir, "src", "x.ts"));
  });

  // R48 (a): a sanitising hook's rewrite must never be silently dropped, so an updatedInput the
  // adapter cannot apply BLOCKS the call (it used to run the original args, logged and counted).
  const UNAPPLIED = "hook rewrote the input but the rewrite can't be applied in OpenCode";
  test("R48: a multi-call updatedInput BLOCKS, args untouched; still logged and counted", async () => {
    const H = harness({ results: { "edit-guard": { stdout: json({ hookSpecificOutput: { updatedInput: { content: "SANITISED" } } }) } } });
    const v1 = await H.make();
    const p = patch("*** Add File: a.txt", "+one", "*** Add File: b.txt", "+two");
    const output = { args: { patchText: p } };
    await expect(v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, output)).rejects.toThrow(`${UNAPPLIED}: apply_patch maps to 2 CC calls`);
    expect(output.args).toEqual({ patchText: p });
    expect(H.logs.join("\n")).toContain("updatedInput ignored: apply_patch maps to 2 CC calls");
    await v1.dispose();
    const f = H.disk().failures.list().filter((x) => x.msg.startsWith("updatedInput not honoured"));
    expect(f).toHaveLength(2);
    expect(f[0].hookId).toBe(H.spawned[0].entry.id);
  });

  test("R48: a single-call updatedInput on a tool with no reverse map (MCP) BLOCKS too", async () => {
    const H = harness({ results: { "serena-pre": { stdout: json({ hookSpecificOutput: { updatedInput: { name_path: "Y" } } }) } } });
    const v1 = await H.make();
    await v1.config({});
    const output = { args: { name_path: "X" } };
    await expect(v1["tool.execute.before"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c" }, output)).rejects.toThrow(`${UNAPPLIED}: no reverse arg map for OC serena_find_symbol`);
    expect(output.args).toEqual({ name_path: "X" });
    await v1.dispose();
    expect(H.disk().failures.list().some((x) => x.msg === "updatedInput not honoured: no reverse arg map for OC serena_find_symbol")).toBe(true);
  });

  test("R48: a rewrite of a field OC's tool has no arg for (bash run_in_background) BLOCKS; nothing is half-applied", async () => {
    const H = harness({ results: { "guard-commit": { stdout: json({ hookSpecificOutput: { updatedInput: { command: "git commit -m safe", run_in_background: true } } }) } } });
    const v1 = await H.make();
    const output = { args: { command: "git commit -m x" } };
    await expect(v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, output)).rejects.toThrow(`${UNAPPLIED}: no OC bash arg for run_in_background`);
    expect(output.args).toEqual({ command: "git commit -m x" });
  });

  test("R48 control: a mappable rewrite, alone or echoing the whole CC input back, is applied, not blocked", async () => {
    const H = harness({ results: { "guard-commit": { stdout: json({ hookSpecificOutput: { updatedInput: { command: "git commit -m safe" } } }) } } });
    const v1 = await H.make();
    const output = { args: { command: "git commit -m x", timeout: 5 } };
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, output);
    expect(output.args.command).toBe("git commit -m safe");
    const H2 = harness({ results: { "guard-commit": (input) => ({ stdout: json({ hookSpecificOutput: { updatedInput: { ...input.tool_input, command: "git commit -m safe2" } } }) }) } });
    const v2 = await H2.make();
    const out2 = { args: { command: "git commit -m x", timeout: 5 } };
    await v2["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, out2);
    expect(out2.args).toEqual({ command: "git commit -m safe2", timeout: 5 });
  });

  // Round 4 m3: a hook that echoes its call's input back unchanged rewrote nothing, so the R48
  // checks (multi-call, no reverse map, unmapped key) do not apply on ANY tool.
  const echo = (input) => ({ stdout: json({ hookSpecificOutput: { updatedInput: { ...input.tool_input } } }) });
  test("m3: an unchanged echo passes on a tool with no reverse map (MCP), with nothing counted", async () => {
    const H = harness({ results: { "serena-pre": echo } });
    const v1 = await H.make();
    await v1.config({});
    const output = { args: { name_path: "X" } };
    await v1["tool.execute.before"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c" }, output);
    expect(output.args).toEqual({ name_path: "X" });
    await v1.dispose();
    expect(H.disk().failures.list().some((x) => x.msg.startsWith("updatedInput not honoured"))).toBe(false);
  });
  test("m3: an unchanged echo passes on a multi-call apply_patch", async () => {
    const H = harness({ results: { "edit-guard": echo } });
    const v1 = await H.make();
    const p = patch("*** Add File: a.txt", "+one", "*** Add File: b.txt", "+two");
    const output = { args: { patchText: p } };
    await v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, output);
    expect(output.args).toEqual({ patchText: p });
    expect(H.spawned.filter((s) => s.command === "edit-guard")).toHaveLength(2);
  });
  test("m3 control: one changed rewrite among echoes still blocks a multi-call apply_patch", async () => {
    let n = 0;
    const H = harness({ results: { "edit-guard": (input) => (n++ === 0 ? echo(input) : { stdout: json({ hookSpecificOutput: { updatedInput: { content: "SANITISED" } } }) }) } });
    const v1 = await H.make();
    const p = patch("*** Add File: a.txt", "+one", "*** Add File: b.txt", "+two");
    await expect(v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, { args: { patchText: p } })).rejects.toThrow(`${UNAPPLIED}: apply_patch maps to 2 CC calls`);
  });
  // Round 5 I-1: CC REPLACES the input with updatedInput (bundle Xwe: `e.updatedInput??n`), so a
  // hook that returns its input minus a key is a real rewrite, not an echo.
  const minus = (k) => (input) => {
    const u = { ...input.tool_input };
    delete u[k];
    return { stdout: json({ hookSpecificOutput: { updatedInput: u } }) };
  };
  test("I-1: a key-stripping updatedInput on an MCP tool BLOCKS (no reverse map), args untouched, counted", async () => {
    const H = harness({ results: { "serena-pre": minus("force") } });
    const v1 = await H.make();
    await v1.config({});
    const output = { args: { name_path: "X", force: true } };
    await expect(v1["tool.execute.before"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c" }, output)).rejects.toThrow(`${UNAPPLIED}: no reverse arg map for OC serena_find_symbol`);
    expect(output.args).toEqual({ name_path: "X", force: true });
    await v1.dispose();
    expect(H.disk().failures.list().some((x) => x.msg === "updatedInput not honoured: no reverse arg map for OC serena_find_symbol")).toBe(true);
  });
  test("I-1 control: an exact echo of the same two-key MCP input still passes", async () => {
    const H = harness({ results: { "serena-pre": echo } });
    const v1 = await H.make();
    await v1.config({});
    const output = { args: { name_path: "X", force: true } };
    await v1["tool.execute.before"]({ tool: "serena_find_symbol", sessionID: "s", callID: "c" }, output);
    expect(output.args).toEqual({ name_path: "X", force: true });
  });
  // Round 5 m-6: on bash/edit/write a dropped mapped arg is honoured when OC's arg is optional
  // (bash timeout, edit replaceAll: removed from the OC args), and BLOCKS when OC requires it.
  test("m-6: a hook dropping an optional arg removes it from the OC args (bash timeout, edit replaceAll)", async () => {
    const H = harness({ results: { "guard-commit": minus("timeout") } });
    const v1 = await H.make();
    const output = { args: { command: "git commit -m x", timeout: 5, workdir: "." } };
    const ref = output.args;
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, output);
    expect(output.args).toBe(ref);
    expect(ref).toEqual({ command: "git commit -m x", workdir: "." });
    const H2 = harness({ results: { "edit-guard": minus("replace_all") } });
    const v2 = await H2.make();
    const out2 = { args: { filePath: path.join(H2.h.projectDir, "a.txt"), oldString: "a", newString: "b", replaceAll: true } };
    await v2["tool.execute.before"]({ tool: "edit", sessionID: "s", callID: "c" }, out2);
    expect(out2.args).toEqual({ filePath: path.join(H2.h.projectDir, "a.txt"), oldString: "a", newString: "b" });
  });
  test("m-6: a hook dropping an arg OC requires BLOCKS with the R48 message; nothing is half-applied", async () => {
    const H = harness({ results: { "edit-guard": minus("new_string") } });
    const v1 = await H.make();
    const args = { filePath: path.join(H.h.projectDir, "a.txt"), oldString: "a", newString: "b" };
    const output = { args: { ...args } };
    await expect(v1["tool.execute.before"]({ tool: "edit", sessionID: "s", callID: "c" }, output)).rejects.toThrow(`${UNAPPLIED}: the hook dropped new_string, which OC edit requires`);
    expect(output.args).toEqual(args);
    const H2 = harness({ results: { "guard-commit": minus("command") } });
    const v2 = await H2.make();
    const out2 = { args: { command: "git commit -m x", timeout: 5 } };
    await expect(v2["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, out2)).rejects.toThrow(`${UNAPPLIED}: the hook dropped command, which OC bash requires`);
    expect(out2.args).toEqual({ command: "git commit -m x", timeout: 5 });
  });
});

describe("review minors: never-throw edges and kind-3 errors", () => {
  test("a throwing log cannot turn the R32 block into a swallowed error", async () => {
    const H = harness();
    // Throws only on the R32 message, so init (which logs the superpowers problem) is not what fails.
    const v1 = await H.make({ log: (m) => { if (String(m).startsWith("blocked")) throw new Error("log-down"); } });
    await expect(
      v1["tool.execute.before"]({ tool: "apply_patch", sessionID: "s", callID: "c" }, { args: { patchText: "*** Begin Patch\n*** Frobnicate File: a\n*** End Patch" } }),
    ).rejects.toThrow(PATCH_BLOCK_REASON);
  });

  test("a throwing log at init (superpowers problem path) still builds the front-end", async () => {
    const H = harness();
    let v1;
    await expect((async () => (v1 = await H.make({ log: () => { throw new Error("log-down"); } })))()).resolves.toBeDefined();
    expect(typeof v1["chat.message"]).toBe("function");
  });

  test("a kind-3 error is logged and counted, not silently dropped", async () => {
    const H = harness({ settings: {}, seedState: { versions: { cc: "2.1.0" } } });
    const s1 = await H.make({ ccVersion: () => { throw new Error("cc-version-boom"); } });
    const line = parityOf(await say(s1, "ses_1"))[0].text;
    expect(H.logs.join("\n")).toContain("kind3: cc-version-boom");
    // counted: the failure is listed before the line is built, so it surfaces in this very line
    expect(line).toContain("1 hook failure (adapter:kind3)");
    expect(H.logs.some((l) => l.startsWith("  parity [failure] failure adapter:kind3") && l.endsWith("cc-version-boom"))).toBe(true);
    await s1.dispose();
    expect(H.disk().versions.cc).toBe("2.1.0"); // nothing recorded, so it is retried
  });
});

describe("newPartId and adapter.js", () => {
  test("part ids are OC-format and ascending", () => {
    const a = newPartId();
    const b = newPartId();
    expect(a).toMatch(/^prt_[0-9a-f]{12}[0-9A-Za-z]{14}$/);
    expect(a.slice(0, 16) < b.slice(0, 16)).toBe(true);
  });

  test("adapter.js: id, server, and a default export OC's V1 loader accepts", async () => {
    expect(adapter.id).toBe("cc-parity");
    expect(typeof adapter.server).toBe("function");
    expect(adapter.default).toEqual({ id: "cc-parity", server: adapter.server });
  });

  test("adapter.js: a front-end that throws while building resolves to {} and logs", async () => {
    const logs = [];
    const hooks = await adapter.safeServer({}, async () => { throw new Error("init-boom"); }, (m) => logs.push(m));
    expect(hooks).toEqual({});
    expect(logs.join("\n")).toContain("init-boom");
  });
});

describe("config: uncovered -> ask (R45) against OC's agent.ts merge", () => {
  // agent.ts: merge(defaults, <agent's own rules>, user), then the cfg.agent.<name>.permission merge.
  const generalRs = (cfg, home) => [defaults(home), fromConfig({ todowrite: "deny" }, home), fromConfig(cfg.permission, home)];
  const buildRs = (cfg, home) => [defaults(home), fromConfig({ question: "allow", plan_enter: "allow" }, home), fromConfig(cfg.permission, home)];
  test('the user edit "*":"ask" would loosen plan/explore (control); R34\'s re-assertion keeps their edit deny', async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    const home = H.h.home;
    expect(Object.entries(cfg.permission.edit)[0]).toEqual(["*", "ask"]);
    // control: without the re-assertion the R45 ask beats plan's built-in edit deny -> discriminating
    expect(evaluate("edit", path.join("lib", "a.ts"), ...planRuleset(cfg.permission, home)).action).toBe("ask");
    const plan = [...planRuleset(cfg.permission, home), fromConfig(cfg.agent.plan.permission, home)];
    expect(evaluate("edit", path.join("lib", "a.ts"), ...plan).action).toBe("deny");
    expect(evaluate("edit", path.join(".opencode", "plans", "x.md"), ...plan).action).toBe("allow");
    const exploreBase = [defaults(home), fromConfig({ "*": "deny", read: "allow", grep: "allow" }, home), fromConfig(cfg.permission, home)];
    expect(evaluate("edit", path.join("lib", "a.ts"), ...exploreBase).action).toBe("ask");
    expect(evaluate("edit", path.join("lib", "a.ts"), ...exploreBase, fromConfig(cfg.agent.explore.permission, home)).action).toBe("deny");
    // the build agent asks for an uncovered edit and keeps the CC allow
    expect(evaluate("edit", path.join("lib", "a.ts"), ...buildRs(cfg, home)).action).toBe("ask");
    expect(evaluate("edit", path.join("src", "a.ts"), ...buildRs(cfg, home)).action).toBe("allow");
  });
  test("question / plan_enter / plan_exit denies are untouched; build keeps its own allows", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = { mcp: { plan: { type: "local", command: ["x"] } } };
    await v1.config(cfg);
    const home = H.h.home;
    expect("*" in cfg.permission).toBe(false);
    for (const p of ["question", "plan_enter", "plan_exit"]) expect([p, evaluate(p, "*", ...generalRs(cfg, home)).action]).toEqual([p, "deny"]);
    expect(evaluate("question", "*", ...buildRs(cfg, home)).action).toBe("allow");
  });
  test("webfetch / websearch ask, task follows CC (no prompt, R49); every configured MCP server (OC's own too) asks before CC's allows", async () => {
    const H = harness({ settings: { hooks: HOOKS, permissions: { allow: ["mcp__serena__find_symbol"] } } });
    const v1 = await H.make();
    const cfg = { mcp: { mine: { type: "local", command: ["x"] } } };
    await v1.config(cfg);
    const home = H.h.home;
    const rs = buildRs(cfg, home);
    expect(evaluate("webfetch", "https://x", ...rs).action).toBe("ask");
    expect(evaluate("websearch", "q", ...rs).action).toBe("ask");
    expect(evaluate("task", "general", ...rs).action).toBe("allow");
    expect(cfg.permission["serena_*"]).toBe("ask");
    expect(cfg.permission["mine_*"]).toBe("ask");
    expect(evaluate("serena_find_symbol", "*", ...rs).action).toBe("allow");
    expect(evaluate("serena_replace_body", "*", ...rs).action).toBe("ask");
    expect(evaluate("mine_tool", "*", ...rs).action).toBe("ask");
  });
});

describe("R47: CC's trust gate on the project scope", () => {
  const projSettings = (H, dir = H.h.projectDir) =>
    H.h.w(path.join(dir, ".claude", "settings.json"), {
      hooks: { SessionStart: [{ hooks: [{ type: "command", command: "proj-start" }] }] },
      permissions: { allow: ["Bash(rm *)"], deny: ["Read(proj-secret.txt)"] },
    });
  const trust = (H, dirs) => H.h.w(".claude.json", { mcpServers: {}, projects: Object.fromEntries(dirs.map((d) => [projectKey(d), { hasTrustDialogAccepted: true }])) });
  // The full itemised parity list in cc-parity.log (R42), one line per delivered item.
  const untrustedLines = (H) => H.logs.filter((l) => l.startsWith("  parity [unknown]") && l.includes(UNTRUSTED_NOTE));

  test("untrusted: the project's hooks never run and its allows never reach cfg.permission; its deny does", async () => {
    const H = harness();
    projSettings(H);
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    expect(cfg.permission.bash["rm *"]).toBeUndefined();
    expect(cfg.permission.read["proj-secret.txt"]).toBe("deny");
    const out = await say(v1, "ses_a");
    expect(H.cmds("SessionStart")).toEqual(["ss-ctx"]); // the user's own SessionStart only
    expect(parityOf(out)).toHaveLength(1);
    const lines = untrustedLines(H);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain(projectKey(H.h.projectDir));
  });

  test("trusted (control): the same project's hook runs and its allow lands; nothing is reported", async () => {
    const H = harness();
    projSettings(H);
    trust(H, [H.h.projectDir]);
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    expect(cfg.permission.bash["rm *"]).toBe("allow");
    await say(v1, "ses_a");
    expect(H.cmds("SessionStart").sort()).toEqual(["proj-start", "ss-ctx"]);
    expect(untrustedLines(H)).toEqual([]);
  });

  test("the report fires once PER DIRECTORY: seen in one directory never silences another", async () => {
    const H = harness();
    projSettings(H);
    const other = fs.mkdtempSync(path.join(path.dirname(H.h.projectDir), "ccp-proj2-"));
    cleanups.push(() => fs.rmSync(other, { recursive: true, force: true }));
    projSettings(H, other);
    await say(await H.make(), "ses_1");
    expect(untrustedLines(H)).toHaveLength(1);
    await say(await H.make(), "ses_2"); // same directory, next session: already seen
    expect(untrustedLines(H)).toHaveLength(1);
    await say(await H.make({}, other), "ses_3"); // another untrusted directory, same state file
    const lines = untrustedLines(H);
    expect(lines).toHaveLength(2);
    expect(lines[1]).toContain(projectKey(other));
    expect(lines[0]).not.toContain(projectKey(other));
  });
});

describe("I5: continue:false through the plugin", () => {
  const stop = (reason) => ({ stdout: json({ continue: false, ...(reason ? { stopReason: reason } : {}) }) });
  test("PreToolUse continue:false blocks the tool with stopReason (a throw), and the unhonoured turn-stop is logged", async () => {
    const H = harness({ results: { "edit-guard": stop("frozen file") } });
    const v1 = await H.make();
    await expect(v1["tool.execute.before"]({ tool: "edit", sessionID: "s", callID: "c" }, { args: { filePath: "a.ts", oldString: "a", newString: "b" } })).rejects.toThrow("frozen file");
    expect(H.logs.some((l) => l.includes("not honoured: PreToolUse continue:false"))).toBe(true);
  });
  test("UserPromptSubmit continue:false goes through the block path (the model is told not to act)", async () => {
    const H = harness({ results: { ups: stop("prompt rejected") } });
    const v1 = await H.make();
    const out = await say(v1, "ses_a", "do the thing");
    const text = out.parts.map((p) => p.text ?? "").join("\n");
    expect(text).toContain("A UserPromptSubmit hook blocked this prompt: prompt rejected");
    expect(text).not.toContain("UPS-CONTEXT");
  });
  test("Stop continue:false is not honoured and is logged, never thrown", async () => {
    const H = harness({ results: { "stop-hook": stop("x") } });
    const v1 = await H.make();
    await expect(v1.event({ event: { type: "session.idle", properties: { sessionID: "ses_top" } } })).resolves.toBeUndefined();
    expect(H.logs.some((l) => l.includes("not honoured: Stop continue:false"))).toBe(true);
  });
});

describe("Minor 1: tool.execute.before fails CLOSED once a PreToolUse entry may apply", () => {
  const throwingArgs = () => ({ get url() { throw new Error("map-boom"); }, get command() { throw new Error("map-boom"); } });
  test("no PreToolUse hook configured: a mapping error stays non-blocking, logged and counted", async () => {
    const H = harness({ settings: { hooks: { Stop: HOOKS.Stop } } });
    const v1 = await H.make();
    await expect(v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args: throwingArgs() })).resolves.toBeUndefined();
    expect(H.logs.join("\n")).toContain("map-boom");
    await v1.dispose();
    expect(H.disk().failures.list().map((f) => f.hookId)).toContain("adapter:tool.execute.before");
  });
  test("PreToolUse hooks configured: the same mapping error BLOCKS (whether a guard applied is unknown)", async () => {
    const H = harness();
    const v1 = await H.make();
    await expect(v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args: throwingArgs() })).rejects.toThrow("failed closed");
    expect(H.logs.join("\n")).toContain("map-boom");
  });
  test("matching proved nothing applies (webfetch: only skip/cc-only entries): a throwing runner is never reached (control)", async () => {
    const H = harness();
    const v1 = await H.make({ runHook: async () => { throw new Error("never-called"); } });
    await expect(v1["tool.execute.before"]({ tool: "webfetch", sessionID: "s", callID: "c" }, { args: { url: "https://x" } })).resolves.toBeUndefined();
    expect(H.logs.join("\n")).not.toContain("never-called");
  });
  test("a bookkeeping error (recording arg names) never blocks and never stops the hooks", async () => {
    const H = harness();
    const v1 = await H.make();
    // ownKeys throws: Object.keys(args) fails while recording arg names (R7), before any matching
    const args = new Proxy({ command: "git commit -m x" }, { ownKeys: () => { throw new Error("args-boom"); } });
    await expect(v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args })).resolves.toBeUndefined();
    expect(H.logs.join("\n")).toContain("args-boom");
    expect(H.cmds("PreToolUse")).toContain("guard-commit"); // the guard still ran
  });
});

describe("Minor 6: non-command hook types are reported, never dispatched", () => {
  test("a prompt-type PreToolUse handler matching the call is not spawned; it is still in the parity report", async () => {
    const H = harness({ settings: { hooks: { ...HOOKS, PreToolUse: [...HOOKS.PreToolUse, { matcher: "Bash", hooks: [{ type: "prompt", prompt: "is this safe?" }] }] } } });
    const v1 = await H.make();
    await v1["tool.execute.before"]({ tool: "bash", sessionID: "s", callID: "c" }, { args: { command: "git commit -m x" } });
    expect(H.cmds("PreToolUse")).toEqual(["guard-commit"]); // control: the matching command hook still ran
    expect(H.spawned.every((s) => s.entry.type === "command")).toBe(true);
    await say(v1, "ses_a");
    expect(H.logs.some((l) => l.startsWith("  parity [unknown]") && l.includes("hooks.type=prompt"))).toBe(true);
  });
});

describe("Minor 7: an OC version change is reported once, as a parity item", () => {
  const ocLines = (H) => H.logs.filter((l) => l.startsWith("  parity [ocVersion]"));
  test("first run records the version without an item; a change gives one item; the next session none", async () => {
    const H = harness({ seedState: { versions: { oc: "1.18.0" } } });
    const out = await say(await H.make(), "ses_1");
    expect(parityOf(out)[0].text).toContain("1 OC version change");
    expect(ocLines(H)).toHaveLength(1);
    expect(ocLines(H)[0]).toContain("OC 1.18.0 -> 1.19.0");
    expect(H.disk().versions.oc).toBe("1.19.0");
    await say(await H.make(), "ses_2");
    expect(ocLines(H)).toHaveLength(1);
  });
  test("no stored OC version: recorded, never reported", async () => {
    const H = harness();
    await say(await H.make(), "ses_1");
    expect(ocLines(H)).toEqual([]);
    expect(H.disk().versions.oc).toBe("1.19.0");
  });
  test("a failed log write leaves the OC version unrecorded, so the item repeats (never lost)", async () => {
    const H = harness({ seedState: { versions: { oc: "1.18.0" } } });
    await say(await H.make({ log: () => false }), "ses_1");
    expect(H.disk().versions.oc).toBe("1.18.0");
  });
});

describe("Minor 9: the serena override marker never reaches cfg.mcp", () => {
  test("cfg.mcp.serena carries no `override` key; the rewritten context is kept", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    expect(cfg.mcp.serena.command).toContain("--context=agent");
    expect("override" in cfg.mcp.serena).toBe(false);
  });
});

describe("Minor 2: an inventory failure falls back to the baseline plus a fail-closed overlay", () => {
  const boom = () => { throw new Error("inventory-boom"); };
  test("bash/edit/skill '*' ask, webfetch/websearch ask, no task key (R49), baseline keys kept, plan's edit deny re-asserted", async () => {
    const H = harness();
    const v1 = await H.make({ buildInventory: boom });
    const cfg = { permission: { bash: { "rm -rf *": "deny" }, read: { "*.pem": "deny" } }, mcp: { mine: { type: "local", command: ["x"] } } };
    await v1.config(cfg);
    const p = cfg.permission;
    expect(Object.entries(p.bash)[0]).toEqual(["*", "ask"]);
    expect(p.bash["rm -rf *"]).toBe("deny");
    expect(p.read["*.pem"]).toBe("deny");
    expect(Object.entries(p.edit)[0]).toEqual(["*", "ask"]);
    expect("task" in p).toBe(false);
    expect(p.skill).toEqual({ "*": "ask" });
    expect(p.webfetch).toBe("ask");
    expect(p.websearch).toBe("ask");
    expect(p["mine_*"]).toBe("ask");
    const home = H.h.home;
    const plan = [...planRuleset(p, home), fromConfig(cfg.agent.plan.permission, home)];
    expect(evaluate("edit", path.join("lib", "a.ts"), ...plan).action).toBe("deny");
    expect(H.logs.join("\n")).toContain("inventory-boom");
  });
  test("a stricter baseline survives the overlay; a looser one is tightened to ask", async () => {
    const H = harness();
    const v1 = await H.make({ buildInventory: boom });
    const cfg = { permission: { webfetch: "deny", websearch: "allow", bash: { "*": "allow" } } };
    await v1.config(cfg);
    expect(cfg.permission.webfetch).toBe("deny");
    expect(cfg.permission.websearch).toBe("ask");
    expect(cfg.permission.bash["*"]).toBe("ask");
  });
  test("the failure is a problem item in the parity line", async () => {
    const H = harness();
    const out = await say(await H.make({ buildInventory: boom }), "ses_a");
    expect(parityOf(out)[0].text).toContain("CC inventory failed");
    expect(H.logs.some((l) => l.startsWith("  parity [problem]") && l.includes("CC inventory failed"))).toBe(true);
  });
});

describe("Minor 3: MCP secrets never reach the log or a pushed part", () => {
  test("a header secret and an env secret stay out of H.logs, every pushed part and the state file", async () => {
    const SECRET_H = "Bearer SECRET-HDR-7f3a91";
    const SECRET_E = "SECRET-ENV-9c1d42";
    const H = harness();
    H.h.w(".claude.json", {
      mcpServers: {
        serena: { command: "uvx", args: ["serena", "start-mcp-server", "--context=claude-code"] },
        remote: { type: "http", url: "https://mcp.example.test/x", headers: { Authorization: SECRET_H } },
        local: { command: "srv", env: { API_KEY: SECRET_E } },
      },
    });
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    // positive control: the secrets really are carried (in memory, into cfg.mcp)
    expect(cfg.mcp.remote.headers.Authorization).toBe(SECRET_H);
    expect(cfg.mcp.local.environment.API_KEY).toBe(SECRET_E);
    const parts = [];
    for (const sid of ["ses_a", "ses_b"]) parts.push(...(await say(v1, sid)).parts);
    await v1["tool.execute.before"]({ tool: "remote_query", sessionID: "ses_a", callID: "c1" }, { args: { q: "x" } });
    await v1["tool.execute.after"]({ tool: "remote_query", sessionID: "ses_a", callID: "c1", args: { q: "x" } }, { content: [{ type: "text", text: "r" }] });
    await v1.dispose();
    const hay = [...H.logs, ...parts.map((p) => JSON.stringify(p)), fs.readFileSync(H.stateFile, "utf8")].join("\n");
    expect(hay.length).toBeGreaterThan(100); // the haystack is not empty
    expect(hay).toContain("CC parity: "); // and holds the delivered line
    expect(hay).not.toContain("SECRET-HDR");
    expect(hay).not.toContain("SECRET-ENV");
  });
});

describe("R48 (b): R45's user-level keys never loosen an OC built-in deny (agent.ts merge order)", () => {
  // OC v1.19.0 agent.ts: merge(defaults, <agent's own rules>, user), then cfg.agent.<name>.permission.
  const own = {
    explore: { "*": "deny", grep: "allow", glob: "allow", list: "allow", bash: "allow", webfetch: "allow", websearch: "allow", read: "allow" },
    compaction: { "*": "deny" },
    title: { "*": "deny" },
    summary: { "*": "deny" },
    general: { todowrite: "deny" },
    plan: { question: "allow", plan_exit: "allow", task: { general: "deny" } },
  };
  const rs = (cfg, name, home, withAgent = true) => [
    defaults(home),
    fromConfig(own[name], home),
    fromConfig(cfg.permission, home),
    ...(withAgent ? [fromConfig(cfg.agent?.[name]?.permission ?? {}, home)] : []),
  ];
  const act = (cfg, name, perm, pattern, home, withAgent) => evaluate(perm, pattern, ...rs(cfg, name, home, withAgent)).action;
  const setup = async () => {
    const H = harness({ settings: { hooks: HOOKS, permissions: { allow: ["mcp__serena__find_symbol", "TodoWrite", "Agent(general)", "Skill(my-skill)"] } } });
    const v1 = await H.make();
    const cfg = { mcp: { mine: { type: "local", command: ["x"] } } };
    await v1.config(cfg);
    return { H, cfg, home: H.h.home };
  };

  test("the deny-all built-ins (compaction/title/summary/explore) keep deny for task, skill, the MCP servers and (unless built-in allowed) webfetch/websearch", async () => {
    const { cfg, home } = await setup();
    for (const name of ["compaction", "title", "summary", "explore"]) {
      const checks = [["task", "general"], ["skill", "my-skill"], ["serena_replace_body", "*"], ["serena_find_symbol", "*"], ["mine_tool", "*"]];
      if (name !== "explore") checks.push(["webfetch", "https://x"], ["websearch", "q"]);
      for (const [perm, pat] of checks) {
        // control: without the agent-level re-assertion the user-level key loosens the built-in deny
        expect([name, perm, act(cfg, name, perm, pat, home, false)]).not.toEqual([name, perm, "deny"]);
        expect([name, perm, act(cfg, name, perm, pat, home)]).toEqual([name, perm, "deny"]);
      }
    }
  });
  test("explore's built-in webfetch/websearch ALLOWS are not re-asserted: the R45 ask may still make them stricter", async () => {
    const { cfg, home } = await setup();
    expect(cfg.agent.explore.permission.webfetch).toBeUndefined();
    expect(cfg.agent.explore.permission.websearch).toBeUndefined();
    expect(act(cfg, "explore", "webfetch", "https://x", home)).toBe("ask");
    expect(act(cfg, "explore", "websearch", "q", home)).toBe("ask");
    expect(act(cfg, "explore", "read", "a.ts", home)).toBe("allow"); // untouched built-in allow
  });
  test("plan's built-in task.general deny and general's todowrite deny survive R45 / a CC TodoWrite allow", async () => {
    const { cfg, home } = await setup();
    expect(act(cfg, "plan", "task", "general", home, false)).toBe("allow"); // control: the CC Agent(general) allow loosens it
    expect(act(cfg, "plan", "task", "general", home)).toBe("deny");
    expect(act(cfg, "plan", "task", "explore", home)).toBe("allow"); // R49: CC runs uncovered subagents without a prompt
    expect(act(cfg, "general", "todowrite", "*", home, false)).toBe("allow"); // control: the CC allow loosens it
    expect(act(cfg, "general", "todowrite", "*", home)).toBe("deny");
  });
  test("a user's own OC agent-level rule for one of these keys is kept and still wins", async () => {
    const H = harness();
    const v1 = await H.make();
    const cfg = { agent: { explore: { permission: { task: { general: "allow" } } }, compaction: { permission: { webfetch: "allow" } } } };
    await v1.config(cfg);
    expect(act(cfg, "explore", "task", "general", H.h.home)).toBe("allow");
    expect(act(cfg, "explore", "task", "other", H.h.home)).toBe("deny");
    expect(act(cfg, "compaction", "webfetch", "https://x", H.h.home)).toBe("allow");
  });
  test("the inventory-failure overlay gets the same re-assertion", async () => {
    const H = harness();
    const v1 = await H.make({ buildInventory: () => { throw new Error("inv-boom"); } });
    const cfg = { mcp: { mine: { type: "local", command: ["x"] } } };
    await v1.config(cfg);
    for (const [perm, pat] of [["task", "general"], ["skill", "x"], ["webfetch", "https://x"], ["mine_tool", "*"]]) {
      expect([perm, act(cfg, "summary", perm, pat, H.h.home)]).toEqual([perm, "deny"]);
    }
  });
});

// Round 4 m6: plan's re-asserted plan-file edit allows (agent.ts) merge after the user rules, so
// they would beat a CC Edit deny that covers them. They are dropped when such a deny exists.
describe("m6: a CC Edit deny beats plan's re-asserted plan-file edit allow", () => {
  const planEdit = async (deny) => {
    const H = harness({ settings: { hooks: HOOKS, permissions: { deny } } });
    const v1 = await H.make();
    const cfg = {};
    await v1.config(cfg);
    const home = H.h.home;
    const plan = [...planRuleset(cfg.permission, home), fromConfig(cfg.agent.plan.permission, home)];
    return { cfg, act: evaluate("edit", path.join(".opencode", "plans", "x.md"), ...plan).action };
  };
  test("Edit(**/*.md) deny: plan cannot edit its plan file; both allow keys are dropped", async () => {
    const { cfg, act } = await planEdit(["Edit(**/*.md)"]);
    expect(act).toBe("deny");
    expect(Object.values(cfg.agent.plan.permission.edit)).toEqual(["deny"]);
  });
  test("control: an unrelated Edit deny keeps the plan-file allow", async () => {
    const { cfg, act } = await planEdit(["Edit(secret.txt)"]);
    expect(act).toBe("allow");
    expect(Object.values(cfg.agent.plan.permission.edit).filter((v) => v === "allow")).toHaveLength(2);
  });
});
