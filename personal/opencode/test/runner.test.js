import { afterAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { findBash, killTree, plan, runAll, runHook, sweepSet, timeoutFor, sysExe, WIN_TOOLS } from "../core/runner.js";
import { interpret } from "../core/protocol.js";

const WIN = process.platform === "win32";
const winTest = WIN ? test : test.skip;
const FIX = path.join(import.meta.dir, "fixtures", "hooks");
const tmps = [];
const mkRoot = (name = "has space") => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-run-"));
  tmps.push(base);
  const root = path.join(base, name);
  fs.mkdirSync(root, { recursive: true });
  return root;
};
afterAll(() => tmps.forEach((d) => fs.rmSync(d, { recursive: true, force: true })));

const input = { hook_event_name: "PreToolUse", tool_name: "Bash" };

// Newest semgrep install by numeric semver (never .in_use, never lexical order).
function semgrepScripts() {
  const base = path.join(os.homedir(), ".claude", "plugins", "cache");
  const found = [];
  for (const mk of fs.existsSync(base) ? fs.readdirSync(base) : []) {
    const d = path.join(base, mk, "semgrep");
    if (!fs.existsSync(d)) continue;
    for (const v of fs.readdirSync(d)) if (/^\d+\.\d+\.\d+/.test(v) && fs.existsSync(path.join(d, v, "scripts", "hook"))) found.push(path.join(d, v));
  }
  if (!found.length) throw new Error("RF1 exec-form test needs semgrep's real scripts/hook under ~/.claude/plugins/cache/*/semgrep/<semver>/ and found none. Install the semgrep plugin; this test must not skip.");
  const key = (p) => path.basename(p).split(/[.-]/).slice(0, 3).map(Number);
  found.sort((a, b) => { const x = key(a), y = key(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return y[i] - x[i]; return 0; });
  return path.join(found[0], "scripts");
}

describe("env, stdin and shell form", () => {
  test("stdin JSON, CLAUDE_PROJECT_DIR, CLAUDE_PLUGIN_ROOT and settings env reach the hook", async () => {
    const root = mkRoot();
    fs.mkdirSync(path.join(root, "hooks"));
    fs.copyFileSync(path.join(FIX, "dump.sh"), path.join(root, "hooks", "dump.sh"));
    const projectDir = mkRoot("proj dir");
    const r = await runHook({ event: "PreToolUse", command: 'sh "${CLAUDE_PLUGIN_ROOT}/hooks/dump.sh"', pluginRoot: root }, input, { cwd: os.tmpdir(), projectDir, env: { FOO: "bar" } });
    expect(r.spawnError).toBeUndefined();
    expect(r.status).toBe(0);
    expect(r.stdout).toContain(`PD=${projectDir}`);
    expect(r.stdout).toContain(`PR=${root}`);
    expect(r.stdout).toContain("FOO=bar");
    expect(r.stdout).toContain('"tool_name":"Bash"');
    expect(r.timedOut).toBe(false);
  });
  test("RF1 shell form: plugin root with a space", async () => {
    const root = mkRoot();
    fs.mkdirSync(path.join(root, "hooks"));
    fs.copyFileSync(path.join(FIX, "dump.sh"), path.join(root, "hooks", "dump.sh"));
    const r = await runHook({ event: "PreToolUse", command: '"${CLAUDE_PLUGIN_ROOT}/hooks/dump.sh"', pluginRoot: root }, input, { cwd: os.tmpdir(), projectDir: os.tmpdir() });
    expect(r.spawnError).toBeUndefined();
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("tool_name");
  });
  test("exit code and stderr are captured", async () => {
    const r = await runHook({ event: "PreToolUse", command: "echo oops >&2; exit 2" }, input, { cwd: os.tmpdir() });
    expect(r.status).toBe(2);
    expect(r.stderr).toContain("oops");
    expect(interpret("PreToolUse", r).block).toBe("oops");
  });
  test("powershell shell form runs", async () => {
    if (!WIN) return;
    const r = await runHook({ event: "PreToolUse", command: "Write-Output hi-from-ps", shell: "powershell" }, input, { cwd: os.tmpdir() });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("hi-from-ps");
  });
  test("findBash returns something that runs", () => {
    const b = findBash();
    const r = spawnSync(b, ["-c", "echo ok"], { encoding: "utf8" });
    expect(r.stdout.trim()).toBe("ok");
  });
  test("spawnError for a missing executable in exec form (non-win32 path) / unspawnable shell", async () => {
    const r = await runHook({ event: "PreToolUse", command: "x", args: [], shell: "powershell" }, input, { cwd: path.join(os.tmpdir(), "definitely-not-a-dir-ccp") });
    expect(typeof r.spawnError).toBe("string");
    expect(interpret("PreToolUse", r).failed).toBe(true);
  });
});

describe("exec form (R11)", () => {
  winTest("RF1 exec form: semgrep's real extension-less CRLF scripts/hook under a space root", async () => {
    const src = semgrepScripts();
    const root = mkRoot();
    const dst = path.join(root, "scripts");
    fs.mkdirSync(dst);
    fs.copyFileSync(path.join(src, "hook"), path.join(dst, "hook"));
    if (fs.existsSync(path.join(src, "hook.exe"))) fs.copyFileSync(path.join(src, "hook.exe"), path.join(dst, "hook.exe"));
    const crlf = fs.readFileSync(path.join(dst, "hook"), "latin1").includes("\r\n");
    const r = await runHook({ event: "SessionStart", command: "${CLAUDE_PLUGIN_ROOT}/scripts/hook", args: ["claude", "SessionStatus"], pluginRoot: root, timeout: 60 }, { hook_event_name: "SessionStart", source: "startup" }, { cwd: os.tmpdir(), projectDir: os.tmpdir() });
    expect({ spawnError: r.spawnError, status: r.status, stderr: r.stderr.slice(0, 200), crlf }).toEqual({ spawnError: undefined, status: 0, stderr: r.stderr.slice(0, 200), crlf });
  });
  winTest("a .exe sibling wins over the extension-less script and is spawned directly", async () => {
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "exit7.sh"), path.join(root, "tool"));
    fs.copyFileSync(path.join(process.env.SystemRoot ?? "C:\\Windows", "System32", "hostname.exe"), path.join(root, "tool.exe"));
    const r = await runHook({ event: "PreToolUse", command: path.join(root, "tool").replace(/\\/g, "/"), args: [] }, input, { cwd: os.tmpdir() });
    expect(r.spawnError).toBeUndefined();
    expect(r.status).toBe(0);
    expect(r.stdout.trim().toLowerCase()).toBe(os.hostname().toLowerCase());
    expect(r.stdout).not.toContain("from-posix-script");
  });
  winTest("a .cmd sibling runs through cmd /c (space in path)", async () => {
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "exit7.sh"), path.join(root, "tool"));
    fs.copyFileSync(path.join(FIX, "ok.cmd"), path.join(root, "tool.cmd"));
    const r = await runHook({ event: "PreToolUse", command: path.join(root, "tool").replace(/\\/g, "/"), args: ["a b"] }, input, { cwd: os.tmpdir() });
    expect(r.spawnError).toBeUndefined();
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("from-cmd-sibling");
  });
  winTest("a .bat sibling runs through cmd /c", async () => {
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "exit7.sh"), path.join(root, "tool"));
    fs.copyFileSync(path.join(FIX, "ok.cmd"), path.join(root, "tool.bat"));
    const r = await runHook({ event: "PreToolUse", command: path.join(root, "tool").replace(/\\/g, "/"), args: [] }, input, { cwd: os.tmpdir() });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("from-cmd-sibling");
  });
  winTest("explicit .cmd command (with extension) goes through cmd /c", async () => {
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "ok.cmd"), path.join(root, "x.cmd"));
    const r = await runHook({ event: "PreToolUse", command: path.join(root, "x.cmd"), args: [] }, input, { cwd: os.tmpdir() });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("from-cmd-sibling");
  });
  winTest("no sibling: an extension-less script runs through Git Bash with [command, ...args]", async () => {
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "exit7.sh"), path.join(root, "tool"));
    const r = await runHook({ event: "PreToolUse", command: path.join(root, "tool").replace(/\\/g, "/"), args: [] }, input, { cwd: os.tmpdir() });
    expect(r.spawnError).toBeUndefined();
    expect(r.status).toBe(7);
    expect(r.stdout).toContain("from-posix-script");
  });
  test("${CLAUDE_PLUGIN_ROOT} is substituted in command and args, with forward slashes", () => {
    const p = plan({ command: "${CLAUDE_PLUGIN_ROOT}/x", args: ["--r=${CLAUDE_PLUGIN_ROOT}"], pluginRoot: "C:\\a b\\c" });
    const all = [p.file, ...p.args].join(" ");
    expect(all).toContain("C:/a b/c/x");
    expect(all).toContain("--r=C:/a b/c");
    expect(all).not.toContain("${CLAUDE_PLUGIN_ROOT}");
  });
});

