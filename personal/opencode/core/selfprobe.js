// OC arg-name self-probe. The tool map (toolmap.js) reads OC tool args by name; if OC renames one,
// hooks silently see an empty field. So the arg names OC was OBSERVED sending (state.observed.args,
// recorded by tool.execute.before) are compared with the names the map expects.
//
// Timing (review rev2 #3): tool.definition and tool.execute.before fire during a session, after the
// first chat.message, so observations are persisted and compared at the NEXT session's first
// message. Drift in OC's own surface is therefore reported one session late.
//
// Expected names: the full measured OC v1.19.0 schemas (docs/v1-capabilities.md E8), not only the
// args the map reads, so an optional arg the map ignores is never a false mismatch. Pass-through
// tools (websearch, question, lsp, plan_exit), MCP tools and OC_INTERNAL ids are not probed: no
// schema was measured for them.
export const EXPECTED_ARGS = {
  read: ["filePath", "offset", "limit"],
  edit: ["filePath", "oldString", "newString", "replaceAll"],
  write: ["content", "filePath"],
  grep: ["pattern", "path", "include"],
  glob: ["pattern", "path"],
  bash: ["command", "timeout", "workdir"],
  task: ["description", "prompt", "subagent_type", "task_id", "command", "background"],
  webfetch: ["url", "format", "timeout"],
  skill: ["name"],
  todowrite: ["todos"],
  apply_patch: ["patchText"],
};

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// selfProbe(observedArgs: Record<tool, string[]>, expected?) -> string[] (one problem per
// unexpected arg name, in observation order). An observed name outside the expected set means OC
// sent an arg the map does not know: a rename or a new arg. Never throws.
export function selfProbe(observedArgs, expected = EXPECTED_ARGS) {
  const out = [];
  if (!isObj(observedArgs) || !isObj(expected)) return out;
  for (const [tool, names] of Object.entries(observedArgs)) {
    if (!Object.hasOwn(expected, tool) || !Array.isArray(names)) continue;
    for (const n of names) {
      if (typeof n === "string" && !expected[tool].includes(n)) {
        out.push(`self-probe: OC tool ${tool} sent arg "${n}", which the tool map does not expect`);
      }
    }
  }
  return out;
}
