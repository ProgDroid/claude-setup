// 0.12.1 D2 (a `~/...sh` hook under a home with a space) and D3 (a hook that declares itself async
// on its first stdout line). Real Git Bash spawns, synthetic homes only (a temp dir named "x y").
import { afterAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { ccWinShellForm, plan, runHook, findBash } from "../core/runner.js";

const WIN = process.platform === "win32";
const winTest = WIN ? test : test.skip;
const tmps = [];
afterAll(() => tmps.forEach((d) => fs.rmSync(d, { recursive: true, force: true })));

// A synthetic home whose path contains a space, with hooks/h.sh and hooks/noext in it.
function spacedHome() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-d2-"));
  tmps.push(base);
  const home = path.join(base, "x y");
  fs.mkdirSync(path.join(home, "hooks"), { recursive: true });
  // Reads stdin, so the test also proves the hook input still arrives through the bash prefix.
  fs.writeFileSync(path.join(home, "hooks", "h.sh"), '#!/usr/bin/env bash\nin=$(cat)\necho "HOOK-RAN $in"\n');
  fs.writeFileSync(path.join(home, "hooks", "noext"), "#!/usr/bin/env bash\necho NOEXT-RAN\n");
  return { home, env: { HOME: home, USERPROFILE: home } };
}
const input = { hook_event_name: "PostToolUse", tool_name: "Edit" };

describe("D2: ccWinShellForm is a port of CC 2.1.300's k3n", () => {
  test("a first token ending in .sh gets `bash ` in front; the original string is kept as is", () => {
    expect(ccWinShellForm("~/.claude/hooks/x.sh")).toBe("bash ~/.claude/hooks/x.sh");
    expect(ccWinShellForm("~/.claude/hooks/x.sh --flag a")).toBe("bash ~/.claude/hooks/x.sh --flag a");
    expect(ccWinShellForm('"C:/a b/x.sh" arg')).toBe('bash "C:/a b/x.sh" arg');
    expect(ccWinShellForm("'q d/x.sh'")).toBe("bash 'q d/x.sh'");
    expect(ccWinShellForm("a\\ b.sh")).toBe("bash a\\ b.sh"); // backslash escape joins the token
    expect(ccWinShellForm('"unterminated.sh')).toBe('bash "unterminated.sh'); // CC takes the rest
    expect(ccWinShellForm("  ~/x.sh  ")).toBe("bash   ~/x.sh  "); // trimmed only for the scan
  });
  test("anything else is returned unchanged", () => {
    for (const c of ["~/bin/noext", "x.SH", "echo a.sh", "bash ~/x.sh", "x.sh.bak", "", "VAR=1 ~/x.sh", "x.shx"]) expect(ccWinShellForm(c)).toBe(c);
  });
  winTest("plan(): shell form on Windows gets the prefix; powershell, exec form and other commands do not", () => {
    expect(plan({ command: "~/.claude/hooks/x.sh" }).args).toEqual(["-c", "bash ~/.claude/hooks/x.sh"]);
    expect(plan({ command: "echo plain" }).args).toEqual(["-c", "echo plain"]);
    expect(plan({ command: "~/bin/noext" }).args).toEqual(["-c", "~/bin/noext"]);
    expect(plan({ command: "~/x.sh", shell: "powershell" }).args).toEqual(["-NoProfile", "-Command", "~/x.sh"]);
    const root = path.join(os.tmpdir(), "p r");
    expect(plan({ command: '"${CLAUDE_PLUGIN_ROOT}/h.sh"', pluginRoot: root }).args).toEqual(["-c", `bash "${root.replace(/\\/g, "/")}/h.sh"`]);
    // exec form is untouched: its own planning (R11/R25) applies
    expect(plan({ command: "x.sh", args: ["a"] }).args).not.toContain("bash x.sh");
  });
});

