import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ccPaths, projectPaths } from "./paths.js";
import { parseFrontmatter, stripComment } from "./agents.js";

// A SKILL.md may sit at most this many directory levels below a plugin root.
export const SKILL_DEPTH = 4;
const SKIP = new Set(["node_modules", ".git"]);

const isDir = (p) => {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
};

// True if a SKILL.md exists at root/d1/.../dN (N <= maxDepth directory levels below root).
export function hasSkill(root, maxDepth = SKILL_DEPTH) {
  const seen = new Set();
  const walk = (dir, depth) => {
    let real;
    try {
      real = fs.realpathSync(dir);
    } catch {
      return false;
    }
    if (seen.has(real)) return false;
    seen.add(real);
    try {
      if (fs.statSync(path.join(dir, "SKILL.md")).isFile()) return true;
    } catch {
      /* none here */
    }
    if (depth >= maxDepth) return false;
    let ents;
    try {
      ents = fs.readdirSync(dir);
    } catch {
      return false;
    }
    return ents.some((e) => !SKIP.has(e) && isDir(path.join(dir, e)) && walk(path.join(dir, e), depth + 1));
  };
  return walk(root, 0);
}

// skills.paths. ~/.claude/skills children are added explicitly (OC's own CC-skill scan is turned
// off by OPENCODE_DISABLE_CLAUDE_CODE_SKILLS, row 12) EXCEPT `synced`.
export function skillPaths({ home = os.homedir(), projectDir, plugins = [] } = {}) {
  const out = [];
  for (const p of plugins) {
    if (p && p.exists !== false && p.installPath && hasSkill(p.installPath)) out.push(p.installPath);
  }
  const user = ccPaths(home).skillsDir;
  if (isDir(user)) {
    let ents = [];
    try {
      ents = fs.readdirSync(user).sort();
    } catch {
      /* unreadable */
    }
    for (const e of ents) if (e !== "synced" && isDir(path.join(user, e))) out.push(path.join(user, e));
  }
  if (projectDir && path.resolve(projectDir) !== path.resolve(home)) {
    const proj = projectPaths(projectDir).skillsDir;
    if (isDir(proj)) out.push(proj);
  }
  return [...new Set(out)];
}

// CC 2.1.300's Skill tool (checkPermissions, after deny and allow rules) runs a skill without a
// prompt only when every property of its definition is in a fixed "safe" set; the frontmatter
// fields that land outside it are these (non-empty). Anything else asks (docs/v1-capabilities.md).
const UNSAFE_FIELDS = ["allowed-tools", "disallowed-tools", "disallowedTools", "hooks"];
const EMPTY_LITERAL = /^(\{\s*\}|\[\s*\])$/;

function* skillFiles(root) {
  const seen = new Set();
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let real;
    try {
      real = fs.realpathSync(dir);
    } catch {
      continue;
    }
    if (seen.has(real)) continue;
    seen.add(real);
    let ents;
    try {
      ents = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of ents) {
      const p = path.join(dir, e.name);
      if (e.name === "SKILL.md" && !e.isDirectory()) yield p;
      else if (!SKIP.has(e.name) && (e.isDirectory() || (e.isSymbolicLink() && isDir(p)))) stack.push(p);
    }
  }
}

// promptingSkills(paths) -> [{ name, file, fields }]: the skills under `paths` (OC scans
// `**/SKILL.md` under each skills.paths entry and names a skill by its frontmatter `name`) that CC
// would prompt for. A field OC's parser cannot read counts as set unless it is a literal {} or [],
// so an unparseable guard still asks.
export function promptingSkills(paths = []) {
  const out = [];
  for (const root of paths) {
    if (typeof root !== "string" || !isDir(root)) continue;
    for (const file of skillFiles(root)) {
      let text;
      try {
        text = fs.readFileSync(file, "utf8");
      } catch {
        continue;
      }
      const { fm, problems } = parseFrontmatter(text);
      // R51 m-2: a frontmatter line the parser cannot read that names a guarded field fails closed.
      const lines = text.replace(/^\uFEFF/, "").split(/\r?\n/);
      const unread = problems.map((p) => /^unparseable frontmatter line (\d+)$/.exec(p)).filter(Boolean).map((m) => lines[Number(m[1])] ?? "");
      const name = typeof fm.name === "string" ? fm.name.trim() : "";
      if (!name) continue;
      const fields = UNSAFE_FIELDS.filter((k) => {
        if (unread.some((l) => l.includes(k))) return true;
        const v = fm[k];
        if (Array.isArray(v)) return v.length > 0;
        if (typeof v === "string") return v.trim() !== "";
        if (!problems.includes(`unsupported value syntax for ${k}`)) return false;
        const raw = new RegExp(`^["']?${k}["']?\\s*:\\s*(.*)$`, "m").exec(text);
        return !(raw && EMPTY_LITERAL.test(stripComment(raw[1])));
      });
      if (fields.length) out.push({ name, file, fields });
    }
  }
  return out;
}
