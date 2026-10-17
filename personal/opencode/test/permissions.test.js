import { describe, test, expect } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { toOcPermission, OC_ACTION_ONLY } from "../core/permissions.js";
import * as OC from "./oc-matcher.js";

// Effect checks use the verbatim OC v1.19.0 matcher (test/oc-matcher.js). This short form puts
// only OC's catch-all default ("*": allow, agent.ts:119-121) in front of the user ruleset;
// `build()` below uses the build agent's full defaults.
function evaluate(permission, pattern, perm, home = os.homedir()) {
  return OC.evaluate(permission, pattern, [{ permission: "*", pattern: "*", action: "allow" }], OC.fromConfig(perm, home)).action;
}
const build = (permission, pattern, perm, home = os.homedir()) => OC.evaluate(permission, pattern, ...OC.buildRuleset(perm, home)).action;
// Only the emitted rules, with OC's no-match fallback ("ask"): shows what a rule itself allows.
const only = (permission, pattern, perm, home = os.homedir()) => OC.evaluate(permission, pattern, OC.fromConfig(perm, home)).action;

// The live opencode.json baseline's shape (generic patterns, in order): bare twins, allow-backs
// after the denies, the settings.json edit deny, bash "*" first.
const BASELINE = () => ({
  read: {
    "**/.ssh/**": "deny", "**/.aws/**": "deny", "**/.gnupg/**": "deny",
    "**/.env": "deny", "**/.env.local": "deny", "**/.env.*.local": "deny", "**/.env*": "deny",
    "**/*.pem": "deny", "**/id_rsa*": "deny", "**/id_ed25519*": "deny", "**/id_ecdsa*": "deny",
    "**/credentials.json": "deny",
    ".ssh/**": "deny", ".aws/**": "deny", ".gnupg/**": "deny",
    ".env": "deny", ".env.local": "deny", ".env.*.local": "deny", ".env*": "deny",
    "*.pem": "deny", "id_rsa*": "deny", "id_ed25519*": "deny", "id_ecdsa*": "deny",
    "credentials.json": "deny",
    "**/.env.example": "allow", ".env.example": "allow", "**/.env.sample": "allow", ".env.sample": "allow",
  },
  edit: { "**/.claude/settings.json": "deny", ".claude/settings.json": "deny" },
  bash: {
    "*": "ask",
    "curl * | sh": "deny", "curl * | bash": "deny", "wget * | sh": "deny", "wget * | bash": "deny",
    "git push --force*": "ask", "git push -f *": "ask", "git reset --hard*": "ask", "git clean -fdx*": "ask",
  },
});

const perms = (o = {}) => ({ allow: [], ask: [], deny: [], ...o });
const tmp = os.tmpdir();
const HOME = path.join(tmp, "ccp-perm-home");
const WT = path.join(tmp, "ccp-perm-wt");
const opts = { home: HOME, worktree: WT };
const rel = (x) => path.relative(WT, path.join(HOME, x));

describe("toOcPermission: twins (row 16a)", () => {
  test("deny Read(**/id_rsa*) emits **/id_rsa* AND the bare id_rsa*", () => {
    const { permission } = toOcPermission(perms({ deny: ["Read(**/id_rsa*)"] }), {}, opts);
    expect(permission.read["**/id_rsa*"]).toBe("deny");
    expect(permission.read["id_rsa*"]).toBe("deny");
    // Effect: a ROOT file is not matched by **/ alone (16a), the twin catches it.
    expect(evaluate("read", "id_rsa", permission)).toBe("deny");
    expect(evaluate("read", path.join("sub", "id_rsa"), permission)).toBe("deny");
  });
  test("Edit and Write both land on OC edit, twin included", () => {
    const { permission } = toOcPermission(perms({ deny: ["Edit(**/a.lock)", "Write(**/b.lock)"] }), {}, opts);
    expect(permission.edit).toMatchObject({ "**/a.lock": "deny", "a.lock": "deny", "**/b.lock": "deny", "b.lock": "deny" });
  });
  test("a bare filename deny matches at any depth in CC, so it gains the **/ form", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["Read(.env)"] }), {}, opts);
    expect(permission.read).toEqual({ ".env": "deny", "**/.env": "deny" });
    expect(unknown).toEqual([]);
    expect(evaluate("read", path.join("a", "b", ".env"), permission)).toBe("deny");
  });
  test("a bare filename ALLOW is narrowed to the root: OC's **/ would also match ../ paths (I3)", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["Read(notes.md)"] }), {}, opts);
    expect(permission.read).toEqual({ "notes.md": "allow" });
    expect(unknown).toHaveLength(1);
    expect(unknown[0].note).toContain("narrowed");
    expect(only("read", path.join("..", "other", "notes.md"), permission)).toBe("ask");
    expect(only("read", "notes.md", permission)).toBe("allow");
  });
  test("./x: deny/ask gain the any-depth form, allow stays anchored", () => {
    const { permission } = toOcPermission(perms({ deny: ["Read(./secret.txt)"], allow: ["Read(./open.txt)"] }), {}, opts);
    expect(permission.read).toMatchObject({ "secret.txt": "deny", "**/secret.txt": "deny", "open.txt": "allow" });
    expect("**/open.txt" in permission.read).toBe(false);
    expect("./secret.txt" in permission.read).toBe(false);
  });
  test("single directory segment: deny matches at any depth, allow only at the anchor", () => {
    const { permission } = toOcPermission(perms({ deny: ["Read(secrets/**)"], allow: ["Edit(src/**)"] }), {}, opts);
    expect(permission.read).toMatchObject({ "secrets/**": "deny", "**/secrets/**": "deny" });
    expect(permission.edit["src/**"]).toBe("allow");
    expect("**/src/**" in permission.edit).toBe(false);
  });
  test("a multi-segment relative pattern is emitted as is", () => {
    const { permission } = toOcPermission(perms({ deny: ["Edit(src/gen/**)"] }), {}, opts);
    expect(Object.keys(permission.edit)).toEqual(["*", "src/gen/**"]); // "*": the R45 uncovered ask
  });
});

