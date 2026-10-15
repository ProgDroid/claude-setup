import path from "node:path";
import { parseApplyPatch, parseApplyPatchFull } from "./patch.js";

export { parseApplyPatch };

// OC tool id -> CC tool name (v1-capabilities.md rows 8 and 11). `apply_patch` fans out per
// file, so its value is the marker "apply_patch". HANDLED.ocTools in enumerate.js is these keys
// plus OC_INTERNAL.
export const OC_TO_CC = {
  bash: "Bash",
  edit: "Edit",
  write: "Write",
  read: "Read",
  grep: "Grep",
  glob: "Glob",
  webfetch: "WebFetch",
  task: "Task",
  todowrite: "TodoWrite",
  skill: "Skill",
  apply_patch: "apply_patch",
  // Pass-through rows (args unchanged): no measured arg map, but a CC matcher can still hit them.
  websearch: "WebSearch",
  question: "AskUserQuestion",
  lsp: "LSP",
  plan_exit: "ExitPlanMode",
};

// OC-internal tool ids with no CC counterpart (R30): handled, silent, never hooked
// (toCcCalls returns null). `invalid` is OC's placeholder for a malformed tool call.
// `execute` (Code Mode) is here too (R39): its child MCP calls fire tool.execute.before/after with
// the MCP tool id (OC v1.19.0 packages/opencode/src/tool/code-mode.ts:141-145 before, :180-184 after),
// so mcp__ hooks are bridged through those events and `execute` itself needs no report.
export const OC_INTERNAL = ["invalid", "execute"];

export const PATCH_BLOCK_REASON = "patch could not be represented for CC hooks; split it or use edit/write";

const sanitize = (s) => String(s).replace(/[^A-Za-z0-9_-]/g, "_");
// The CC/OC MCP-name sanitiser (R33), shared with permissions.js and mcp.js.
export const sanitizeMcpName = sanitize;
const abs = (p, cwd) => (typeof p === "string" && p ? path.resolve(cwd || process.cwd(), p) : p);
const pick = (o, keys) => Object.fromEntries(keys.filter((k) => o[k] !== undefined).map((k) => [k, o[k]]));
const rename = (o, map) => {
  const r = {};
  for (const [from, to] of Object.entries(map)) if (o[from] !== undefined) r[to] = o[from];
  return r;
};
// `rm -- <path>`, single-quoted unless the path is plainly shell-safe.
const rmCommand = (p) => `rm -- ${/^[A-Za-z0-9_./:@%+=,-]+$/.test(p) ? p : `'${p.replace(/'/g, `'\\''`)}'`}`;

// Resolve `<server>_<tool>` against the KNOWN servers only (R7), longest sanitized prefix wins,
// so `my_srv_do_it` with servers [my, my_srv] is my_srv/do_it, never my/srv_do_it. The emitted
// CC name uses the SANITIZED server (`[^A-Za-z0-9_-]` -> `_`), as CC itself does:
// `plugin:qmd:qmd` -> `mcp__plugin_qmd_qmd__<tool>`.
function mcpName(ocTool, mcpServers) {
  let best = null;
  for (const server of Array.isArray(mcpServers) ? mcpServers : []) {
    const clean = sanitize(server);
    const prefix = `${clean}_`;
    if (prefix.length <= 1 || !ocTool.startsWith(prefix) || ocTool.length === prefix.length) continue;
    if (!best || prefix.length > best.prefix.length) best = { clean, prefix };
  }
  return best ? `mcp__${best.clean}__${ocTool.slice(best.prefix.length)}` : null;
}

