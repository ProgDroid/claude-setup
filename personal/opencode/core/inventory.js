import fs from "node:fs";
import os from "node:os";
import { ccPaths } from "./paths.js";
import { loadSettings } from "./settings.js";
import { enabledPlugins } from "./plugins.js";
import { enumerate } from "./enumerate.js";
import { collectHooks } from "./hooks.js";
import { dispositionFor, loadRules } from "./dispositions.js";
import { toOcPermission } from "./permissions.js";
import { collectMcp, toOcMcp } from "./mcp.js";
import { collectAgents } from "./agents.js";
import { skillPaths as collectSkillPaths, promptingSkills } from "./skills.js";
import { ruleFiles } from "./rules.js";
import { selfProbe } from "./selfprobe.js";

// Problem strings are seen-keys too, so their text must stay stable across starts.
export const PROBLEMS = {
  codeMode: "Code Mode is off (OPENCODE_EXPERIMENTAL_CODE_MODE, else OPENCODE_EXPERIMENTAL): MCP tools are sent to the model one by one",
  // Row 12 held: the flag stops OC's own ~/.claude/skills and .claude/skills scan (CLAUDE.md is unaffected).
  ccSkills: "OC's own Claude Code skill scan is on (neither OPENCODE_DISABLE_CLAUDE_CODE_SKILLS nor OPENCODE_DISABLE_CLAUDE_CODE is set): it runs beside the adapter's skills.paths",
  // R35, verbatim: pre-existing OC behaviour found in the Task 7 re-review.
  grepGlob: "OC grep/glob ignore read denies; CC Read denies do not protect file contents from OC search tools",
};
// Short names for the compact parity line (R42); the full text goes to cc-parity.log.
export const PROBLEM_LABELS = {
  [PROBLEMS.codeMode]: "Code Mode off",
  [PROBLEMS.ccSkills]: "OC's own CC-skill scan on",
  [PROBLEMS.grepGlob]: "grep/glob ignore read denies",
};

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// OC's boolean env flags (effect Config.boolean). Spellings beyond "1"/"0" are assumed, not verified
// against the installed effect version; an unset or empty variable counts as not set.
const flag = (env, name) => {
  const v = env?.[name];
  if (v === undefined || v === "") return undefined;
  if (/^(true|1|yes|on|y)$/i.test(v)) return true;
  if (/^(false|0|no|off|n)$/i.test(v)) return false;
  return undefined;
};
// OC v1.19.0 effect/runtime-flags.ts:10-14,48: the explicit flag when set, else OPENCODE_EXPERIMENTAL.
export const codeModeOn = (env) => flag(env, "OPENCODE_EXPERIMENTAL_CODE_MODE") ?? flag(env, "OPENCODE_EXPERIMENTAL") === true;
// runtime-flags.ts:27-30: OPENCODE_DISABLE_CLAUDE_CODE || OPENCODE_DISABLE_CLAUDE_CODE_SKILLS.
export const ccSkillsOff = (env) => flag(env, "OPENCODE_DISABLE_CLAUDE_CODE") === true || flag(env, "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS") === true;

function readJson(file, unknown) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e?.code !== "ENOENT") unknown.push({ where: file, key: ".claude.json", note: `unreadable: ${e?.code}` });
    return undefined;
  }
  try {
    return JSON.parse(text.replace(/^﻿/, ""));
  } catch {
    unknown.push({ where: file, key: ".claude.json", note: "unparseable JSON, skipped" });
    return undefined;
  }
}