describe("toOcPermission: home-anchored rules (R5, row 16b)", () => {
  test("deny Edit(~/.claude/settings.json) emits ~/ AND the exact worktree-relative key", () => {
    const { permission } = toOcPermission(perms({ deny: ["Edit(~/.claude/settings.json)"] }), {}, opts);
    const key = rel(".claude/settings.json");
    expect(key.startsWith("..")).toBe(true); // same drive: OC asks with a ..-relative path
    expect(permission.edit["~/.claude/settings.json"]).toBe("deny");
    expect(permission.edit[key]).toBe("deny");
    // Effect: OC asks edit with path.relative(worktree, file) (edit.ts:104).
    expect(evaluate("edit", key, permission, HOME)).toBe("deny");
  });
  test("allow and ask get both forms too", () => {
    const { permission } = toOcPermission(perms({ allow: ["Read(~/notes/x.md)"], ask: ["Read(~/notes/y.md)"] }), {}, opts);
    expect(permission.read["~/notes/x.md"]).toBe("allow");
    expect(permission.read[rel("notes/x.md")]).toBe("allow");
    expect(permission.read["~/notes/y.md"]).toBe("ask");
    expect(permission.read[rel("notes/y.md")]).toBe("ask");
  });
  test("a real temp home and worktree on the same drive", () => {
    const home = fs.mkdtempSync(path.join(tmp, "ccp-h-"));
    const wt = fs.mkdtempSync(path.join(tmp, "ccp-w-"));
    try {
      const { permission } = toOcPermission(perms({ deny: ["Read(~/.ssh/**)"] }), {}, { home, worktree: wt });
      const key = path.relative(wt, path.join(home, ".ssh/**"));
      expect(permission.read[key]).toBe("deny");
      expect(evaluate("read", path.relative(wt, path.join(home, ".ssh", "id_x")), permission, home)).toBe("deny");
    } finally {
      fs.rmSync(home, { recursive: true, force: true });
      fs.rmSync(wt, { recursive: true, force: true });
    }
  });
  test.if(process.platform === "win32")("a worktree on another drive yields an absolute key, which also matches", () => {
    const drive = path.parse(HOME).root.slice(0, 1).toUpperCase();
    const other = drive === "Q" ? "R" : "Q";
    const wt = `${other}:\\proj`;
    const { permission } = toOcPermission(perms({ deny: ["Edit(~/.claude/settings.json)"] }), {}, { home: HOME, worktree: wt });
    const key = path.relative(wt, path.join(HOME, ".claude/settings.json"));
    expect(path.isAbsolute(key)).toBe(true);
    expect(permission.edit[key]).toBe("deny");
    expect(evaluate("edit", path.join(HOME, ".claude", "settings.json"), permission, HOME)).toBe("deny");
  });
  test("~/**/x with the worktree under home also covers files inside the worktree", () => {
    const home = path.join(tmp, "ccp-h2");
    const wt = path.join(home, "proj");
    const { permission } = toOcPermission(perms({ deny: ["Read(~/**/.netrc)"] }), {}, { home, worktree: wt });
    expect(permission.read).toMatchObject({ "~/**/.netrc": "deny", "**/.netrc": "deny", ".netrc": "deny" });
    expect(evaluate("read", path.join("sub", ".netrc"), permission, home)).toBe("deny");
    expect(evaluate("read", ".netrc", permission, home)).toBe("deny");
  });
  test("no worktree: only the ~/ form, and an unknown says why", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["Edit(~/.claude/settings.json)"] }), {}, { home: HOME });
    expect(Object.keys(permission.edit)).toEqual(["*", "~/.claude/settings.json"]); // "*": the R45 ask
    expect(unknown).toHaveLength(1);
    expect(unknown[0]).toMatchObject({ where: "permissions.deny", key: "Edit(~/.claude/settings.json)" });
  });
});

