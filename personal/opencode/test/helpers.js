import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// tree: { "relative/path": string | object(JSON) }. Paths are relative to the
// temp home; a key prefixed "project:" goes into the temp project dir instead.
// Both dirs live under the preload's CC_PARITY_TEST_DIR, which its global afterAll removes, so a
// test that never calls cleanup() no longer leaks them into the system temp dir.
export function makeHome(tree = {}) {
  const base = process.env.CC_PARITY_TEST_DIR || os.tmpdir();
  fs.mkdirSync(base, { recursive: true });
  const home = fs.mkdtempSync(path.join(base, "ccp-home-"));
  const projectDir = fs.mkdtempSync(path.join(base, "ccp-proj-"));
  for (const [rel, content] of Object.entries(tree)) {
    const isProj = rel.startsWith("project:");
    const file = path.join(isProj ? projectDir : home, isProj ? rel.slice(8) : rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, typeof content === "string" ? content : JSON.stringify(content, null, 2));
  }
  return {
    home,
    projectDir,
    cleanup() {
      fs.rmSync(home, { recursive: true, force: true });
      fs.rmSync(projectDir, { recursive: true, force: true });
    },
  };
}

// A fake CC home with one of everything the inventory derives: settings (env, permissions,
// hooks, an unknown key), two enabled plugins (semgrep: a degraded SessionEnd hook, a skill and
// a bin/ dir; superpowers: a skill, no OC adapter), ~/.claude.json MCP (serena), a rule, an
// agent, a command and a user skill. `settings` replaces the default settings object's keys.
export function makeCcHome(settings = {}) {
  const h = makeHome();
  const w = (rel, content) => {
    const f = path.isAbsolute(rel) ? rel : path.join(h.home, rel);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, typeof content === "string" ? content : JSON.stringify(content, null, 2));
  };
  const semgrep = path.join(h.home, ".claude", "plugins", "cache", "official", "semgrep", "1.0.0");
  const sp = path.join(h.home, ".claude", "plugins", "cache", "superpowers-dev", "superpowers", "7.0.0");
  w(".claude/plugins/installed_plugins.json", {
    plugins: {
      "semgrep@claude-plugins-official": [{ scope: "user", version: "1.0.0", installPath: semgrep }],
      "superpowers@superpowers-dev": [{ scope: "user", version: "7.0.0", installPath: sp }],
    },
  });
  // A real plugin ships a manifest; without one the marketplace entry is the manifest (D1) and these homes have no marketplaces.
  w(path.join(semgrep, ".claude-plugin", "plugin.json"), { name: "semgrep" });
  w(path.join(sp, ".claude-plugin", "plugin.json"), { name: "superpowers" });
  w(path.join(semgrep, "hooks", "hooks.json"), { hooks: { SessionEnd: [{ hooks: [{ type: "command", command: "semgrep-end" }] }] } });
  w(path.join(semgrep, "skills", "scan", "SKILL.md"), "---\nname: scan\n---\nbody\n");
  fs.mkdirSync(path.join(semgrep, "bin"), { recursive: true });
  w(path.join(sp, "skills", "brainstorming", "SKILL.md"), "---\nname: brainstorming\n---\nbody\n");
  w(".claude/settings.json", {
    env: { CC_TEST_ENV: "on" },
    permissions: { allow: ["Bash(git status)", "Edit(src/**)"], deny: ["Read(**/.env)"] },
    enabledPlugins: { "semgrep@claude-plugins-official": true, "superpowers@superpowers-dev": true },
    brandNewSetting: 1,
    hooks: {
      PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "unclassified-guard" }] }],
    },
    ...settings,
  });
  w(".claude.json", { mcpServers: { serena: { command: "uvx", args: ["serena", "start-mcp-server", "--context=claude-code"] } } });
  w(".claude/rules/style.md", "# style\n");
  w(".claude/agents/rev.md", "---\nname: rev\ndescription: reviewer\ntools: Read, Grep\n---\nYou review.\n");
  w(".claude/commands/hi.md", "---\ndescription: say hi\n---\nSay hi to $0\n");
  w(".claude/skills/mine/SKILL.md", "---\nname: mine\n---\nbody\n");
  return { ...h, semgrep, sp, w };
}
