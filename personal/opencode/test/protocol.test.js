import { describe, expect, test } from "bun:test";
import { buildInput, interpret, askMessage, INPUT_FIELDS, OUTPUT_FIELDS, EVENTS } from "../core/protocol.js";

describe("exported field lists (Task 9 fold-in: releasenotes `known` imports these)", () => {
  test("INPUT_FIELDS is exactly the union of buildInput keys over every event", () => {
    const full = { sessionId: "s", cwd: "/w", toolName: "Bash", toolInput: {}, toolUseId: "t", toolResponse: {}, prompt: "p" };
    const union = new Set(EVENTS.flatMap((e) => Object.keys(buildInput(e, full))));
    expect([...INPUT_FIELDS].sort()).toEqual([...union].sort());
    for (const f of ["tool_input", "tool_name", "session_id", "hook_event_name", "tool_response", "transcript_path", "permission_mode", "cwd", "tool_use_id", "stop_hook_active"]) {
      expect(INPUT_FIELDS).toContain(f);
    }
  });
  test("EVENTS covers the seven bridged events; OUTPUT_FIELDS the recognised output keys", () => {
    expect([...EVENTS].sort()).toEqual(["PostToolUse", "PreCompact", "PreToolUse", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"]);
    for (const f of ["decision", "hookSpecificOutput", "permissionDecision", "updatedInput", "additionalContext"]) expect(OUTPUT_FIELDS).toContain(f);
    // recognised output keys never land in unknownFields
    const r = interpret("PreToolUse", { status: 0, stdout: JSON.stringify({ decision: "x", hookSpecificOutput: { updatedInput: {} } }), stderr: "" });
    expect(r.unknownFields).toEqual([]);
  });
});

const ok = (stdout, extra = {}) => ({ status: 0, stdout, stderr: "", timedOut: false, ...extra });
const hso = (o) => JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", ...o } });

describe("buildInput", () => {
  const ctx = { sessionId: "s1", cwd: "/w", permissionMode: "auto", toolName: "Bash", toolInput: { command: "ls" }, toolUseId: "t1", toolResponse: { out: "x" }, prompt: "hi" };
  test("common fields on every event", () => {
    for (const ev of ["PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart", "Stop", "PreCompact", "SessionEnd", "Unknown"]) {
      const o = buildInput(ev, ctx);
      expect(o.session_id).toBe("s1");
      expect(o.transcript_path).toBeNull();
      expect(o.cwd).toBe("/w");
      expect(o.hook_event_name).toBe(ev);
      expect(o.permission_mode).toBe("auto");
    }
  });
  test("PreToolUse / PostToolUse", () => {
    const pre = buildInput("PreToolUse", ctx);
    expect(pre.tool_name).toBe("Bash");
    expect(pre.tool_input).toEqual({ command: "ls" });
    expect(pre.tool_use_id).toBe("t1");
    expect("tool_response" in pre).toBe(false);
    expect(buildInput("PostToolUse", ctx).tool_response).toEqual({ out: "x" });
  });
  test("UserPromptSubmit, SessionStart, Stop, PreCompact, SessionEnd", () => {
    expect(buildInput("UserPromptSubmit", ctx).prompt).toBe("hi");
    expect(buildInput("SessionStart", ctx).source).toBe("startup");
    expect(buildInput("SessionStart", { ...ctx, source: "resume" }).source).toBe("resume");
    expect(buildInput("Stop", ctx).stop_hook_active).toBe(false);
    const pc = buildInput("PreCompact", ctx);
    expect(pc.trigger).toBe("auto");
    expect(pc.custom_instructions).toBe("");
    expect(buildInput("SessionEnd", ctx).reason).toBe("other");
  });
  test("defaults when ctx is sparse", () => {
    const o = buildInput("PreToolUse", {});
    expect(o.permission_mode).toBe("default");
    expect(o.tool_input).toEqual({});
  });
});

describe("interpret", () => {
  test("permissionDecision deny blocks with the reason", () => {
    const r = interpret("PreToolUse", ok(hso({ permissionDecision: "deny", permissionDecisionReason: "no rm" })));
    expect(r.block).toBe("no rm");
    expect(r.failed).toBe(false);
  });
  test("deny without a reason still blocks", () => {
    expect(interpret("PreToolUse", ok(hso({ permissionDecision: "deny" }))).block).toBe("blocked by hook");
  });
  test("exit 2 blocks PreToolUse and UserPromptSubmit with stderr", () => {
    expect(interpret("PreToolUse", { status: 2, stdout: "", stderr: " nope \n" }).block).toBe("nope");
    expect(interpret("UserPromptSubmit", { status: 2, stdout: "", stderr: "" }).block).toBe("blocked by hook");
  });
  test("exit 2 on PostToolUse is context, on others nothing", () => {
    const r = interpret("PostToolUse", { status: 2, stdout: "", stderr: "fix lint" });
    expect(r.context).toBe("fix lint");
    expect(r.block).toBeUndefined();
    const s = interpret("SessionStart", { status: 2, stdout: "", stderr: "x" });
    expect(s.block).toBeUndefined();
    expect(s.context).toBeUndefined();
    expect(s.failed).toBe(false);
  });
  test("ask blocks with the ask-in-chat text", () => {
    const r = interpret("PreToolUse", ok(hso({ permissionDecision: "ask", permissionDecisionReason: "touches prod" })));
    expect(r.block).toContain("Ask the user in chat");
    expect(r.block).toBe(askMessage("touches prod"));
    expect(r.block).toContain("touches prod");
  });
  test("allow and defer do not block", () => {
    expect(interpret("PreToolUse", ok(hso({ permissionDecision: "allow" }))).block).toBeUndefined();
    expect(interpret("PreToolUse", ok(hso({ permissionDecision: "defer" }))).block).toBeUndefined();
  });
  test("deprecated decision:block on PreToolUse blocks", () => {
    expect(interpret("PreToolUse", ok(JSON.stringify({ decision: "block", reason: "old style" }))).block).toBe("old style");
  });
  test("decision:block on Stop and PostToolUse is not honoured", () => {
    const s = JSON.stringify({ decision: "block", reason: "x" });
    expect(interpret("Stop", ok(s)).block).toBeUndefined();
    expect(interpret("PostToolUse", ok(s)).block).toBeUndefined();
  });
  test("R24: Stop decision:block is reported as notHonoured, never blocks", () => {
    const r = interpret("Stop", ok(JSON.stringify({ decision: "block", reason: "x" })));
    expect(r.notHonoured).toBe("Stop decision:block");
    expect(r.block).toBeUndefined();
    expect(interpret("Stop", ok("")).notHonoured).toBeUndefined();
  });
  test("R24: PostToolUse decision:block hands the reason to Claude as context", () => {
    const r = interpret("PostToolUse", ok(JSON.stringify({ decision: "block", reason: "lint failed" })));
    expect(r.context).toBe("lint failed");
    expect(r.block).toBeUndefined();
    expect(r.notHonoured).toBeUndefined();
    const both = interpret("PostToolUse", ok(JSON.stringify({ decision: "block", reason: "r", hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: "c" } })));
    expect(both.context).toBe("c\nr");
  });
  test("M6: malformed JSON carries malformed:true (still not failed)", () => {
    const r = interpret("PreToolUse", ok("{ nope"));
    expect(r.malformed).toBe(true);
    expect(r.failed).toBe(false);
    expect(interpret("PreToolUse", ok('{"a":1}')).malformed).toBeUndefined();
  });
  test("M1: only {...} is parsed; an array or a bare brace-less string is plain text", () => {
    expect(interpret("SessionStart", ok("[1,2]")).context).toBe("[1,2]");
    expect(interpret("SessionStart", ok("[not json")).context).toBe("[not json");
  });
  test("additionalContext, systemMessage, updatedInput", () => {
    const r = interpret("PreToolUse", ok(JSON.stringify({ systemMessage: "sm", hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: "ctx", updatedInput: { command: "ls -l" } } })));
    expect(r.context).toBe("ctx");
    expect(r.systemMessage).toBe("sm");
    expect(r.updatedInput).toEqual({ command: "ls -l" });
    expect(r.unknownFields).toEqual([]);
  });
  test("SessionStart and UserPromptSubmit text stdout is context; other events ignore text", () => {
    expect(interpret("SessionStart", ok("hello there\n")).context).toBe("hello there");
    expect(interpret("UserPromptSubmit", ok("extra")).context).toBe("extra");
    expect(interpret("PreToolUse", ok("chatter")).context).toBeUndefined();
    expect(interpret("Stop", ok("chatter")).context).toBeUndefined();
  });
  test("RF3: malformed JSON is non-blocking, not failed, never throws, never becomes context", () => {
    for (const ev of ["PreToolUse", "SessionStart", "UserPromptSubmit"]) {
      const r = interpret(ev, ok('{"hookSpecificOutput": {"permissionDecision": "deny"'));
      expect(r.block).toBeUndefined();
      expect(r.context).toBeUndefined();
      expect(r.failed).toBe(false);
    }
  });
  test("non-object JSON (array, JSON string) is ignored", () => {
    expect(interpret("PreToolUse", ok("[1,2]")).block).toBeUndefined();
    expect(interpret("SessionStart", ok('"str"')).context).toBe('"str"');
  });
  test("CRLF JSON parses", () => {
    const body = '{\r\n  "hookSpecificOutput": {\r\n    "hookEventName": "PreToolUse",\r\n    "permissionDecision": "deny",\r\n    "permissionDecisionReason": "crlf"\r\n  }\r\n}\r\n';
    expect(interpret("PreToolUse", ok(body)).block).toBe("crlf");
  });
  test("a leading BOM is stripped before parsing", () => {
    expect(interpret("PreToolUse", ok("﻿" + hso({ permissionDecision: "deny", permissionDecisionReason: "bom" }))).block).toBe("bom");
  });
  test("CRLF in text context is normalised to LF", () => {
    expect(interpret("SessionStart", ok("a\r\nb\r\n")).context).toBe("a\nb");
    expect(interpret("PostToolUse", { status: 2, stdout: "", stderr: "x\r\ny" }).context).toBe("x\ny");
  });
  test("unknown fields surface (top-level and hookSpecificOutput)", () => {
    const r = interpret("PreToolUse", ok(JSON.stringify({ mystery: 1, hookSpecificOutput: { hookEventName: "PreToolUse", updatedToolOutput: "z" } })));
    expect(r.unknownFields).toEqual(["mystery", "hookSpecificOutput.updatedToolOutput"]);
  });
  test("every recognised key is NOT reported unknown", () => {
    const j = { continue: true, stopReason: "s", suppressOutput: false, systemMessage: "m", terminalSequence: "", decision: "x", reason: "r", hookSpecificOutput: { hookEventName: "E", permissionDecision: "allow", permissionDecisionReason: "r", updatedInput: {}, additionalContext: "c" } };
    expect(interpret("PostToolUse", ok(JSON.stringify(j))).unknownFields).toEqual([]);
  });
  test("exit 1 / other codes fail, non-blocking", () => {
    for (const status of [1, 3, 127]) {
      const r = interpret("PreToolUse", { status, stdout: "", stderr: "boom" });
      expect(r.failed).toBe(true);
      expect(r.block).toBeUndefined();
    }
  });
  test("a timeout or a spawnError is a failure, never a block", () => {
    const t = interpret("PreToolUse", { status: null, stdout: "", stderr: "", timedOut: true });
    expect(t.failed).toBe(true);
    expect(t.block).toBeUndefined();
    const s = interpret("PreToolUse", { status: null, stdout: "", stderr: "", spawnError: "ENOENT" });
    expect(s.failed).toBe(true);
  });
  test("a timeout is a failure even when the killed process reported status 0", () => {
    const r = interpret("PreToolUse", { status: 0, stdout: "", stderr: "", timedOut: true });
    expect(r.failed).toBe(true);
  });
  test("exit 0 with empty stdout is a clean pass", () => {
    const r = interpret("PreToolUse", ok(""));
    expect(r).toEqual({ unknownFields: [], failed: false });
  });
  test("UserPromptSubmit decision:block blocks", () => {
    expect(interpret("UserPromptSubmit", ok(JSON.stringify({ decision: "block", reason: "no" }))).block).toBe("no");
  });
});