describe("toOcPermission: // absolute and other anchors", () => {
  test("//**/x is any file anywhere: **/x plus the bare twin", () => {
    const { permission } = toOcPermission(perms({ deny: ["Read(//**/.pgpass)"] }), {}, opts);
    expect(permission.read).toMatchObject({ "**/.pgpass": "deny", ".pgpass": "deny" });
    expect(evaluate("read", path.join("..", "..", "x", ".pgpass"), permission)).toBe("deny");
  });
  test.if(process.platform === "win32")("win32 //c/... becomes the c: path plus its worktree-relative form", () => {
    const drive = path.parse(WT).root.slice(0, 1).toLowerCase();
    const { permission, unknown } = toOcPermission(perms({ deny: [`Read(//${drive}/secret/**)`] }), {}, opts);
    const abs = `${drive}:/secret/**`;
    expect(unknown).toEqual([]);
    expect(permission.read[abs]).toBe("deny");
    expect(permission.read[path.relative(WT, abs)]).toBe("deny");
    expect(evaluate("read", path.relative(WT, `${drive}:/secret/k`), permission)).toBe("deny");
  });
  test.if(process.platform === "win32")("win32 // without a drive segment is unknown", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["Read(//etc/passwd)"] }), {}, opts);
    expect(permission.read).toBeUndefined();
    expect(unknown.map((u) => u.key)).toEqual(["Read(//etc/passwd)"]);
  });
  test.if(process.platform !== "win32")("posix //abs becomes /abs plus its worktree-relative form", () => {
    const { permission } = toOcPermission(perms({ deny: ["Read(//etc/passwd)"] }), {}, opts);
    expect(permission.read["/etc/passwd"]).toBe("deny");
    expect(permission.read[path.relative(WT, "/etc/passwd")]).toBe("deny");
  });
  test("I1: a single-slash /path deny over-matches as **/path (plus the bare twin), reported", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["Edit(/src/**)"] }), {}, opts);
    expect(permission.edit).toMatchObject({ "**/src/**": "deny", "src/**": "deny" });
    expect(evaluate("edit", path.join("src", "a.ts"), permission)).toBe("deny");
    expect(evaluate("edit", path.join("pkg", "src", "a.ts"), permission)).toBe("deny");
    expect(unknown[0]).toMatchObject({ where: "permissions.deny", key: "Edit(/src/**)" });
    expect(unknown[0].note).toContain("**/");
  });
  test("I1: a character class deny becomes ?; a ! negation deny asks on the whole key (R35 floor)", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["Read(**/[ab].key)", "Read(!sample.env)"] }), {}, opts);
    expect(permission.read).toMatchObject({ "**/?.key": "deny", "?.key": "deny", "*": "ask" });
    expect(evaluate("read", path.join("d", "a.key"), permission)).toBe("deny");
    expect(evaluate("read", "b.key", permission)).toBe("deny");
    expect(evaluate("read", "other.txt", permission)).toBe("ask");
    expect(unknown.map((u) => u.key)).toEqual(["Read(**/[ab].key)", "Read(!sample.env)"]);
  });
  test("I1: the same untranslatable forms as ALLOWS are dropped (dropping an allow fails closed)", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["Read(/src/**)", "Read(**/[ab].key)", "Read(!sample.env)"] }), {}, opts);
    expect(permission.read).toBeUndefined();
    expect(unknown.map((u) => u.key)).toEqual(["Read(/src/**)", "Read(**/[ab].key)", "Read(!sample.env)"]);
    for (const u of unknown) expect(u.note).toStartWith("not translated");
  });
  test("an allow whose single * would cross directories in OC is unknown; the same deny is emitted", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["Edit(src/*.ts)"], deny: ["Edit(lib/*.ts)"] }), {}, opts);
    expect(permission.edit).toEqual({ "*": "ask", "lib/*.ts": "deny" });
    expect(unknown.map((u) => u.key)).toEqual(["Edit(src/*.ts)"]);
  });
});