// Permission + agents depend on the OC baseline (cfg.permission), known only inside the config
// hook, so they are a separate step that the config hook re-runs with the real baseline (R36: agents
// take the toOcPermission output, baseline included).
// mcpServers (optional): every configured server name, OC's own included (R45 asks per server);
// defaults to the CC servers. R49: the CC skills CC would prompt for (non-safe frontmatter) ask.
export function permissionAndAgents({ merged, plugins, mcp, home, projectDir, worktree, baseline, mcpServers }) {
  const skillAsks = promptingSkills(collectSkillPaths({ home, projectDir, plugins })).map((s) => s.name);
  const perm = toOcPermission(merged?.permissions, baseline, { home, worktree, mcpServers: Array.isArray(mcpServers) ? mcpServers : Object.keys(mcp ?? {}), skillAsks });
  const ag = collectAgents({ home, projectDir, plugins, userPermission: perm.permission });
  return { permission: perm.permission, agent: ag.agent, command: ag.command, commandSource: ag.commandSource, unknown: [...perm.unknown, ...ag.unknown] };
}

// buildInventory({ home, projectDir, ocTools, observedArgs, env, worktree, baseline }) -> Inventory
//   ocTools / observedArgs: the PREVIOUS session's observations (state.observed), see selfprobe.js.
//   Inventory = { merged, plugins, hooks, degraded, permission, mcp, agent, command, commandSource,
//                 skillPaths, instructions, unknown, problems, probeMismatches }
//   commandSource: per bridged command, its raw CC body for command.execute.before (agents.js).
//   hooks: every collected entry plus { disposition, reason, classified }. problems: the env-flag,
//   R35 and self-probe items (probe mismatches last, also listed in probeMismatches). The
//   superpowers-adapter problem is added by v1/plugin.js, which owns that composition.
// Every core module it calls is total over bad input; a throw here is a bug and the caller logs it.
export function buildInventory({ home = os.homedir(), projectDir = process.cwd(), ocTools = [], observedArgs = {}, env = process.env, worktree, baseline } = {}) {
  const unknown = [];
  // Read first: CC's trust record gates the project scope (R47). Its own unknowns keep their place.
  const cjUnknown = [];
  const claudeJson = readJson(ccPaths(home).claudeJson, cjUnknown);
  const settings = loadSettings({ home, projectDir, claudeJson: isObj(claudeJson) ? claudeJson : null });
  unknown.push(...settings.unknown);
  const { merged, sources } = settings;
  const pl = enabledPlugins({ home, merged });
  unknown.push(...pl.unknown);
  const { plugins } = pl;

  unknown.push(...cjUnknown);
  const servers = collectMcp({ claudeJson, projectDir, plugins, settings: merged, unknown, trusted: settings.trusted, home });
  const oc = toOcMcp(servers, { env });
  unknown.push(...oc.unknown);
  const mcp = oc.mcp;

  unknown.push(...enumerate({ sources, plugins, claudeJson, ocTools: Array.isArray(ocTools) ? ocTools : [], mcpServers: Object.keys(mcp), projectDir, home }));

  const disp = loadRules(env);
  if (disp.problem) unknown.push({ where: disp.file, key: "dispositions", note: disp.problem });
  const hooks = collectHooks({ merged, plugins }).map((e) => ({ ...e, ...dispositionFor(e, disp.rules) }));
  const degraded = hooks.filter((h) => h.disposition === "degraded");

  const pa = permissionAndAgents({ merged, plugins, mcp, home, projectDir, worktree, baseline });
  unknown.push(...pa.unknown);

  const problems = [];
  if (!codeModeOn(env)) problems.push(PROBLEMS.codeMode);
  if (!ccSkillsOff(env)) problems.push(PROBLEMS.ccSkills);
  problems.push(PROBLEMS.grepGlob);
  const probeMismatches = selfProbe(isObj(observedArgs) ? observedArgs : {});
  problems.push(...probeMismatches);

  return {
    merged,
    plugins,
    hooks,
    degraded,
    permission: pa.permission,
    mcp,
    agent: pa.agent,
    command: pa.command,
    commandSource: pa.commandSource,
    skillPaths: collectSkillPaths({ home, projectDir, plugins }),
    instructions: ruleFiles(home),
    unknown,
    problems,
    probeMismatches,
  };
}