// toCcCalls(ocTool, ocArgs, cwd, mcpServers) -> Array<{ tool_name, tool_input, cwd? }>
//                                              | { block: string } | null
//   null            unmapped tool (including OC_INTERNAL and `execute`).
//   { block }       (apply_patch only, R32, fail closed) a non-empty patchText that does not
//                   parse into any operation, or that holds an unrecognised `***` line. NOT an
//                   array. Task 10 must check `Array.isArray(r)` and, on `r.block`, throw from
//                   tool.execute.before with that text, log it and count it as a parity item.
//   `cwd` on an entry is present only for bash with a `workdir` (R6): the caller uses it as the
//   hook input's cwd instead of the session cwd. All file_path values are absolute against `cwd`.
//   tool_input is always a fresh object, never the OC args object.
//   apply_patch fans out, in patch order:
//     add            -> Write {file_path, content}
//     update         -> one Edit per hunk {file_path, old_string, new_string}
//     update + move  -> those Edits on the source, then Write {abs(moveTo), content: new text of
//                       all hunks}, then Bash `rm -- <abs source>` (the source is removed)
//     delete         -> Bash `rm -- <abs path>` (how CC itself deletes, so Bash guards see it)
export function toCcCalls(ocTool, ocArgs, cwd, mcpServers = []) {
  const a = ocArgs && typeof ocArgs === "object" ? ocArgs : {};
  if (typeof ocTool !== "string") return null;
  if (!Object.hasOwn(OC_TO_CC, ocTool)) {
    const name = mcpName(ocTool, mcpServers);
    return name ? [{ tool_name: name, tool_input: { ...a } }] : null;
  }
  switch (ocTool) {
    case "bash": {
      const call = { tool_name: "Bash", tool_input: pick(a, ["command", "timeout"]) };
      if (typeof a.workdir === "string" && a.workdir) call.cwd = abs(a.workdir, cwd);
      return [call];
    }
    case "edit":
      return [{ tool_name: "Edit", tool_input: { file_path: abs(a.filePath, cwd), ...rename(a, { oldString: "old_string", newString: "new_string", replaceAll: "replace_all" }) } }];
    case "write":
      return [{ tool_name: "Write", tool_input: { file_path: abs(a.filePath, cwd), ...pick(a, ["content"]) } }];
    case "read":
      return [{ tool_name: "Read", tool_input: { file_path: abs(a.filePath, cwd), ...pick(a, ["offset", "limit"]) } }];
    case "grep":
      return [{ tool_name: "Grep", tool_input: { ...pick(a, ["pattern", "path"]), ...rename(a, { include: "glob" }) } }];
    case "glob":
      return [{ tool_name: "Glob", tool_input: pick(a, ["pattern", "path"]) }];
    case "webfetch":
      return [{ tool_name: "WebFetch", tool_input: { url: a.url, prompt: "" } }];
    case "task":
      return [{ tool_name: "Task", tool_input: pick(a, ["description", "prompt", "subagent_type"]) }];
    case "apply_patch": {
      const { ops, unknown } = parseApplyPatchFull(a.patchText);
      const nonEmpty = typeof a.patchText === "string" && a.patchText.trim() !== "";
      if (unknown || (nonEmpty && ops.length === 0)) return { block: PATCH_BLOCK_REASON };
      const calls = [];
      for (const f of ops) {
        const file = abs(f.path, cwd);
        if (f.op === "add") calls.push({ tool_name: "Write", tool_input: { file_path: file, content: f.content } });
        else if (f.op === "delete") calls.push({ tool_name: "Bash", tool_input: { command: rmCommand(file) } });
        else {
          // A hunkless update still rewrites the file in OC: name the path with an empty Edit.
          if (f.hunks.length === 0) calls.push({ tool_name: "Edit", tool_input: { file_path: file, old_string: "", new_string: "" } });
          for (const h of f.hunks) calls.push({ tool_name: "Edit", tool_input: { file_path: file, old_string: h.oldText, new_string: h.newText } });
          if (f.moveTo) {
            calls.push({ tool_name: "Write", tool_input: { file_path: abs(f.moveTo, cwd), content: f.hunks.map((h) => h.newText).join("\n") } });
            calls.push({ tool_name: "Bash", tool_input: { command: rmCommand(file) } });
          }
        }
      }
      // Fail closed on what was EMITTED, not what was parsed: a non-empty patch that yields no
      // call at all would reach no hook.
      if (nonEmpty && calls.length === 0) return { block: PATCH_BLOCK_REASON };
      return calls;
    }
    default:
      return [{ tool_name: OC_TO_CC[ocTool], tool_input: { ...a } }];
  }
}