describe("toOcPermission: never a read/edit allow-all (row 16c); uncovered edits ask (R45)", () => {
  const inputs = ["Read", "Edit", "Write", "Read(*)", "Edit(**)", "Write(./*)", "Read(//**)", "Edit(**/*)", "Read(~/**)"];
  test('allow: no match-everything ALLOW key in edit or read; edit "*" is the R45 ask, first', () => {
    const { permission, unknown } = toOcPermission(perms({ allow: inputs }), {}, { home: HOME, worktree: HOME });
    expect("*" in (permission.read || {})).toBe(false);
    expect(Object.keys(permission.edit)[0]).toBe("*");
    expect(permission.edit["*"]).toBe("ask");
    for (const p of ["read", "edit"]) {
      for (const [k, v] of Object.entries(permission[p] || {})) if (/^[*/\\]+$/.test(k)) expect(v).not.toBe("allow");
    }
    expect(unknown.length).toBeGreaterThan(0);
  });
  test('ask: a match-everything ask becomes "*":"ask" (I1), never an allow-all', () => {
    const { permission } = toOcPermission(perms({ ask: inputs }), {}, { home: HOME, worktree: HOME });
    expect(permission.read["*"]).toBe("ask");
    expect(permission.edit["*"]).toBe("ask");
    for (const p of ["read", "edit"]) {
      const allAll = Object.entries(permission[p]).filter(([k]) => /^[*/\\]+$/.test(k));
      expect(allAll).toEqual([["*", "ask"]]);
    }
    expect(build("read", path.join("src", "a.ts"), permission, HOME)).toBe("ask");
    expect(build("edit", path.join("src", "a.ts"), permission, HOME)).toBe("ask");
  });
  test('deny: a match-everything rule becomes "*":"deny" as the LAST key, never earlier (M1)', () => {
    for (const input of inputs) {
      const { permission } = toOcPermission(perms({ deny: [input] }), BASELINE(), { home: HOME, worktree: HOME });
      const p = input.startsWith("Read") ? "read" : "edit";
      const keys = Object.keys(permission[p]);
      expect(keys.at(-1)).toBe("*");
      expect(permission[p]["*"]).toBe("deny");
      for (const k of keys.slice(0, -1)) expect(/^[*/\\]+$/.test(k)).toBe(false);
      // Effect: every path is denied, including the baseline's own allow-back.
      expect(build(p, ".env.example", permission, HOME)).toBe("deny");
      expect(build(p, path.join("src", "a.ts"), permission, HOME)).toBe("deny");
    }
  });
  test("a deny whose worktree-relative form covers the whole worktree becomes a deny-all, with a note (M2)", () => {
    const home = path.join(tmp, "ccp-m2-home");
    const wt = path.join(home, "proj");
    const { permission, unknown } = toOcPermission(perms({ deny: ["Read(~/proj/**)"] }), {}, { home, worktree: wt });
    expect(Object.keys(permission.read).at(-1)).toBe("*");
    expect(only("read", path.join("src", "a.ts"), permission, home)).toBe("deny");
    expect(unknown).toHaveLength(1);
    expect(unknown[0].note).toContain("deny-all");
  });
  test("a deny-all still lets the plan agent's built-in edit deny stand, and blocks the build agent", () => {
    const { permission } = toOcPermission(perms({ deny: ["Edit"] }), {}, opts);
    expect(OC.evaluate("edit", path.join("src", "a.ts"), ...OC.planRuleset(permission, HOME)).action).toBe("deny");
    expect(build("edit", path.join("src", "a.ts"), permission, HOME)).toBe("deny");
  });
  test("a baseline edit '*' is kept (unless the baseline had one)", () => {
    const { permission } = toOcPermission(perms({ deny: ["Edit(**/x)"] }), { edit: { "*": "ask" } }, opts);
    expect(permission.edit["*"]).toBe("ask");
  });
  test("a baseline string edit: 'ask' becomes the equivalent object", () => {
    const { permission } = toOcPermission(perms({ deny: ["Edit(**/x)"] }), { edit: "ask" }, opts);
    expect(permission.edit).toEqual({ "*": "ask", "**/x": "deny", x: "deny" });
  });
});

