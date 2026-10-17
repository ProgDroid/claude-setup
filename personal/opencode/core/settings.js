import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ccPaths, projectPaths } from "./paths.js";
import { projectKey } from "./mcp.js";

// R47: the per-directory report item for an untrusted project scope. Stable text: it is a seen-key.
export const UNTRUSTED_NOTE = "project settings not trusted in CC; hooks and allows skipped (of the project settings only permissions.deny is loaded)";

// The nearest directory at or above `dir` holding a `.git` file or directory (a worktree has a file).
function gitRoot(dir) {
  for (let s = dir; ; ) {
    try {
      if (fs.existsSync(path.join(s, ".git"))) return s;
    } catch {
      return null;
    }
    const p = path.dirname(s);
    if (p === s) return null;
    s = p;
  }
}

const UNC = /^[\\/]{2}/;
// A regular file's trimmed text, or null (missing, a symlink or anything special: CC's hB guard).
function readPlain(file) {
  try {
    if (!fs.lstatSync(file).isFile()) return null;
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return null;
  }
}
const real = (p) => fs.realpathSync(p);

// The main repository of a git worktree, as CC 2.1.300 resolves it (Sr, behind qs /
// canonicalRootByRoot): `root`'s `.git` FILE names a gitdir; that gitdir's `commondir` names the
// common dir; the gitdir must sit in <common>/worktrees, and its own `gitdir` file must point back
// at `root`/.git. The main repo is the common dir's parent (or the common dir itself when it is a
// bare repo not named .git). A `.git` DIRECTORY is the root itself. Any missing piece, unreadable
// file or failed check falls back to `root` (so a submodule, whose gitdir has no commondir, is
// only its own root): fewer trust sources, never more.
export function canonicalGitRoot(root) {
  try {
    const dotGit = path.join(root, ".git");
    if (fs.lstatSync(dotGit).isDirectory()) return root;
    const txt = readPlain(dotGit);
    if (txt === null || !txt.startsWith("gitdir:")) return root;
    const gd = txt.slice(7).trim();
    if (!gd || UNC.test(gd)) return root;
    const gitdir = path.resolve(root, gd);
    const cd = readPlain(path.join(gitdir, "commondir"));
    if (!cd || UNC.test(cd)) return root;
    const common = path.resolve(gitdir, cd);
    if (!sameDir(path.dirname(gitdir), path.join(common, "worktrees"))) return root;
    const back = readPlain(path.join(gitdir, "gitdir"));
    if (!back || UNC.test(back)) return root;
    if (!sameDir(real(path.resolve(gitdir, back)), path.join(real(root), ".git"))) return root;
    if (path.basename(common) !== ".git") return fs.existsSync(path.join(common, ".git")) ? root : path.normalize(common);
    return path.dirname(common);
  } catch {
    return root;
  }
}

// Does CC trust `dir`? Mirrors CC 2.1.300 (iO / X1e / Nm in its bundle): first the canonical git
// root's own key (for a git worktree, its MAIN repository: canonicalGitRoot), then
// projects[key].hasTrustDialogAccepted === true for the directory or any parent, the walk stopping
// at the nearest git root (or, outside a repo, at the filesystem root). Keys compare through
// projectKey (forward slashes, upper-case drive, no trailing slash), as CC writes them. Anything
// malformed is untrusted: the gate fails closed.
export function ccTrusted(claudeJson, dir) {
  const projects = isObj(claudeJson) && isObj(claudeJson.projects) ? claudeJson.projects : {};
  const trusted = new Set(Object.keys(projects).filter((k) => isObj(projects[k]) && projects[k].hasTrustDialogAccepted === true).map(projectKey));
  if (!trusted.size || typeof dir !== "string" || !dir) return false;
  let s = path.resolve(dir);
  const root = gitRoot(s);
  if (root !== null && trusted.has(projectKey(canonicalGitRoot(root)))) return true;
  for (;;) {
    if (trusted.has(projectKey(s))) return true;
    if (root !== null && sameDir(s, root)) return false;
    const p = path.dirname(s);
    if (p === s) return false;
    s = p;
  }
}

// What an untrusted project scope still contributes: its deny rules, which only ever tighten.
function denyOnly(data) {
  const deny = isObj(data.permissions) && Array.isArray(data.permissions.deny) ? data.permissions.deny : [];
  return deny.length ? { permissions: { deny } } : {};
}

function readClaudeJson(file) {
  try {
    const d = JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
    return isObj(d) ? d : undefined;
  } catch {
    return undefined; // missing or corrupt: untrusted; inventory.js reports a corrupt file
  }
}