describe("timeout, parallel, detached", () => {
  // Counts live sleep.exe processes whose REAL command line carries 37.421 (MSYS shape:
  // "...\usr\bin\sleep.exe" 37.421), found by image name + argument, never by the bash -c text.
  const PROBE = "(Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*37.421*' } | Measure-Object).Count";
  const sleepProcs = () => Number(spawnSync("powershell", ["-NoProfile", "-Command", PROBE], { encoding: "utf8" }).stdout.trim());
  const reap = () => spawnSync("powershell", ["-NoProfile", "-Command", "Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*37.421*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], { stdio: "ignore" });
  winTest("RF2: timeout kills the whole tree, including the MSYS grandchild", async () => {
    reap();
    expect(sleepProcs()).toBe(0);
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "sleeper.sh"), path.join(root, "sleeper.sh"));
    try {
      const run = runHook({ event: "PreToolUse", command: "sh \"" + path.join(root, "sleeper.sh").replace(/\\/g, "/") + "\"", timeout: 3 }, input, { cwd: os.tmpdir() });
      await new Promise((res) => setTimeout(res, 1500));
      expect(sleepProcs()).toBeGreaterThan(0); // positive control: the probe sees the grandchild while it lives
      const r = await run;
      expect(r.timedOut).toBe(true);
      expect(r.durationMs).toBeLessThan(5000);
      expect(interpret("PreToolUse", r).failed).toBe(true);
      await new Promise((res) => setTimeout(res, 500));
      expect(sleepProcs()).toBe(0);
    } finally {
      reap();
    }
  }, 30000);
  winTest("a detached hook past its timeout is killed with its tree and reported timedOut", async () => {
    reap();
    const root = mkRoot();
    fs.copyFileSync(path.join(FIX, "sleeper.sh"), path.join(root, "sleeper.sh"));
    try {
      let got;
      const r = await runHook({ event: "Stop", asyncRewake: true, command: "sh \"" + path.join(root, "sleeper.sh").replace(/\\/g, "/") + "\"", timeout: 2 }, input, { cwd: os.tmpdir(), onDetached: (x) => (got = x) });
      expect(r.detached).toBe(true);
      for (let i = 0; i < 80 && !got; i++) await new Promise((res) => setTimeout(res, 100));
      expect(got.timedOut).toBe(true);
      expect(got.failed).toBe(true);
      await new Promise((res) => setTimeout(res, 300));
      expect(sleepProcs()).toBe(0);
    } finally {
      reap();
    }
  }, 30000);
  test("timeoutFor: defaults, UPS 30, invalid values fall back, huge values clamp", () => {
    expect(timeoutFor({ event: "PreToolUse" })).toBe(600);
    expect(timeoutFor({ event: "UserPromptSubmit" })).toBe(30);
    expect(timeoutFor({ event: "Stop", timeout: 5 })).toBe(5);
    for (const bad of [0, -1, NaN, "x", null]) expect(timeoutFor({ event: "Stop", timeout: bad })).toBe(600);
    expect(timeoutFor({ event: "Stop", timeout: 1e12 }) * 1000).toBeLessThan(2 ** 31);
  });
  const T0 = 1000000000; // hook spawn time (ms) in the sweepSet fixtures
  const PSHEAD = "      PID    PPID    PGID     WINPID   TTY";
  test("sweepSet follows Windows parents, then MSYS process groups, and never selects self", () => {
    const win = ["100 1 " + (T0 + 5), "101 100 " + (T0 + 10), "201 101 " + (T0 + 20), "202 201 " + (T0 + 30), "300 7 " + (T0 + 40), process.pid + " 1 " + (T0 + 50)].join("\n");
    const ps = [
      PSHEAD,
      "      900       0       0        100  ?  0 t cmd",
      "      901       1     901        101  ?  0 t /usr/bin/bash",
      "      902     901     901        201  ?  0 t /usr/bin/sh",
      "      903     902     901        202  ?  0 t /usr/bin/sleep",
      "      950     1     950          300  ?  0 t /usr/bin/other",
      "      960       0       0   " + process.pid + "  ?  0 t self",
      "      961     901     901   " + process.pid + "  ?  0 t selfchild",
    ].join("\n");
    expect([...sweepSet(100, win, ps, T0)].sort()).toEqual([100, 101, 201, 202]);
  });
  test("C1: a stale-parent process (created before the hook, ParentProcessId == root's reused pid) is NOT in the set", () => {
    const win = ["100 1 " + (T0 + 5), "101 100 " + (T0 + 10), "777 100 " + (T0 - 600000), "778 777 " + (T0 - 599000)].join("\n");
    const set = sweepSet(100, win, PSHEAD, T0);
    expect([...set].sort()).toEqual([100, 101]);
    expect(set.has(777)).toBe(false);
    expect(set.has(778)).toBe(false);
  });
  test("C1: a pre-existing process sharing the hook's pgid is NOT in the set", () => {
    const win = ["100 1 " + (T0 + 5), "101 100 " + (T0 + 10), "205 1 " + (T0 + 20), "600 1 " + (T0 - 900000), "601 1 " + (T0 - 900000)].join("\n");
    const ps = [
      PSHEAD,
      "      901       1     901        101  ?  0 t /usr/bin/bash",
      "      902     901     901        205  ?  0 t /usr/bin/sleep",
      "      810       1     901        600  ?  0 t /usr/bin/old-group-member",
      "      811     810     901        601  ?  0 t /usr/bin/old-child-of-member",
    ].join("\n");
    const set = sweepSet(100, win, ps, T0);
    expect([...set].sort()).toEqual([100, 101, 205]);
  });
  test("C1: the skew allows a process created up to 1 s before the recorded spawn", () => {
    const win = ["100 1 " + (T0 - 500), "101 100 " + (T0 - 900)].join("\n");
    expect(sweepSet(100, win, PSHEAD, T0).has(101)).toBe(true);
    expect(sweepSet(100, "100 1 " + (T0 - 500) + "\n101 100 " + (T0 - 1100), PSHEAD, T0).has(101)).toBe(false);
  });

  test("a quick hook is not marked timed out", async () => {
    const r = await runHook({ event: "PreToolUse", command: "exit 0", timeout: 5 }, input, { cwd: os.tmpdir() });
    expect(r.timedOut).toBe(false);
    expect(r.status).toBe(0);
  });
  test("runAll runs hooks in parallel and keeps order", async () => {
    const e = (n) => ({ event: "PreToolUse", command: `sleep 1; echo ${n}` });
    const t0 = Date.now();
    const rs = await runAll([e(1), e(2), e(3)], input, { cwd: os.tmpdir() });
    expect(Date.now() - t0).toBeLessThan(2800);
    expect(rs.map((r) => r.stdout.trim())).toEqual(["1", "2", "3"]);
  }, 20000);
  test("runAll accepts a per-entry input function", async () => {
    const rs = await runAll([{ event: "A", command: "cat" }, { event: "B", command: "cat" }], (e) => ({ ev: e.event }), { cwd: os.tmpdir() });
    expect(rs[0].stdout).toContain('"ev":"A"');
    expect(rs[1].stdout).toContain('"ev":"B"');
  });
  test("asyncRewake and async return immediately, detached", async () => {
    for (const flag of ["asyncRewake", "async"]) {
      const r = await runHook({ event: "Stop", command: "sleep 3", [flag]: true }, input, { cwd: os.tmpdir() });
      expect(r.detached).toBe(true);
      expect(r.status).toBe(0);
      expect(r.durationMs).toBeLessThan(500);
    }
  });
  test("a default timeout of 30s applies to UserPromptSubmit, 600s otherwise (no premature kill)", async () => {
    const r = await runHook({ event: "UserPromptSubmit", command: "echo hi" }, input, { cwd: os.tmpdir() });
    expect(r.timedOut).toBe(false);
  });
});

