import { describe, expect, test } from "bun:test";
import { interpret, EVENTS } from "../core/protocol.js";

// Final review I5: CC's `continue:false` stops Claude after the hooks run and takes precedence over
// decision fields (hooks reference). OC cannot stop a turn from a hook, so on the two events that
// have a block path it blocks; everywhere else it is recorded as notHonoured (R24's pattern).

const ok = (o) => ({ status: 0, stdout: JSON.stringify(o), stderr: "", timedOut: false });

describe("interpret: continue:false (I5)", () => {
  test("PreToolUse: blocks with stopReason, and the turn-stop it cannot honour is recorded", () => {
    const r = interpret("PreToolUse", ok({ continue: false, stopReason: "guard says stop" }));
    expect(r.block).toBe("guard says stop");
    expect(r.notHonoured).toBe("PreToolUse continue:false (the tool is blocked; the turn is not stopped)");
    expect(r.failed).toBe(false);
  });
  test("PreToolUse: without a stopReason the block says 'stopped by hook'", () => {
    expect(interpret("PreToolUse", ok({ continue: false })).block).toBe("stopped by hook");
    expect(interpret("PreToolUse", ok({ continue: false, stopReason: "" })).block).toBe("stopped by hook");
  });
  test("continue:false takes precedence over decision fields (an allow, an ask, an updatedInput)", () => {
    const r = interpret("PreToolUse", ok({ continue: false, stopReason: "halt", hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "x" } } }));
    expect(r.block).toBe("halt");
    const a = interpret("PreToolUse", ok({ continue: false, stopReason: "halt", hookSpecificOutput: { permissionDecision: "ask", permissionDecisionReason: "why" } }));
    expect(a.block).toBe("halt");
  });
  test("UserPromptSubmit: blocks through the existing block path", () => {
    const r = interpret("UserPromptSubmit", ok({ continue: false, stopReason: "no" }));
    expect(r.block).toBe("no");
    expect(interpret("UserPromptSubmit", ok({ continue: false })).block).toBe("stopped by hook");
  });
  test("every other event: notHonoured '<event> continue:false', never a block", () => {
    for (const ev of EVENTS.filter((e) => e !== "PreToolUse" && e !== "UserPromptSubmit")) {
      const r = interpret(ev, ok({ continue: false, stopReason: "x" }));
      expect([ev, r.block, r.notHonoured]).toEqual([ev, undefined, `${ev} continue:false`]);
    }
  });
  test("Stop with both decision:block and continue:false records both", () => {
    expect(interpret("Stop", ok({ continue: false, decision: "block", reason: "r" })).notHonoured).toBe("Stop decision:block; Stop continue:false");
  });
  test("continue:true or absent changes nothing (control)", () => {
    for (const o of [{ continue: true }, {}, { stopReason: "only a reason" }]) {
      const r = interpret("PreToolUse", ok(o));
      expect(r.block).toBeUndefined();
      expect(r.notHonoured).toBeUndefined();
    }
  });
});