describe("toOcPermission: baseline preservation and order", () => {
  test("every baseline rule survives, and the allow-back precedes the CC-derived denies", () => {
    const base = BASELINE();
    const snapshot = JSON.stringify(base);
    const { permission } = toOcPermission(perms({ deny: ["Read(**/secret.txt)", "Read(**/.env*)"] }), base, opts);
    expect(JSON.stringify(base)).toBe(snapshot); // the baseline object itself is not mutated
    for (const [p, rules] of Object.entries(BASELINE())) {
      for (const [k, v] of Object.entries(rules)) expect(permission[p][k]).toBe(v);
    }
    const keys = Object.keys(permission.read);
    expect(keys.indexOf("**/.env.example")).toBeLessThan(keys.indexOf("**/secret.txt"));
    // A CC deny on an existing baseline key keeps the baseline position, so the allow-back holds.
    expect(keys.indexOf("**/.env*")).toBeLessThan(keys.indexOf("**/.env.example"));
    expect(evaluate("read", ".env.example", permission)).toBe("allow");
    expect(evaluate("read", ".env", permission)).toBe("deny");
    expect(evaluate("read", path.join("a", "secret.txt"), permission)).toBe("deny");
  });
  test("a baseline-only permission key is kept untouched", () => {
    const { permission } = toOcPermission(perms(), { external_directory: { "~/x/*": "allow" }, webfetch: "ask" }, opts);
    expect(permission.external_directory).toEqual({ "~/x/*": "allow" });
    expect(permission.webfetch).toBe("ask");
  });
  test("on a key collision the stricter action wins; CC never weakens a baseline rule", () => {
    const base = { read: { "**/a": "deny", "**/b": "allow" } };
    const { permission } = toOcPermission(perms({ allow: ["Read(**/a)"], deny: ["Read(**/b)"] }), base, opts);
    expect(permission.read["**/a"]).toBe("deny");
    expect(permission.read["**/b"]).toBe("deny");
  });
  test("a CC allow never shadows a baseline ask or deny (CC: deny > ask > allow)", () => {
    const { permission } = toOcPermission(perms({ allow: ["Bash(git push:*)", "Bash(curl:*)"] }), BASELINE(), opts);
    expect(evaluate("bash", "git push --force origin", permission)).toBe("ask");
    expect(evaluate("bash", "curl x | sh", permission)).toBe("deny");
    expect(evaluate("bash", "git push origin", permission)).toBe("allow");
  });
  test("CC ask beats CC allow, CC deny beats both, whatever the input order", () => {
    const { permission } = toOcPermission(
      perms({ deny: ["Bash(rm -rf:*)"], ask: ["Bash(rm:*)"], allow: ["Bash(rm -i:*)"] }), {}, opts);
    expect(Object.keys(permission.bash)).toEqual(["*", "rm -i *", "rm *", "rm -rf *"]);
    expect(evaluate("bash", "rm -rf /", permission)).toBe("deny");
    expect(evaluate("bash", "rm x", permission)).toBe("ask");
  });
  test("R34 order: '*' -> CC allow -> CC ask -> baseline -> CC deny", () => {
    const { permission } = toOcPermission(
      perms({ allow: ["Bash(ls *)"], ask: ["Bash(curl:*)"], deny: ["Bash(nc *)"] }), { bash: { "*": "ask", "curl * | sh": "deny" } }, opts);
    expect(Object.keys(permission.bash)).toEqual(["*", "ls *", "curl *", "curl * | sh", "nc *"]);
  });
  test("a broader CC ask never downgrades a baseline deny (I1)", () => {
    const { permission } = toOcPermission(perms({ ask: ["Bash(curl:*)", "Bash(wget *)", "Read(**/id_*)"] }), BASELINE(), opts);
    expect(build("bash", "curl x | sh", permission)).toBe("deny");
    expect(build("bash", "wget u | bash", permission)).toBe("deny");
    expect(build("read", "id_rsa", permission)).toBe("deny");
    expect(build("read", path.join("sub", "id_ed25519"), permission)).toBe("deny");
    // ...while the CC ask still applies where the baseline is silent.
    expect(build("bash", "curl https://x", permission)).toBe("ask");
    expect(build("read", path.join("sub", "id_other"), permission)).toBe("ask");
  });
  test("an accepted R34 consequence: a baseline allow-back beats a broader CC ask", () => {
    const { permission } = toOcPermission(perms({ ask: ["Read(**/.env.*)"] }), BASELINE(), opts);
    expect(build("read", ".env.example", permission)).toBe("allow");
    expect(build("read", ".env.prod", permission)).toBe("deny"); // the baseline's own .env* deny
  });
  test("a CC deny on a NEW key beats the baseline allow-back (CC is main, R34 / review M3)", () => {
    const { permission } = toOcPermission(perms({ deny: ["Read(**/.env.*)"] }), BASELINE(), opts);
    expect(build("read", ".env.example", permission)).toBe("deny");
  });
  test("a bare CC Bash deny is the LAST key and beats every allow and ask (I2)", () => {
    const { permission } = toOcPermission(perms({ deny: ["Bash"], allow: ["Bash(ls *)"], ask: ["Bash(git:*)"] }), BASELINE(), opts);
    const keys = Object.keys(permission.bash);
    expect(keys.at(-1)).toBe("*");
    expect(permission.bash["*"]).toBe("deny");
    for (const c of ["ls", "ls -la", "git push --force x", "git status", "curl x | sh", "echo hi"]) expect(build("bash", c, permission)).toBe("deny");
  });
  test("a bare CC Bash ask sits after the CC allows, so it beats them; specific baseline keys still follow", () => {
    const { permission } = toOcPermission(perms({ ask: ["Bash"], allow: ["Bash(ls *)"] }), BASELINE(), opts);
    expect(Object.keys(permission.bash).slice(0, 2)).toEqual(["ls *", "*"]);
    expect(build("bash", "ls", permission)).toBe("ask");
    expect(build("bash", "curl x | sh", permission)).toBe("deny");
  });
});