describe("bare-name exec form (R25)", () => {
  winTest("a bare name resolves PATH x PATHEXT (.exe first), PATH passed explicitly", async () => {
    const dir = mkRoot("bin dir");
    fs.copyFileSync(path.join(process.env.SystemRoot ?? "C:\\Windows", "System32", "hostname.exe"), path.join(dir, "bareexe.exe"));
    const r = await runHook({ event: "PreToolUse", command: "bareexe", args: [] }, input, { cwd: os.tmpdir(), env: { PATH: dir + path.delimiter + (process.env.PATH ?? "") } });
    expect(r.spawnError).toBeUndefined();
    expect(r.status).toBe(0);
    expect(r.stdout.trim().toLowerCase()).toBe(os.hostname().toLowerCase());
  });
  winTest("a bare name resolving to a .cmd on PATH runs through cmd /c", async () => {
    const dir = mkRoot("bin dir");
    fs.copyFileSync(path.join(FIX, "ok.cmd"), path.join(dir, "barecmd.cmd"));
    const r = await runHook({ event: "PreToolUse", command: "barecmd", args: ["x y"] }, input, { cwd: os.tmpdir(), env: { PATH: dir } });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("from-cmd-sibling");
  });
  winTest("an unresolvable bare name is last-resort bash, not a crash", async () => {
    const r = await runHook({ event: "PreToolUse", command: "no-such-cmd-ccp", args: [] }, input, { cwd: os.tmpdir(), env: { PATH: "" } });
    expect(interpret("PreToolUse", r).failed).toBe(true);
  });
});

