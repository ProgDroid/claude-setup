import { test, expect, afterEach } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { makeHome } from "./helpers.js";
import { skillPaths, hasSkill } from "../core/skills.js";

let h;
afterEach(() => h && h.cleanup());

const plug = (name, installPath, exists = true) => ({ key: `${name}@mk`, name, marketplace: "mk", installPath, exists });
const S = "---\nname: s\n---\nx";

// SKILL.md count under a root by a DIFFERENT traversal than core/skills.js:
// one recursive readdir (Node's own recursion), no hand-written walk, no depth limit.
function independentCount(root) {
  return fs.readdirSync(root, { recursive: true }).filter((p) => path.basename(String(p)) === "SKILL.md").length;
}

test("skills exclude `synced`, include other ~/.claude/skills children and project skills", () => {
  h = makeHome({
    ".claude/skills/keep/SKILL.md": S,
    ".claude/skills/synced/SKILL.md": S,
    ".claude/skills/also/SKILL.md": S,
    "project:.claude/skills/p/SKILL.md": S,
  });
  const got = skillPaths({ home: h.home, projectDir: h.projectDir, plugins: [] });
  expect(got).toEqual([
    path.join(h.home, ".claude", "skills", "also"),
    path.join(h.home, ".claude", "skills", "keep"),
    path.join(h.projectDir, ".claude", "skills"),
  ]);
});

test("a plugin without skills is not added; a missing plugin is not added", () => {
  h = makeHome({ "nos/agents/a.md": "x", "has/skills/s/SKILL.md": S });
  const got = skillPaths({
    home: h.home,
    projectDir: h.projectDir,
    plugins: [plug("nos", path.join(h.home, "nos")), plug("gone", path.join(h.home, "gone"), false), plug("has", path.join(h.home, "has"))],
  });
  expect(got).toEqual([path.join(h.home, "has")]);
});

test("depth limit: SKILL.md at 4 levels counts, at 5 does not", () => {
  h = makeHome({ "d4/a/b/c/d/SKILL.md": S, "d5/a/b/c/d/e/SKILL.md": S, "nm/node_modules/x/SKILL.md": S });
  expect(hasSkill(path.join(h.home, "d4"))).toBe(true);
  expect(hasSkill(path.join(h.home, "d5"))).toBe(false);
  expect(hasSkill(path.join(h.home, "nm"))).toBe(false);
});

test("no ~/.claude/skills and no project skills dir -> only plugin paths; projectDir===home adds no project scope", () => {
  h = makeHome({ "pl/skills/s/SKILL.md": S, ".claude/skills/x/SKILL.md": S });
  const got = skillPaths({ home: h.home, projectDir: h.home, plugins: [plug("pl", path.join(h.home, "pl"))] });
  // home-as-project must not list <home>/.claude/skills a second time
  expect(got).toEqual([path.join(h.home, "pl"), path.join(h.home, ".claude", "skills", "x")]);
});

test("skill path count matches an independent recursive count (3 layouts)", () => {
  h = makeHome({
    // layout 1: skills/ directly
    "p1/skills/a/SKILL.md": S,
    "p1/skills/b/SKILL.md": S,
    // layout 2: <ver>/qmd
    "p2/qmd/SKILL.md": S,
    "p2/qmd/references/ignored.md": "x",
    // layout 3: nested category
    "p3/skills/cat/sub/one/SKILL.md": S,
    "p3/skills/cat/two/SKILL.md": S,
    "p3/skills/cat/two/nested/three/SKILL.md": S,
    // a plugin without skills, and one beyond the depth limit: neither is returned
    "p4/README.md": "x",
    "p5/a/b/c/d/e/SKILL.md": S,
  });
  const roots = ["p1", "p2", "p3", "p4", "p5"].map((n) => path.join(h.home, n));
  const got = skillPaths({ home: h.home, projectDir: h.projectDir, plugins: roots.map((r, i) => plug(`p${i + 1}`, r)) });
  // Independent oracle: ONE recursive readdir per installPath (not core/skills.js's walk), the
  // depth of each SKILL.md read off its relative path. Not pinned to the returned paths.
  const found = (r) =>
    fs.readdirSync(r, { recursive: true }).map(String).filter((p) => path.basename(p) === "SKILL.md").map((p) => p.split(path.sep).length - 1);
  const perRoot = roots.map(found);
  expect(perRoot.map((d) => d.length)).toEqual([2, 1, 3, 0, 1]); // by hand: p5 has one, at depth 5
  const reachable = roots.filter((_, i) => perRoot[i].some((d) => d <= 4));
  expect(got).toEqual(reachable);
  // every SKILL.md under ALL plugin roots, minus those under roots the rule drops, == under returned paths
  const total = perRoot.reduce((n, d) => n + d.length, 0);
  const returned = got.reduce((n, p) => n + found(p).length, 0);
  expect(total).toBe(7);
  expect(returned).toBe(total - perRoot[4].length);
});