describe("toOcPermission: bash", () => {
  test('bash["*"] === "ask" and comes first, with or without a baseline', () => {
    for (const base of [{}, BASELINE(), { bash: { "curl * | sh": "deny" } }]) {
      const { permission } = toOcPermission(perms({ allow: ["Bash(ls *)"] }), base, opts);
      expect(permission.bash["*"]).toBe("ask");
      expect(Object.keys(permission.bash)[0]).toBe("*");
    }
  });
  test("an added '*' never shadows a baseline bash deny (it goes first)", () => {
    const { permission } = toOcPermission(perms(), { bash: { "curl * | sh": "deny" } }, opts);
    expect(evaluate("bash", "curl x | sh", permission)).toBe("deny");
    expect(evaluate("bash", "ls", permission)).toBe("ask");
  });
  test("a baseline bash '*' value is kept", () => {
    const { permission } = toOcPermission(perms(), { bash: { "*": "allow" } }, opts);
    expect(permission.bash["*"]).toBe("allow");
  });
  test("x:* becomes 'x *' with a word boundary (R20); others pass through", () => {
    const { permission } = toOcPermission(perms({ allow: ["Bash(npm run test:*)", "Bash(ls *)", "Bash(git status)"] }), {}, opts);
    expect(permission.bash).toEqual({ "*": "ask", "npm run test *": "allow", "ls *": "allow", "git status": "allow" });
    expect(evaluate("bash", "npm run test", permission)).toBe("allow");
    expect(evaluate("bash", "npm run testx", permission)).toBe("ask");
  });
  test("bare Bash sets the '*' action", () => {
    expect(toOcPermission(perms({ deny: ["Bash"] }), {}, opts).permission.bash).toEqual({ "*": "deny" });
  });
});

describe("toOcPermission: WebFetch", () => {
  test("bare WebFetch is the whole webfetch permission", () => {
    expect(toOcPermission(perms({ deny: ["WebFetch"] }), {}, opts).permission.webfetch).toBe("deny");
  });
  test("every domain: rule is unknown, never a per-URL object (C1: OC's schema rejects it)", () => {
    const rules = ["WebFetch(domain:example.com)", "WebFetch(domain:*.example.com)", "WebFetch(domain:docs.rs)"];
    for (const kind of ["allow", "ask", "deny"]) {
      for (const base of [{}, { webfetch: "ask" }]) {
        const { permission, unknown } = toOcPermission(perms({ [kind]: rules }), base, opts);
        expect(permission.webfetch === undefined || typeof permission.webfetch === "string").toBe(true);
        // allow: unknown only; deny/ask: fail-safe "ask" for every URL (R35)
        expect(permission.webfetch).toBe("ask"); // allow: the baseline, else R45's uncovered ask
        expect(unknown.map((u) => u.key)).toEqual(rules);
        for (const u of unknown) expect(u.note).toContain("no per-URL patterns");
      }
    }
  });
  test("R35: a domain deny makes every fetch ask, never OC's default allow; schema-valid", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["WebFetch(domain:evil.com)"] }), BASELINE(), opts);
    expect(permission.webfetch).toBe("ask");
    expect(OC.schemaErrors(permission)).toEqual([]);
    expect(build("webfetch", "https://evil.com/x", permission)).toBe("ask");
    expect(unknown.map((u) => u.key)).toEqual(["WebFetch(domain:evil.com)"]);
    expect(unknown[0].note).toContain("set to ask");
  });
  test("R35: a stricter baseline webfetch deny is kept", () => {
    for (const kind of ["deny", "ask"]) {
      const { permission } = toOcPermission(perms({ [kind]: ["WebFetch(domain:evil.com)"] }), { webfetch: "deny" }, opts);
      expect(permission.webfetch).toBe("deny");
      expect(OC.schemaErrors(permission)).toEqual([]);
    }
  });
  test("R35: a domain allow adds no allow; the uncovered webfetch asks (R45)", () => {
    const { permission } = toOcPermission(perms({ allow: ["WebFetch(domain:docs.rs)"] }), BASELINE(), opts);
    expect(permission.webfetch).toBe("ask");
    expect(build("webfetch", "https://docs.rs/x", permission)).toBe("ask"); // never an allow from the domain rule
  });
  test("domain:* is the bare action; it merges with a baseline string by the stricter action", () => {
    expect(toOcPermission(perms({ deny: ["WebFetch(domain:*)"] }), {}, opts).permission.webfetch).toBe("deny");
    expect(toOcPermission(perms({ allow: ["WebFetch"] }), { webfetch: "ask" }, opts).permission.webfetch).toBe("ask");
    expect(toOcPermission(perms({ deny: ["WebFetch"] }), { webfetch: "ask" }, opts).permission.webfetch).toBe("deny");
  });
  test("a baseline webfetch object (already invalid for OC) is never extended; the CC rule is reported", () => {
    const base = { webfetch: { "*": "ask" } };
    const { permission, unknown } = toOcPermission(perms({ deny: ["WebFetch"] }), base, opts);
    expect(permission.webfetch).toEqual({ "*": "ask" });
    expect(unknown.map((u) => u.key)).toEqual(["WebFetch"]);
  });
});

