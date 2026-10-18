// Test oracle: OC v1.19.0 permission matching and config-shape rules, copied from
// opencode (MIT License, Copyright (c) 2025 opencode; permission notice in
// personal/opencode/THIRD_PARTY_NOTICES). Behaviour must stay verbatim;
// only `os.homedir()` is parameterised as `home`.
//   match       packages/core/src/util/wildcard.ts:3-14
//   evaluate    packages/opencode/src/permission/index.ts:28-37
//   fromConfig  packages/opencode/src/permission/index.ts:178-198
//   defaults    packages/opencode/src/agent/agent.ts:119-135 (whitelisted dirs omitted)
//   build/plan  packages/opencode/src/agent/agent.ts:138-177 (built-ins, then the user ruleset)
//   schema      packages/core/src/v1/config/permission.ts:5-35, as a plain validator
//   commandText SessionPrompt.command (packages/opencode/src/session/prompt.ts), its template
//               steps up to the trim, read from the 1.19.0 binary's bundle; the `!`...`` shell
//               step is left out (tests never run a shell)
import path from "node:path";

const Gy = /(?:\[Image\s+\d+\]|"[^"]*"|'[^']*'|[^\s"']+)/gi;
const Ca = /\$(\d+)/g;
const Xy = /^["']|["']$/g;
// The text OC 1.19.0 renders from a command template and its argument string, as handed to
// command.execute.before.
export function commandText(C, args) {
  const Q = (args.match(Gy) ?? []).map((A) => A.replace(Xy, ""));
  const X = C.match(Ca) ?? [];
  let j = 0;
  for (const A of X) {
    const I = Number(A.slice(1));
    if (I > j) j = I;
  }
  const ae = C.replaceAll(Ca, (A, I) => {
    const le = Number(I);
    const he = le - 1;
    if (he >= Q.length) return "";
    if (le === j) return Q.slice(he).join(" ");
    return Q[he];
  });
  const Ge = C.includes("$ARGUMENTS");
  let se = ae.replaceAll("$ARGUMENTS", args);
  if (X.length === 0 && !Ge && args.trim()) se = se + "\n\n" + args;
  return se.trim();
}

export function match(input, pattern) {
  const normalized = input.replaceAll("\\", "/");
  let escaped = pattern
    .replaceAll("\\", "/")
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");

  if (escaped.endsWith(" .*")) escaped = escaped.slice(0, -3) + "( .*)?";

  return new RegExp("^" + escaped + "$", process.platform === "win32" ? "si" : "s").test(normalized);
}

export function evaluate(permission, pattern, ...rulesets) {
  return (
    rulesets
      .flat()
      .findLast((rule) => match(permission, rule.permission) && match(pattern, rule.pattern)) ?? {
      action: "ask",
      permission,
      pattern: "*",
    }
  );
}

export function fromConfig(permission, home) {
  const expand = (pattern) => {
    if (pattern.startsWith("~/")) return home + pattern.slice(1);
    if (pattern === "~") return home;
    if (pattern.startsWith("$HOME/")) return home + pattern.slice(5);
    if (pattern.startsWith("$HOME")) return home + pattern.slice(5);
    return pattern;
  };
  const ruleset = [];
  for (const [key, value] of Object.entries(permission)) {
    if (typeof value === "string") {
      ruleset.push({ permission: key, action: value, pattern: "*" });
      continue;
    }
    ruleset.push(...Object.entries(value).map(([pattern, action]) => ({ permission: key, pattern: expand(pattern), action })));
  }
  return ruleset;
}

export const defaults = (home) =>
  fromConfig(
    {
      "*": "allow",
      doom_loop: "ask",
      external_directory: { "*": "ask" },
      question: "deny",
      plan_enter: "deny",
      plan_exit: "deny",
      read: { "*": "allow", "*.env": "ask", "*.env.*": "ask", "*.env.example": "allow" },
    },
    home,
  );

// The build agent's ruleset with `user` (an OC `permission` config) merged last.
export const buildRuleset = (user, home) => [defaults(home), fromConfig({ question: "allow", plan_enter: "allow" }, home), fromConfig(user, home)];

// The plan agent's ruleset (worktree-relative data-dir plan allow omitted).
export const planRuleset = (user, home) => [
  defaults(home),
  fromConfig({ question: "allow", plan_exit: "allow", task: { general: "deny" }, edit: { "*": "deny", [path.join(".opencode", "plans", "*.md")]: "allow" } }, home),
  fromConfig(user, home),
];

// ConfigPermissionV1.Info: an Action, or an object whose known Action-only keys hold an Action
// and whose every other key holds an Action or a Record<string, Action>.
const ACTIONS = ["ask", "allow", "deny"];
const ACTION_ONLY = ["todowrite", "question", "webfetch", "websearch", "doom_loop"];
export function schemaErrors(permission) {
  const errs = [];
  if (typeof permission === "string") return ACTIONS.includes(permission) ? errs : ["permission: not an action"];
  if (permission === null || typeof permission !== "object" || Array.isArray(permission)) return ["permission: not an object"];
  for (const [k, v] of Object.entries(permission)) {
    if (ACTIONS.includes(v)) continue;
    if (ACTION_ONLY.includes(k)) {
      errs.push(`${k}: must be a bare action`);
      continue;
    }
    if (v === null || typeof v !== "object" || Array.isArray(v)) errs.push(`${k}: not an action or a record`);
    else for (const [p, a] of Object.entries(v)) if (!ACTIONS.includes(a)) errs.push(`${k}[${p}]: not an action`);
  }
  return errs;
}