const dedupe = (arr) => {
  const seen = new Set();
  return arr.filter((x) => {
    const k = JSON.stringify(x);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
};
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// scalars: higher wins; arrays: concat + dedupe; objects: deep merge.
function mergeValue(lo, hi) {
  if (Array.isArray(lo) && Array.isArray(hi)) return dedupe([...lo, ...hi]);
  if (isObj(lo) && isObj(hi)) {
    const out = { ...lo };
    for (const k of Object.keys(hi)) out[k] = k in lo ? mergeValue(lo[k], hi[k]) : hi[k];
    return out;
  }
  return hi;
}

// Case-insensitive only on win32; platform injectable for tests.
export const sameDir = (a, b, platform = process.platform) => {
  const win = platform === "win32";
  const p = win ? path.win32 : path.posix;
  const n = (x) => {
    const r = p.resolve(x).replace(/[\\/]+$/, "");
    return win ? r.toLowerCase() : r;
  };
  return n(a) === n(b);
};

function readJson(file, unknown) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return undefined;
    unknown.push({ where: file, key: "settings", note: `unreadable: ${e && e.code}` });
    return undefined;
  }
  try {
    const data = JSON.parse(text.replace(/^﻿/, ""));
    if (!isObj(data)) throw new Error("not an object");
    return data;
  } catch (e) {
    unknown.push({ where: file, key: "settings", note: `unparseable JSON, skipped: ${e.message}` });
    return undefined;
  }
}

// Hook groups concatenate across scopes; each group and handler carries its
// origin. Identical-handler dedupe is hooks.js's job, not this module's.
function withOrigin(hooks, origin) {
  const out = {};
  if (!isObj(hooks)) return out;
  for (const [event, groups] of Object.entries(hooks)) {
    if (!Array.isArray(groups)) continue;
    out[event] = groups.filter(isObj).map((g) => ({
      ...g,
      origin,
      hooks: Array.isArray(g.hooks) ? g.hooks.map((h) => (isObj(h) ? { ...h, origin } : h)) : g.hooks,
    }));
  }
  return out;
}

// loadSettings({ home, projectDir, claudeJson?, trusted? }) -> { merged, sources, unknown, trusted }
//   R47: the project and projectLocal scopes load in full only when CC trusts projectDir
//   (ccTrusted over ~/.claude.json; pass `claudeJson` to reuse a parsed copy, or `trusted` to
//   decide outright). Untrusted, each contributes only its permissions.deny (fails closed), and
//   ONE item per directory is reported. Hooks, allows, asks, env, enabledPlugins and MCP
//   approvals of an untrusted project never load: CC would run none of them either.
export function loadSettings({ home = os.homedir(), projectDir = process.cwd(), claudeJson, trusted } = {}) {
  const unknown = [];
  const cc = ccPaths(home);
  const scopes = [{ scope: "user", origin: "settings:user", path: cc.settings }];
  if (!sameDir(projectDir, home)) {
    const pp = projectPaths(projectDir);
    scopes.push({ scope: "project", origin: "settings:project", path: pp.settings });
    scopes.push({ scope: "projectLocal", origin: "settings:projectLocal", path: pp.settingsLocal });
  }
  const isTrusted = typeof trusted === "boolean" ? trusted : ccTrusted(claudeJson === undefined ? readClaudeJson(cc.claudeJson) : claudeJson, projectDir);
  if (fs.existsSync(cc.settingsLocalUser)) {
    unknown.push({
      where: cc.settingsLocalUser,
      key: "settings.local.json",
      note: "user-level settings.local.json is not in Claude Code's documented settings stack; reported, not read",
    });
  }

  const sources = [];
  let merged = {};
  const hooks = {};
  let skipped = false;
  for (const s of scopes) {
    let data = readJson(s.path, unknown);
    if (data === undefined) continue;
    if (s.scope !== "user" && !isTrusted) {
      skipped = true;
      data = denyOnly(data);
    }
    sources.push({ scope: s.scope, path: s.path, data });
    const { hooks: h, ...rest } = data;
    merged = mergeValue(merged, rest);
    const tagged = withOrigin(h, s.origin);
    for (const [ev, groups] of Object.entries(tagged)) hooks[ev] = [...(hooks[ev] || []), ...groups];
  }
  if (skipped) unknown.push({ where: projectKey(path.resolve(projectDir)), key: "project settings (untrusted)", note: UNTRUSTED_NOTE });
  if (Object.keys(hooks).length) merged.hooks = hooks;
  return { merged, sources, unknown, trusted: isTrusted };
}
