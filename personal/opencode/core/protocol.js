// CC hook protocol: the stdin JSON per event, and the reading of a hook's exit/stdout/stderr.
// Rules verified against code.claude.com/docs/en/hooks.md (see docs/v1-capabilities.md).

export function buildInput(event, ctx = {}) {
  const o = {
    session_id: ctx.sessionId ?? "",
    transcript_path: null,
    cwd: ctx.cwd ?? process.cwd(),
    hook_event_name: event,
    permission_mode: ctx.permissionMode ?? "default",
  };
  switch (event) {
    case "PostToolUse":
      o.tool_name = ctx.toolName;
      o.tool_input = ctx.toolInput ?? {};
      o.tool_use_id = ctx.toolUseId;
      o.tool_response = ctx.toolResponse ?? {};
      break;
    case "PreToolUse":
      o.tool_name = ctx.toolName;
      o.tool_input = ctx.toolInput ?? {};
      o.tool_use_id = ctx.toolUseId;
      break;
    case "UserPromptSubmit":
      o.prompt = ctx.prompt ?? "";
      break;
    case "SessionStart":
      o.source = ctx.source ?? "startup";
      break;
    case "Stop":
      o.stop_hook_active = false;
      break;
    case "PreCompact":
      o.trigger = ctx.trigger ?? "auto";
      o.custom_instructions = "";
      break;
    case "SessionEnd":
      o.reason = ctx.reason ?? "other";
      break;
  }
  return o;
}

// The CC hook events the adapter bridges (enumerate.js HANDLED.hookEvents holds the same seven).
export const EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "PreCompact"];

// Every stdin field name buildInput sends, derived from buildInput itself so it cannot drift.
// releasenotes.js counts these as known identifiers (Task 9 review fold-in).
export const INPUT_FIELDS = [
  ...new Set(EVENTS.flatMap((e) => Object.keys(buildInput(e, { toolName: "", toolUseId: "", toolResponse: {}, prompt: "" })))),
];

const TOP_KEYS = new Set(["continue", "stopReason", "suppressOutput", "systemMessage", "terminalSequence", "decision", "reason", "hookSpecificOutput"]);
const HSO_KEYS = new Set(["hookEventName", "permissionDecision", "permissionDecisionReason", "updatedInput", "additionalContext"]);
// Output keys interpret() recognises (top level and hookSpecificOutput).
export const OUTPUT_FIELDS = [...TOP_KEYS, ...HSO_KEYS];

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// BOM and CRLF both come from Windows shells; normalise before parsing or passing on as text.
const normalise = (s) => String(s ?? "").replace(/^﻿/, "").replace(/\r\n/g, "\n");

export function askMessage(reason) {
  return `A hook requires the user's confirmation: ${reason}. Ask the user in chat; do not rephrase or retry the command to get around this.`;
}

// r: { status, stdout, stderr, timedOut, spawnError }
export function interpret(event, r = {}) {
  const out = { unknownFields: [], failed: false };
  if (r.spawnError || r.timedOut) {
    out.failed = true;
    return out;
  }
  const stderr = normalise(r.stderr);
  const stdout = normalise(r.stdout).trim();

  if (r.status === 2) {
    if (event === "PreToolUse" || event === "UserPromptSubmit") out.block = stderr.trim() || "blocked by hook";
    else if (event === "PostToolUse") out.context = stderr;
    return out;
  }
  if (r.status !== 0) {
    out.failed = true;
    return out;
  }
  if (!stdout) return out;

  if (stdout.startsWith("{")) {
    let j;
    try {
      j = JSON.parse(stdout);
    } catch {
      out.malformed = true; // non-blocking, never thrown, never injected as context; flagged so callers can log
      return out;
    }
    if (!isObj(j)) return out;
    for (const k of Object.keys(j)) if (!TOP_KEYS.has(k)) out.unknownFields.push(k);
    const h = isObj(j.hookSpecificOutput) ? j.hookSpecificOutput : {};
    for (const k of Object.keys(h)) if (!HSO_KEYS.has(k)) out.unknownFields.push(`hookSpecificOutput.${k}`);
    if (typeof j.systemMessage === "string") out.systemMessage = j.systemMessage;
    if (typeof h.additionalContext === "string") out.context = h.additionalContext;
    if (event === "PreToolUse") {
      const why = h.permissionDecisionReason || j.reason || "";
      if (h.permissionDecision === "deny") out.block = why || "blocked by hook";
      else if (h.permissionDecision === "ask") out.block = askMessage(why || "no reason given");
      else if (j.decision === "block") out.block = j.reason || "blocked by hook";
      if (isObj(h.updatedInput)) out.updatedInput = h.updatedInput;
    } else if (event === "UserPromptSubmit" && j.decision === "block") {
      out.block = j.reason || "blocked by hook";
    }
    // R24: Stop decision:block has no OC equivalent -> reported, not honoured. On PostToolUse CC shows
    // the reason to Claude beside the tool result, which is exactly what `context` is.
    if (j.decision === "block") {
      if (event === "Stop") out.notHonoured = "Stop decision:block";
      else if (event === "PostToolUse") out.context = [out.context, j.reason || "blocked by hook"].filter(Boolean).join("\n");
    }
    // I5: `continue:false` stops Claude after the hooks run and takes precedence over decision fields
    // (hooks reference). OC cannot stop a turn from a hook: PreToolUse and UserPromptSubmit block
    // through their block paths (fail closed); every other event records it as not honoured (R24).
    if (j.continue === false) {
      const why = typeof j.stopReason === "string" && j.stopReason ? j.stopReason : "stopped by hook";
      const nh = [];
      if (event === "PreToolUse" || event === "UserPromptSubmit") {
        out.block = why;
        if (event === "PreToolUse") nh.push("PreToolUse continue:false (the tool is blocked; the turn is not stopped)");
      } else nh.push(`${event} continue:false`);
      out.notHonoured = [out.notHonoured, ...nh].filter(Boolean).join("; ") || undefined;
      if (out.notHonoured === undefined) delete out.notHonoured;
    }
    return out;
  }

  if (event === "SessionStart" || event === "UserPromptSubmit") out.context = stdout;
  return out;
}