describe("detached outcome (R26)", () => {
  const detachedRun = async (entry, opts = {}) => {
    let got;
    const r = await runHook({ event: "Stop", async: true, ...entry }, input, { cwd: os.tmpdir(), onDetached: (x) => (got = x), ...opts });
    expect(r.detached).toBe(true);
    expect(r.status).toBe(0);
    for (let i = 0; i < 80 && !got; i++) await new Promise((res) => setTimeout(res, 50));
    return got;
  };
  test("a detached exit 1 is reported failed", async () => {
    const got = await detachedRun({ command: "exit 1" });
    expect(got.status).toBe(1);
    expect(got.failed).toBe(true);
  });
  test("a detached exit 0 is reported not failed", async () => {
    const got = await detachedRun({ command: "exit 0" });
    expect(got.status).toBe(0);
    expect(got.failed).toBe(false);
  });
  winTest("a detached missing .exe is reported failed with a spawnError", async () => {
    const got = await detachedRun({ command: path.join(os.tmpdir(), "definitely-missing-ccp.exe"), args: [] });
    expect(typeof got.spawnError).toBe("string");
    expect(got.failed).toBe(true);
  });
  test("without onDetached a failure is logged, not thrown", async () => {
    const prev = process.env.XDG_DATA_HOME;
    const data = mkRoot("xdg");
    process.env.XDG_DATA_HOME = data;
    try {
      const r = await runHook({ event: "Stop", async: true, id: "abc123", command: "exit 3" }, input, { cwd: os.tmpdir() });
      expect(r.detached).toBe(true);
      const logFile = path.join(data, "opencode", "cc-parity.log");
      let txt = "";
      for (let i = 0; i < 80 && !txt; i++) {
        await new Promise((res) => setTimeout(res, 50));
        try { txt = fs.readFileSync(logFile, "utf8"); } catch {}
      }
      expect(txt).toContain("detached hook failed: abc123");
    } finally {
      if (prev === undefined) delete process.env.XDG_DATA_HOME; else process.env.XDG_DATA_HOME = prev;
    }
  });
});