// OC grep / glob text -> CC response shapes (measured from CC transcripts; the shapes
// negative-result-guard.sh requires: filenames / content / numFiles).
//   OC glob: one absolute path per line, "No files found" when empty, optional trailing
//            "(Results are truncated: ...)" after a blank line (tool/glob.ts).
//   OC grep: "No files found" when empty, else "Found N matches", then per file a "<path>:" line
//            and indented "  Line N: text" rows (tool/grep.ts).
const NO_FILES = "No files found";
function globResponse(text) {
  const t = String(text ?? "").trim();
  const truncated = /\n\(Results are truncated/.test(t);
  const filenames = t === "" || t === NO_FILES ? [] : t.split("\n").filter((l) => l && !l.startsWith("(Results are truncated"));
  return { filenames, numFiles: filenames.length, truncated };
}
function grepResponse(text) {
  const t = String(text ?? "").trim();
  if (t === "" || t === NO_FILES) return { mode: "content", numFiles: 0, filenames: [], content: "", numLines: 0 };
  const filenames = [];
  for (const l of t.split("\n")) {
    const m = /^(?!\s)(?!Found \d)(.+):$/.exec(l);
    if (m) filenames.push(m[1]);
  }
  return { mode: "content", numFiles: filenames.length, filenames, content: t, numLines: t.split("\n").length };
}

// PostToolUse tool_response in CC's shapes (R33), as negative-result-guard.sh reads them.
//   Bash: OC's "(no output)" placeholder (shell.ts) -> stdout "", and a trailing
//         <shell_metadata>..</shell_metadata> block is stripped (interrupted when it says the
//         user aborted or the timeout fired).
//   Grep / Glob: parsed from OC's text. mcp__*: the raw MCP result's content array (OC's MCP
//   `output` is {content, structuredContent, isError}; a string is wrapped as one text block).
export function toCcResponse(ccTool, ocOutput, ccInput) {
  if (ccTool === "Bash") {
    let out = typeof ocOutput === "string" ? ocOutput : String(ocOutput ?? "");
    let interrupted = false;
    // Only the LAST block, and only when every line of it is one of OC's two messages
    // (shell.ts), so program output that merely contains such a tag is left alone.
    const open = "\n\n<shell_metadata>\n";
    const close = "\n</shell_metadata>";
    const at = out.lastIndexOf(open);
    if (at !== -1 && out.endsWith(close)) {
      const body = out.slice(at + open.length, out.length - close.length);
      if (body.split("\n").every((l) => l === "User aborted the command" || l.startsWith("shell tool terminated command after exceeding timeout "))) {
        interrupted = true;
        out = out.slice(0, at);
      }
    }
    if (out === "(no output)") out = "";
    return { stdout: out, stderr: "", interrupted, isImage: false };
  }
  if (ccTool === "Write") return { filePath: ccInput?.file_path, type: "create" };
  if (ccTool === "Glob") return globResponse(ocOutput);
  if (ccTool === "Grep") return grepResponse(ocOutput);
  if (typeof ccTool === "string" && ccTool.startsWith("mcp__")) {
    if (ocOutput && typeof ocOutput === "object") return Array.isArray(ocOutput.content) ? ocOutput.content : ocOutput;
    return [{ type: "text", text: String(ocOutput ?? "") }];
  }
  return { output: ocOutput };
}

// CC field -> OC arg, for the tools whose PreToolUse `updatedInput` can be applied.
export const UPDATE_ARG_MAPS = {
  bash: { command: "command", timeout: "timeout" },
  edit: { file_path: "filePath", old_string: "oldString", new_string: "newString", replace_all: "replaceAll" },
  write: { file_path: "filePath", content: "content" },
};

// OC args a hook may drop (R51 m-6): optional in OC's own schema (tool/shell/prompt.ts timeout,
// tool/edit.ts replaceAll), so their absence is representable. Every other mapped arg is required.
export const OPTIONAL_OC_ARGS = { bash: ["timeout"], edit: ["replaceAll"], write: [] };

// R51 m-6: CC REPLACES the input with updatedInput (bundle Xwe: `e.updatedInput??n`), so a key of
// the CC input the hook left out is dropped. -> the dropped keys OC cannot drop: an unmapped key,
// or a mapped one whose OC arg is required. A non-object updatedInput drops every key.
export function undroppableKeys(ocTool, ccInput, ccUpdatedInput) {
  const u = ccUpdatedInput && typeof ccUpdatedInput === "object" ? ccUpdatedInput : {};
  const given = ccInput && typeof ccInput === "object" ? ccInput : {};
  const map = UPDATE_ARG_MAPS[ocTool] ?? {};
  const optional = OPTIONAL_OC_ARGS[ocTool] ?? [];
  return Object.keys(given).filter((k) => !Object.hasOwn(u, k) && !(Object.hasOwn(map, k) && optional.includes(map[k])));
}

// R48: the keys of a hook's updatedInput that cannot be applied to OC tool `ocTool`: a key with no
// OC arg whose value differs from the CC input the hook was given (an unchanged echo is no
// rewrite). A tool with no map at all -> every key that differs. The plugin BLOCKS on any.
export function unmappedUpdateKeys(ocTool, ccInput, ccUpdatedInput) {
  const u = ccUpdatedInput && typeof ccUpdatedInput === "object" ? ccUpdatedInput : {};
  const given = ccInput && typeof ccInput === "object" ? ccInput : {};
  const map = UPDATE_ARG_MAPS[ocTool] ?? {};
  return Object.keys(u).filter((k) => !Object.hasOwn(map, k) && JSON.stringify(u[k]) !== JSON.stringify(given[k]));
}

// Reverse map for PreToolUse `updatedInput`: returns NEW OC args with the hook's changes folded
// in (only keys the hook supplied). Given the CC input the hook saw (`ccInput`), an optional OC arg
// whose CC key the hook left out is removed too (R51 m-6: CC replaces, it does not merge). bash, edit and write only; anything else is returned
// unchanged. The plugin checks unmappedUpdateKeys first and blocks rather than half-apply (R48).
export function applyUpdatedInput(ocTool, ocArgs, ccUpdatedInput, ccInput) {
  const args = ocArgs && typeof ocArgs === "object" ? ocArgs : {};
  const u = ccUpdatedInput && typeof ccUpdatedInput === "object" ? ccUpdatedInput : {};
  const map = UPDATE_ARG_MAPS[ocTool];
  if (!map) {
    return args;
  }
  const out = { ...args };
  for (const [cc, oc] of Object.entries(map)) if (u[cc] !== undefined) out[oc] = u[cc];
  if (ccInput && typeof ccInput === "object") {
    for (const [cc, oc] of Object.entries(map)) {
      if (Object.hasOwn(ccInput, cc) && !Object.hasOwn(u, cc) && (OPTIONAL_OC_ARGS[ocTool] ?? []).includes(oc)) delete out[oc];
    }
  }
  return out;
}