describe("toOcPermission: OC v1.19.0 config schema (C1)", () => {
  const RULES = [
    "Bash", "Bash(ls *)", "Bash(git push:*)", "Read", "Edit", "Write", "Read(**/id_rsa*)", "Read(.env)",
    "Read(~/.ssh/**)", "Edit(~/.claude/settings.json)", "Read(//**/.netrc)", "Edit(src/**)", "Read(notes.md)",
    "WebFetch", "WebFetch(domain:*)", "WebFetch(domain:example.com)", "WebFetch(domain:*.x.org)",
    "mcp__srv-a__query-docs", "mcp__srv-b", "mcp__s__*", "Glob(**)", "*",
  ];
  const BASES = [{}, BASELINE(), { webfetch: "ask", todowrite: "allow", websearch: "deny" }, "ask"];
  for (const kind of ["allow", "ask", "deny"]) {
    test(`${kind}: every emitted permission value has OC's schema shape, for every tool`, () => {
      for (const base of BASES) {
        const { permission } = toOcPermission(perms({ [kind]: RULES }), base, opts);
        expect(OC.schemaErrors(permission)).toEqual([]);
        for (const k of OC_ACTION_ONLY) if (k in permission) expect(["allow", "ask", "deny"]).toContain(permission[k]);
      }
    });
  }
  test("the schema check itself rejects a per-URL webfetch object (positive control)", () => {
    expect(OC.schemaErrors({ webfetch: { "*": "ask", "https://x": "deny" } })).toEqual(["webfetch: must be a bare action"]);
    expect(OC.schemaErrors({ read: { a: "nope" } })).toEqual(["read[a]: not an action"]);
  });
});

describe("toOcPermission: an allow never matches more than CC's (I3)", () => {
  test("a single-segment glob under ~/ is unknown: OC's * would cross directories", () => {
    const home = path.join(tmp, "ccp-i3-home");
    const wt = path.join(home, "proj");
    const { permission, unknown } = toOcPermission(perms({ allow: ["Read(~/*.md)"] }), {}, { home, worktree: wt });
    expect(permission.read).toBeUndefined();
    expect(unknown.map((u) => u.key)).toEqual(["Read(~/*.md)"]);
    // the same rule as a deny may over-match, and is emitted
    expect(toOcPermission(perms({ deny: ["Read(~/*.md)"] }), {}, { home, worktree: wt }).permission.read["~/*.md"]).toBe("deny");
  });
  test.if(process.platform === "win32")("a single-segment glob under //c/ is unknown", () => {
    const d = path.parse(WT).root.slice(0, 1).toLowerCase();
    const { permission, unknown } = toOcPermission(perms({ allow: [`Read(//${d}/docs/*.md)`] }), {}, opts);
    expect(permission.read).toBeUndefined();
    expect(unknown).toHaveLength(1);
  });
  test("~/**/x as an allow never matches outside home", () => {
    const home = path.join(tmp, "ccp-i3-home");
    const wt = path.join(home, "proj");
    const { permission, unknown } = toOcPermission(perms({ allow: ["Read(~/**/.netrc)"] }), {}, { home, worktree: wt });
    const outside = path.relative(wt, path.join(path.parse(tmp).root, "etc", ".netrc"));
    expect(only("read", outside, permission, home)).toBe("ask");
    expect(only("read", path.relative(wt, path.join(home, "deep", ".netrc")), permission, home)).toBe("ask"); // narrowed, not broadened
    expect(only("read", ".netrc", permission, home)).toBe("allow");
    expect(unknown[0].note).toContain("narrowed");
  });
  test("a relative allow never gains a form that climbs out of the worktree", () => {
    for (const rule of ["Read(notes.md)", "Read(**/notes.md)", "Read(//**/notes.md)"]) {
      const { permission } = toOcPermission(perms({ allow: [rule] }), {}, opts);
      expect(only("read", path.join("..", "other", "notes.md"), permission)).toBe("ask");
      expect(only("read", path.join("..", "..", "x", "y", "notes.md"), permission)).toBe("ask");
    }
  });
  test("an allow with only escaping forms is unknown", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["Read(**/*.md)", "Read(*.md)"] }), {}, opts);
    expect(permission.read).toBeUndefined();
    expect(unknown.map((u) => u.key)).toEqual(["Read(**/*.md)", "Read(*.md)"]);
  });
  test("safe allows are untouched: anchored literals and ** after a literal segment", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["Read(~/notes/**)", "Edit(src/**)", "Read(~/a/x.md)"] }), {}, opts);
    expect(unknown).toEqual([]);
    expect(permission.read).toMatchObject({ "~/notes/**": "allow", [rel("notes/**")]: "allow", "~/a/x.md": "allow", [rel("a/x.md")]: "allow" });
    expect(permission.edit).toEqual({ "*": "ask", "src/**": "allow" });
  });
});