describe("PATHEXT, asyncRewake exit 2", () => {
  winTest("PATHEXT from the env decides which PATH match wins", async () => {
    const dir = mkRoot("bin dir");
    fs.copyFileSync(path.join(process.env.SystemRoot ?? "C:\\Windows", "System32", "hostname.exe"), path.join(dir, "twin.exe"));
    fs.copyFileSync(path.join(FIX, "ok.cmd"), path.join(dir, "twin.cmd"));
    const base = { cwd: os.tmpdir() };
    const cmdFirst = await runHook({ event: "PreToolUse", command: "twin", args: [] }, input, { ...base, env: { PATH: dir, PATHEXT: ".CMD;.EXE" } });
    expect(cmdFirst.stdout).toContain("from-cmd-sibling");
    const exeFirst = await runHook({ event: "PreToolUse", command: "twin", args: [] }, input, { ...base, env: { PATH: dir, PATHEXT: ".EXE;.CMD" } });
    expect(exeFirst.stdout.trim().toLowerCase()).toBe(os.hostname().toLowerCase());
  });
  test("an asyncRewake hook exiting 2 is the rewake signal, not a failure", async () => {
    let got;
    const r = await runHook({ event: "Stop", asyncRewake: true, command: "echo wake >&2; exit 2" }, input, { cwd: os.tmpdir(), onDetached: (x) => (got = x) });
    expect(r.detached).toBe(true);
    for (let i = 0; i < 80 && !got; i++) await new Promise((res) => setTimeout(res, 50));
    expect(got.status).toBe(2);
    expect(got.failed).toBe(false);
  });
});