describe("D2: a real Git Bash spawn under a home with a space", () => {
  test("`~/hooks/h.sh` runs (it died with 126/127 before) and still gets its stdin", async () => {
    const { env } = spacedHome();
    const r = await runHook({ event: "PostToolUse", command: "~/hooks/h.sh" }, input, { cwd: os.tmpdir(), env });
    expect(r.stderr).toBe("");
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("HOOK-RAN");
    expect(r.stdout).toContain('"tool_name":"Edit"');
  });
  test("control: a command with no `~` is unaffected, and bash expands `~` itself to the spaced home", async () => {
    const { env, home } = spacedHome();
    const plain = await runHook({ event: "PostToolUse", command: "echo plain" }, input, { cwd: os.tmpdir(), env });
    expect(plain.status).toBe(0);
    expect(plain.stdout.trim()).toBe("plain");
    // `cd ~` lands in the "x y" dir as ONE word: proof the home seen by the hook is the synthetic one
    const where = await runHook({ event: "PostToolUse", command: 'cd ~ && basename "$PWD"' }, input, { cwd: os.tmpdir(), env });
    expect(where.status).toBe(0);
    expect(where.stdout.trim()).toBe(path.basename(home));
  });
  winTest("positive control for the probe: without the prefix, MSYS splits the expanded home and the hook dies", () => {
    const { env } = spacedHome();
    const r = spawnSync(findBash(), ["-c", "~/hooks/h.sh"], { env: { ...process.env, ...env }, encoding: "utf8", input: "{}" });
    expect([126, 127]).toContain(r.status);
    expect(r.stderr).toMatch(/x: (No such file or directory|Is a directory)/);
  });
  winTest("shared with CC: a `~/` command whose first token is not .sh still fails (CC's k3n leaves it alone too)", async () => {
    const { env } = spacedHome();
    const r = await runHook({ event: "PostToolUse", command: "~/hooks/noext" }, input, { cwd: os.tmpdir(), env });
    expect(r.status).not.toBe(0);
  });
});

// ---- D3 -------------------------------------------------------------------------------------
const waitFor = async (get, ms) => {
  for (let t = 0; t < ms && !get(); t += 50) await new Promise((res) => setTimeout(res, 50));
  return get();
};