describe("toOcPermission: MCP", () => {
  test("mcp__<server>__<tool> becomes the OC tool permission <server>_<tool>", () => {
    const { permission } = toOcPermission(perms({ allow: ["mcp__srv-a__query-docs"], deny: ["mcp__plugin_qmd_qmd__get"] }), {}, opts);
    expect(permission["srv-a_query-docs"]).toBe("allow");
    expect(permission["plugin_qmd_qmd_get"]).toBe("deny");
    // OC asks MCP tools with permission = tool id, pattern "*" (session/tools.ts:408).
    expect(evaluate("srv-a_query-docs", "*", { "*": "ask", ...permission })).toBe("allow");
  });
  test("a whole-server rule (bare or __*) becomes <server>_*", () => {
    const { permission } = toOcPermission(perms({ deny: ["mcp__srv-b", "mcp__other__*"] }), {}, opts);
    expect(permission).toMatchObject({ "srv-b_*": "deny", "other_*": "deny" });
    expect(evaluate("srv-b_search", "*", permission)).toBe("deny");
  });
  test("a tool deny after a server allow wins (deny > allow)", () => {
    const { permission } = toOcPermission(perms({ allow: ["mcp__s"], deny: ["mcp__s__drop"] }), {}, opts);
    expect(evaluate("s_drop", "*", permission)).toBe("deny");
    expect(evaluate("s_keep", "*", permission)).toBe("allow");
  });
  test("parenthesised MCP rules stay unknown; server-glob DENIES are emitted as a superset key (I1) unless it hits an OC built-in (m2)", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["mcp__s__t(x)", "mcp__*", "mcp__s*__t"] }), {}, opts);
    expect("*_*" in permission).toBe(false); // m2: it would also match external_directory, plan_enter, ...
    expect(permission["s*_t"]).toBe("deny");
    expect(toOcPermission(perms({ deny: ["mcp__*"] }), {}, { ...opts, mcpServers: ["a"] }).permission["a_*"]).toBe("deny");
    expect("*" in permission).toBe(false); // never a top-level "*"
    expect([...new Set(unknown.map((u) => u.key))]).toEqual(["mcp__s__t(x)", "mcp__*", "mcp__s*__t"]);
  });
  test("server-glob ALLOWS stay unknown", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["mcp__*", "mcp__s*__t", "mcp__s*"] }), {}, opts);
    for (const k of ["*_*", "s*_t", "s*_*", "s*"]) expect(k in permission).toBe(false);
    expect(unknown.map((u) => u.key)).toEqual(["mcp__*", "mcp__s*__t", "mcp__s*"]);
  });
  test("a server prefix that also prefixes another known server: allow unknown, deny emitted and reported", () => {
    const { permission, unknown } = toOcPermission(perms({ allow: ["mcp__my"], deny: ["mcp__my__x"] }), {}, { ...opts, mcpServers: ["my", "my_srv"] });
    expect(permission["my_*"]).toBe("ask"); // R45's uncovered ask, never the CC allow
    expect(permission["my_x"]).toBe("deny");
    expect(unknown.map((u) => u.key)).toEqual(["mcp__my"]);
    const d = toOcPermission(perms({ deny: ["mcp__my"] }), {}, { ...opts, mcpServers: ["my", "my_srv"] });
    expect(d.permission["my_*"]).toBe("deny");
    expect(d.unknown).toHaveLength(1);
  });
});

describe("toOcPermission: everything else", () => {
  test("tools with no OC key are unknown with {where, key, note}; Glob(x) is a whole-key superset", () => {
    const { permission, unknown } = toOcPermission(perms({ deny: ["Glob(**)", "NoSuchTool", "*"] }), {}, opts);
    expect(permission.glob).toEqual({ "*": "deny" });
    expect("*" in permission).toBe(false);
    expect(unknown.map((u) => u.key)).toEqual(["Glob(**)", "NoSuchTool", "*"]);
    for (const u of unknown) {
      expect(u.where).toBe("permissions.deny");
      expect(typeof u.note).toBe("string");
    }
  });
  test("missing perms or baseline are tolerated; uncovered calls get CC's default (R45/R49)", () => {
    const { permission, unknown } = toOcPermission(undefined, undefined, opts);
    expect(permission).toEqual({ bash: { "*": "ask" }, edit: { "*": "ask" }, webfetch: "ask", websearch: "ask" });
    expect(unknown).toEqual([]);
  });
  test("the live-shaped deny set has the intended effect against the baseline", () => {
    const home = path.join(tmp, "ccp-live-home");
    const wt = path.join(tmp, "ccp-live-wt");
    const cc = perms({
      deny: ["Read(~/.ssh/**)", "Read(**/.env*)", "Read(**/id_rsa*)", "Edit(~/.claude/settings.json)", "Bash(curl * | sh)"],
      ask: ["Bash(git reset --hard*)"],
    });
    const { permission, unknown } = toOcPermission(cc, BASELINE(), { home, worktree: wt });
    expect(unknown).toEqual([]);
    const r = (x) => path.relative(wt, path.join(home, x));
    expect(evaluate("read", r(".ssh/config"), permission, home)).toBe("deny");
    expect(evaluate("edit", r(".claude/settings.json"), permission, home)).toBe("deny");
    expect(evaluate("read", "id_rsa.pub", permission, home)).toBe("deny");
    expect(evaluate("read", ".env.example", permission, home)).toBe("allow");
    expect(evaluate("bash", "git reset --hard HEAD", permission, home)).toBe("ask");
    expect(evaluate("read", "src/a.ts", permission, home)).toBe("allow");
  });
});