describe("R28: root already exited", () => {
  const T0 = 1000000000;
  const E = T0 + 100; // root exit time
  const PSHEAD = "      PID    PPID    PGID     WINPID   TTY";
  test("(a) a stranger created after exitTime with ParentProcessId == root pid is excluded, with its children", () => {
    const win = ["300 100 " + (T0 + 5000), "301 300 " + (T0 + 5100)].join("\n");
    expect([...sweepSet(100, win, PSHEAD, T0, E)]).toEqual([]);
  });
  test("(b) a real child created before exitTime is included, and so is its own child", () => {
    const win = ["200 100 " + (T0 + 50), "201 200 " + (T0 + 60), "300 100 " + (T0 + 5000)].join("\n");
    expect([...sweepSet(100, win, PSHEAD, T0, E)].sort()).toEqual([200, 201]);
  });
  test("(c) the exited root pid is never in the kill list, even with a row of its own", () => {
    const win = ["100 1 " + (T0 + 5000), "200 100 " + (T0 + 50)].join("\n");
    const set = sweepSet(100, win, PSHEAD, T0, E);
    expect(set.has(100)).toBe(false);
    expect(set.has(200)).toBe(true);
    // contrast: while the root is alive it is included
    expect(sweepSet(100, win, PSHEAD, T0).has(100)).toBe(true);
  });
  // Minor 4 (final review): (c) cannot reach the R28 guard line, since the exited root never enters
  // `win` through the seed walk. These two put the reused root PID into `win` by the other routes.
  test("(d) the exited root's PID never survives, even when it arrives through a member's pgid row", () => {
    // 200 is a real member (the root's child, created before exit); a stranger took PID 100 later
    // and sits in 200's MSYS process group.
    const win = ["200 100 " + (T0 + 50), "100 1 " + (T0 + 5000)].join("\n");
    const ps = [PSHEAD, "      901       1     901        200  ?  0 t /usr/bin/bash", "      902       1     901        100  ?  0 t /usr/bin/sleep"].join("\n");
    expect([...sweepSet(100, win, ps, T0, E)]).toEqual([200]);
  });
  test("(e) the exited root's PID never survives, even when it arrives as a member's child", () => {
    // The stranger that took PID 100 names the member 200 as its parent and is younger than it.
    const win = ["200 100 " + (T0 + 50), "100 200 " + (T0 + 5000)].join("\n");
    expect([...sweepSet(100, win, PSHEAD, T0, E)]).toEqual([200]);
  });
  test("pgid rows qualify only through a verified member (a reused root's group is not swept)", () => {
    const win = ["100 1 " + (T0 + 5000), "205 1 " + (T0 + 5100)].join("\n");
    const ps = [PSHEAD, "      901       1     901        100  ?  0 t /usr/bin/bash", "      902     901     901        205  ?  0 t /usr/bin/sleep"].join("\n");
    expect([...sweepSet(100, win, ps, T0, E)]).toEqual([]);
  });
  winTest("live: an exited root leaves a stdout-holding child; the timeout kills that child and nothing else", async () => {
    const PROBE = "(Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*37.512*' } | Measure-Object).Count";
    const count = () => Number(spawnSync("powershell", ["-NoProfile", "-Command", PROBE], { encoding: "utf8" }).stdout.trim());
    const reap = () => spawnSync("powershell", ["-NoProfile", "-Command", "Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*37.512*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], { stdio: "ignore" });
    const bystander = spawn(findBash(), ["-c", "sleep 37.513"], { stdio: "ignore", windowsHide: true });
    try {
      reap();
      const usrBin = path.join(path.dirname(findBash()), "..", "usr", "bin");
      // cmd (the root) exits at once; "start /b" leaves sleep.exe as its direct child, holding stdout.
      const run = runHook({ event: "PreToolUse", command: "cmd", args: ["/c", "start /b sleep 37.512"], timeout: 2 }, input, { cwd: os.tmpdir(), env: { PATH: usrBin + path.delimiter + (process.env.PATH ?? "") } });
      await new Promise((res) => setTimeout(res, 1000));
      expect(count()).toBe(1); // positive control: the orphan lives and holds stdout
      const r = await run;
      expect(r.timedOut).toBe(true);
      await new Promise((res) => setTimeout(res, 400));
      expect(count()).toBe(0);
      const b = spawnSync("powershell", ["-NoProfile", "-Command", "(Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*37.513*' } | Measure-Object).Count"], { encoding: "utf8" });
      expect(Number(b.stdout.trim())).toBe(1); // the unrelated process is untouched
    } finally {
      reap();
      spawnSync("powershell", ["-NoProfile", "-Command", "Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*37.513*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], { stdio: "ignore" });
      try { bystander.kill(); } catch {}
    }
  }, 30000);
});

describe("R29: kill-set age check, exit read after the snapshot, exitMs wiring", () => {
  const T0 = 1000000000;
  const PSHEAD = "      PID    PPID    PGID     WINPID   TTY";
  // 200 is a hook member (created T0+500) that took over the PID of a dead parent. 300 is a
  // stranger created after the hook started (T0+200) that still names that dead parent: it is
  // OLDER than 200, so it cannot be 200's child. 201 and 202 are 200's real children (202 shares
  // 200's creation ms: equal qualifies). 301 is the stranger's own child.
  const win = (root) => [root, "200 100 " + (T0 + 500), "300 200 " + (T0 + 200), "301 300 " + (T0 + 700), "201 200 " + (T0 + 600), "202 200 " + (T0 + 500)].join("\n");
  test("alive root: a stranger older than its pid-reused parent is excluded, with its child", () => {
    expect([...sweepSet(100, win("100 1 " + (T0 + 5)), PSHEAD, T0)].sort()).toEqual([100, 200, 201, 202]);
  });
  test("exited root: the same stranger under a verified direct child is excluded", () => {
    expect([...sweepSet(100, win("999 1 " + T0), PSHEAD, T0, T0 + 1000)].sort()).toEqual([200, 201, 202]);
  });

  // Pid-scoped helpers: find our own marker processes and kill them by PID only.
  const markerPids = (m) => spawnSync("powershell", ["-NoProfile", "-Command", `Get-CimInstance Win32_Process -Filter "Name='sleep.exe'" | Where-Object { $_.CommandLine -like '*${m}*' } | ForEach-Object { $_.ProcessId }`], { encoding: "utf8" }).stdout.split(/\s+/).filter(Boolean).map(Number);
  const reapPids = (pids) => pids.length && spawnSync("taskkill", ["/F", ...pids.flatMap((p) => ["/PID", String(p)])], { stdio: "ignore" });
  const usrBin = () => path.join(path.dirname(findBash()), "..", "usr", "bin");

  winTest("runHook passes the root's exit to killTree: kill list non-empty, exited root pid absent", async () => {
    const M = "41.263";
    reapPids(markerPids(M));
    let got;
    try {
      const r = await runHook({ event: "PreToolUse", command: "cmd", args: ["/c", `start /b sleep ${M}`], timeout: 1 }, input, { cwd: os.tmpdir(), env: { PATH: usrBin() + path.delimiter + (process.env.PATH ?? "") }, onKill: (v, root) => (got = { v, root }) });
      expect(r.timedOut).toBe(true);
      expect(got.root).toBeGreaterThan(0);
      expect(got.v.length).toBeGreaterThan(0); // positive control: the stdout-holding sleep was found
      expect(got.v).not.toContain(got.root);
    } finally {
      await new Promise((res) => setTimeout(res, 300));
      reapPids(markerPids(M));
    }
  }, 30000);

  winTest("killTree reads the exit time after its snapshot: a root that exits during it is treated as exited", async () => {
    const sleepExe = path.join(usrBin(), "sleep.exe");
    const run = async (M, flip) => {
      const child = spawn(sleepExe, [M], { stdio: "ignore", windowsHide: true });
      await new Promise((res) => child.once("spawn", res));
      let exitVal = null;
      let got;
      try {
        // killTree runs synchronously up to its snapshot await; setting exitVal right after the
        // call means only a read AFTER the snapshot can see it.
        const p = killTree(child, Date.now() - 100, () => exitVal, (v, root) => (got = { v, root }));
        if (flip) exitVal = Date.now();
        await p;
        return { got, pid: child.pid };
      } finally {
        try { child.kill(); } catch {}
        reapPids(markerPids(M));
      }
    };
    const control = await run("41.381", false); // never exited: the root IS in the list (the probe can see it)
    expect(control.got.root).toBe(control.pid);
    expect(control.got.v).toContain(control.pid);
    const late = await run("41.379", true); // exits while the snapshot runs
    expect(late.got.root).toBe(late.pid);
    expect(late.got.v).not.toContain(late.pid);
  }, 30000);
});

// Minor 10 (final review): powershell and taskkill by absolute %SystemRoot%\System32 path, never a
// bare name that a cwd-first lookup could resolve to a planted file.
describe("Windows system tools by absolute path (Minor 10)", () => {
  test("sysExe joins under SystemRoot\\System32; with no SystemRoot/windir it falls back to the bare name", () => {
    const saved = { SystemRoot: process.env.SystemRoot, windir: process.env.windir };
    try {
      process.env.SystemRoot = path.join(os.tmpdir(), "fake-sysroot");
      expect(sysExe("taskkill.exe")).toBe(path.join(os.tmpdir(), "fake-sysroot", "System32", "taskkill.exe"));
      delete process.env.SystemRoot;
      delete process.env.windir;
      expect(sysExe("taskkill.exe")).toBe("taskkill.exe");
    } finally {
      for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });
  winTest("on this machine both tools resolve to existing absolute files", () => {
    for (const p of [WIN_TOOLS.powershell(), WIN_TOOLS.taskkill()]) {
      expect(path.isAbsolute(p)).toBe(true);
      expect(fs.existsSync(p)).toBe(true);
    }
  });
  test("runner.js never spawns powershell or taskkill by bare name", () => {
    const src = fs.readFileSync(path.join(import.meta.dir, "..", "core", "runner.js"), "utf8");
    expect(src).not.toMatch(/capture\(\s*["'](powershell|taskkill)/);
    expect(src).toMatch(/capture\(\s*WIN_TOOLS\.powershell\(\)/); // positive control: the call sites exist
    expect(src).toMatch(/capture\(\s*WIN_TOOLS\.taskkill\(\)/);
  });
});