describe("D3: a hook whose first stdout line is {\"async\":true} is detached after that line", () => {
  test("async line, then 5 s of work, then exit 1: the call returns at once; the later failure is reported as detached", async () => {
    let got;
    const t0 = Date.now();
    const r = await runHook(
      { event: "SessionStart", command: "printf '{\"async\":true}\\n{\"x\":1}\\n'; sleep 5; echo late-err >&2; exit 1" },
      input,
      { cwd: os.tmpdir(), onDetached: (d) => (got = d) },
    );
    const took = Date.now() - t0;
    expect(took).toBeLessThan(2000);
    expect(r.detached).toBe(true);
    expect(r.status).toBe(0);
    expect(r.stdout).toBe(""); // never interpreted as the hook's answer (no "malformed JSON")
    expect(got).toBeUndefined(); // still running
    await waitFor(() => got, 12000);
    expect(got.status).toBe(1);
    expect(got.failed).toBe(true);
    expect(got.detached).toBe(true);
    expect(got.stderr).toContain("late-err");
    expect(got.stdout).not.toContain('"async"'); // the async line is not part of the later answer
  }, 20000);
  test("a detached exit 0 is not a failure", async () => {
    let got;
    const r = await runHook({ event: "SessionStart", command: "echo '{\"async\": true}'; sleep 1; echo '{\"x\":1}'" }, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d) });
    expect(r.detached).toBe(true);
    await waitFor(() => got, 8000);
    expect(got.status).toBe(0);
    expect(got.failed).toBe(false);
  }, 15000);
  test("the async line split across writes is still recognised (CC waits for a `}` in the first line)", async () => {
    let got;
    const t0 = Date.now();
    const r = await runHook({ event: "PostToolUse", command: "printf '{\"asy'; sleep 0.5; printf 'nc\":true}\\n'; sleep 4" }, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d) });
    expect(Date.now() - t0).toBeLessThan(2500);
    expect(r.detached).toBe(true);
    await waitFor(() => got, 10000);
    expect(got.status).toBe(0);
  }, 15000);
  test("after detaching, output is still drained: 300 KB after the async line does not block the hook", async () => {
    let got;
    const r = await runHook({ event: "PostToolUse", command: "echo '{\"async\":true}'; head -c 300000 /dev/zero | tr '\\0' a; echo; exit 0", timeout: 20 }, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d) });
    expect(r.detached).toBe(true);
    await waitFor(() => got, 15000);
    expect(got.timedOut).toBe(false);
    expect(got.status).toBe(0);
  }, 25000);
  test("R53.3: once the async line arrives its timeout is cleared, as CC does; asyncTimeout is not a timer either", async () => {
    let got;
    // R53.3: timeout 1 s, but the hook goes async and runs 2.5 s: CC's background() clears the
    // timeout (`this.#C()` -> clearTimeout), so it is not killed. asyncTimeout is no timer either.
    const r = await runHook({ event: "PostToolUse", command: "echo '{\"async\":true,\"asyncTimeout\":300}'; sleep 2.5; exit 0", timeout: 1 }, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d) });
    expect(r.detached).toBe(true);
    await waitFor(() => got, 10000);
    expect(got.timedOut).toBe(false);
    expect(got.status).toBe(0);
    expect(got.failed).toBe(false);
  }, 20000);
  test("R53.3 control: a CONFIGURED async hook (async: true) keeps its R26 timeout and failure", async () => {
    let got;
    const r = await runHook({ event: "PostToolUse", async: true, command: "sleep 30", timeout: 1 }, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d) });
    expect(r.detached).toBe(true);
    await waitFor(() => got, 15000);
    expect(got.timedOut).toBe(true);
    expect(got.failed).toBe(true);
  }, 30000);
  // R53.1: cancel() is how dispose ends a detached hook: the R23/R27-R29 tree kill, reported as
  // cancelled, never as a failure (CC's Qis(): kill, outcome "cancelled").
  const PROBE = "(Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*41.733*' } | Measure-Object).Count";
  const sleepProcs = () => Number(spawnSync("powershell", ["-NoProfile", "-Command", PROBE], { encoding: "utf8" }).stdout.trim());
  const reap = () => spawnSync("powershell", ["-NoProfile", "-Command", "Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*41.733*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], { stdio: "ignore" });
  for (const [label, entry] of [
    ["a first-line-async hook", { event: "PostToolUse", command: "echo '{\"async\":true}'; sleep 41.733" }],
    ["a configured async hook", { event: "Stop", async: true, command: "sleep 41.733" }],
  ]) {
    test(`cancel() on ${label}: tree killed, reported cancelled, not failed`, async () => {
      if (WIN) reap();
      try {
        let got;
        const r = await runHook(entry, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d) });
        expect(r.detached).toBe(true);
        expect(typeof r.cancel).toBe("function");
        await new Promise((res) => setTimeout(res, 1500));
        if (WIN) expect(sleepProcs()).toBeGreaterThan(0); // positive control: the probe sees the grandchild
        expect(got).toBeUndefined();
        const t0 = Date.now();
        await r.cancel();
        expect(Date.now() - t0).toBeLessThan(10000);
        await waitFor(() => got, 5000);
        expect(got.cancelled).toBe(true);
        expect(got.failed).toBe(false);
        await new Promise((res) => setTimeout(res, 500));
        if (WIN) expect(sleepProcs()).toBe(0);
        await r.cancel(); // idempotent
      } finally {
        if (WIN) reap();
      }
    }, 30000);
  }
  // R54 m-1 (RM1): CC's Qis keeps a completed hook's real outcome and kills only what still runs.
  // On Windows killTree reports its victims through onKill (on POSIX it returns before calling it).
  winTest("R54 m-1: cancel() on a configured async hook that already exited kills nothing and keeps its real outcome", async () => {
    let got;
    let kills = 0;
    const r = await runHook({ event: "Stop", async: true, command: "exit 0" }, input, { cwd: os.tmpdir(), onDetached: (d) => (got = d), onKill: () => kills++ });
    expect(r.detached).toBe(true);
    await waitFor(() => got, 8000);
    expect(got.status).toBe(0);
    await r.cancel();
    expect(kills).toBe(0);
    expect(got.cancelled).toBeUndefined();
    // positive control: the same observer DOES see a kill when the hook is still running
    let got2;
    const r2 = await runHook({ event: "Stop", async: true, command: "sleep 5" }, input, { cwd: os.tmpdir(), onDetached: (d) => (got2 = d), onKill: () => kills++ });
    await new Promise((res) => setTimeout(res, 300));
    await r2.cancel();
    expect(kills).toBe(1);
    await waitFor(() => got2, 5000);
    expect(got2.cancelled).toBe(true);
  }, 30000);
  test("controls: these first lines are NOT async, and the hook runs synchronously as before", async () => {
    const cases = [
      ['echo \'{"async":false}\'; sleep 1', '{"async":false}'],
      ["echo '{\"x\":1}'; sleep 1", '{"x":1}'],
      ["echo 'plain text'; echo '{\"async\":true}'; sleep 1", "plain text"], // async on line 2: CC reads line 1 only
      ["echo '{\"async\":\"true\"}'; sleep 1", '{"async":"true"}'], // CC: async === true, not truthy
      ["echo '{not json}'; sleep 1", "{not json}"],
    ];
    for (const [command, first] of cases) {
      const t0 = Date.now();
      const r = await runHook({ event: "SessionStart", command }, input, { cwd: os.tmpdir() });
      expect(r.detached).toBeUndefined();
      expect(Date.now() - t0).toBeGreaterThanOrEqual(900);
      expect(r.stdout.split(/\r?\n/)[0]).toBe(first);
    }
  }, 30000);
});
