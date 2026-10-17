// 0.12.1 D4: OC fires `event` without awaiting it (plugin/index.ts: `void hook["event"]?.(...)`), but
// awaits `dispose` on shutdown (effect-cmd.ts `finally { await store.dispose(ctx) }` -> runDisposers
// -> the plugin scope finalizer `Promise.resolve(hook.dispose?.())`, before index.ts's process.exit).
// So a synchronous Stop hook still running at exit must be awaited in dispose, or its failure is
// never logged, counted or reported. R53: detached (async) hooks are NOT awaited; as CC's teardown
// does (Qis), dispose kills them and they are not counted.
import { describe, test, expect, afterEach } from "bun:test";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { makeCcHome } from "./helpers.js";
import { createV1 } from "../v1/plugin.js";
import { stateStore } from "../core/state.js";

const cleanups = [];
afterEach(() => {
  while (cleanups.length) cleanups.pop()();
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function harness({ hooks, runHook, clientDelayMs = 0, exitGraceMs, lookupNever = false } = {}) {
  const h = makeCcHome({ hooks });
  cleanups.push(h.cleanup);
  const stateFile = path.join(h.home, "scratch", "state.json");
  const logs = [];
  let onExit;
  const client = {
    session: {
      get: async ({ path: { id } }) => {
        if (lookupNever) await new Promise(() => {}); // a Stop run that stalls before its hooks run
        if (clientDelayMs) await sleep(clientDelayMs);
        return { data: { id, ...(id === "ses_child" ? { parentID: "ses_top" } : {}) } };
      },
    },
  };
  const make = () =>
    createV1(
      { client, directory: h.projectDir, worktree: h.projectDir },
      {
        home: h.home,
        env: {},
        stateFile,
        runHook,
        log: (m) => logs.push(String(m)),
        ccVersion: () => null,
        ocVersion: () => "1.19.0",
        fetchChangelog: async () => null,
        onExit: (fn) => (onExit = fn),
        flushMs: 5,
        ...(exitGraceMs !== undefined ? { exitGraceMs } : {}),
      },
    );
  return { h, logs, make, disk: () => stateStore(stateFile), exit: () => onExit?.() };
}
const idle = (sessionID) => ({ event: { type: "session.idle", properties: { sessionID } } });
const STOP = (extra = {}) => ({ Stop: [{ hooks: [{ type: "command", command: "stop-hook", ...extra }] }] });
const failedLines = (logs) => logs.filter((l) => /hook failed: \S+ \(Stop\)/.test(l));

describe("D4: hooks in flight at exit are awaited by dispose", () => {
  test("a failing Stop hook still running when dispose starts is logged and counted before dispose resolves", async () => {
    const runHook = async (e) => {
      await sleep(300);
      return { status: 1, stdout: "", stderr: "stop-broke", timedOut: false };
    };
    const H = harness({ hooks: STOP(), runHook });
    const v1 = await H.make();
    void v1.event(idle("ses_top")); // as OC does: not awaited
    await v1.dispose();
    expect(failedLines(H.logs).length).toBe(1);
    expect(failedLines(H.logs)[0]).toContain("exit 1: stop-broke");
    const f = H.disk().failures.list();
    expect(f.length).toBe(1);
    expect(f[0].msg).toContain("stop-broke");
  });
  test("tracked from the event's first line: dispose waits even while the session lookup is still pending", async () => {
    const runHook = async () => ({ status: 3, stdout: "", stderr: "", timedOut: false });
    const H = harness({ hooks: STOP(), runHook, clientDelayMs: 200 });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    await v1.dispose();
    expect(failedLines(H.logs).length).toBe(1);
    expect(H.disk().failures.list().length).toBe(1);
  });
  // R53.1: CC's teardown (Qis) kills async hooks still running and records them "cancelled", not
  // failed. A fake detached run that would only fail 30 s later, with a cancel() like the runner's.
  const detachedFake = (calls) => async (e, input, opts) => {
    let timer = setTimeout(() => opts.onDetached({ status: 1, stdout: "", stderr: "late", timedOut: false, detached: true, failed: true }), 30000);
    const cancel = async () => {
      calls.push(e.command);
      if (!timer) return;
      clearTimeout(timer);
      timer = null;
      opts.onDetached({ status: null, stdout: "", stderr: "", timedOut: false, cancelled: true, detached: true, failed: false });
    };
    return { status: 0, stdout: "", stderr: "", timedOut: false, detached: true, cancel };
  };
  test("R53.1: a detached hook (an async Stop hook) is NOT awaited: dispose cancels it at once and does not count it", async () => {
    const calls = [];
    const H = harness({ hooks: STOP({ async: true }), runHook: detachedFake(calls) });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    const t0 = Date.now();
    await v1.dispose();
    expect(Date.now() - t0).toBeLessThan(1000);
    expect(calls).toEqual(["stop-hook"]);
    expect(H.logs.some((l) => /detached hook failed/.test(l))).toBe(false);
    expect(H.disk().failures.list().length).toBe(0);
  });
  test("R53.1: a detached hook started outside Stop (an async PostToolUse hook) is cancelled the same way", async () => {
    const calls = [];
    const H = harness({ hooks: { PostToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "post-async", async: true }] }] }, runHook: detachedFake(calls) });
    const v1 = await H.make();
    await v1["tool.execute.after"]({ tool: "bash", sessionID: "ses_top", callID: "c1", args: { command: "ls" } }, { output: "x" });
    await v1.dispose();
    expect(calls).toEqual(["post-async"]);
    expect(H.disk().failures.list().length).toBe(0);
  });
  test("R53.1 mixed: the sync Stop hook is awaited and counted, the detached one beside it is cancelled and not", async () => {
    const calls = [];
    const fake = detachedFake(calls);
    const runHook = async (e, input, opts) => {
      if (e.async) return fake(e, input, opts);
      await sleep(300);
      return { status: 1, stdout: "", stderr: "sync-broke", timedOut: false };
    };
    const hooks = { Stop: [{ hooks: [{ type: "command", command: "stop-sync" }, { type: "command", command: "stop-async", async: true }] }] };
    const H = harness({ hooks, runHook });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    await v1.dispose();
    expect(failedLines(H.logs).length).toBe(1);
    expect(failedLines(H.logs)[0]).toContain("sync-broke");
    expect(calls).toEqual(["stop-async"]);
    const f = H.disk().failures.list();
    expect(f.length).toBe(1);
    expect(f[0].msg).toContain("sync-broke");
  });
  test("a successful in-flight Stop hook is awaited and leaves no failure", async () => {
    let ran = false;
    const runHook = async () => {
      await sleep(200);
      ran = true;
      return { status: 0, stdout: "", stderr: "", timedOut: false };
    };
    const H = harness({ hooks: STOP(), runHook });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    await v1.dispose();
    expect(ran).toBe(true);
    expect(H.disk().failures.list().length).toBe(0);
  });
  test("bounded by the hook's own timeout: a run that never settles is given up at timeout + grace, logged and counted", async () => {
    const runHook = () => new Promise(() => {}); // never settles
    const H = harness({ hooks: STOP({ timeout: 1 }), runHook, exitGraceMs: 200 });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    const t0 = Date.now();
    await v1.dispose();
    const took = Date.now() - t0;
    expect(took).toBeGreaterThanOrEqual(1000);
    expect(took).toBeLessThan(3000);
    expect(H.logs.some((l) => /still running at exit/.test(l))).toBe(true);
    expect(H.disk().failures.list().length).toBe(1);
  });
  test("nothing in flight: dispose does not wait, and a child session's idle runs no Stop hook", async () => {
    let n = 0;
    const runHook = async () => {
      n++;
      await sleep(2000);
      return { status: 1, stdout: "", stderr: "", timedOut: false };
    };
    const H = harness({ hooks: STOP(), runHook });
    const v1 = await H.make();
    await v1.event(idle("ses_child"));
    const t0 = Date.now();
    await v1.dispose();
    expect(Date.now() - t0).toBeLessThan(500);
    expect(n).toBe(0);
  });
  test("a hard exit before dispose finishes: the exit handler records each in-flight hook synchronously", async () => {
    const runHook = () => new Promise(() => {});
    const H = harness({ hooks: STOP(), runHook });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    await sleep(50);
    H.exit(); // process "exit": synchronous only
    expect(H.logs.some((l) => /pending at exit/.test(l))).toBe(true);
    const f = H.disk().failures.list();
    expect(f.length).toBe(1);
    expect(f[0].msg).toContain("pending at exit");
  });
  test("R53.1: at a hard exit a detached hook still running is not recorded (Stop only)", async () => {
    const H = harness({ hooks: { PostToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "post-async", async: true }] }] }, runHook: detachedFake([]) });
    const v1 = await H.make();
    await v1["tool.execute.after"]({ tool: "bash", sessionID: "ses_top", callID: "c1", args: { command: "ls" } }, { output: "x" });
    H.exit();
    expect(H.logs.some((l) => /pending at exit/.test(l))).toBe(false);
    expect(H.disk().failures.list().length).toBe(0);
  });

  // R54 I-1 (the reviewer's S3 probe as a test): a Stop run that stalls before its hooks run (the
  // session lookup never settles) is bounded and counted by its SYNC hooks only. An async Stop hook's
  // timeout must neither stretch the wait nor be counted (R53.1: detached hooks are never failures).
  const MIXED = { Stop: [{ hooks: [{ type: "command", command: "stop-sync", timeout: 1 }, { type: "command", command: "stop-async", async: true, timeout: 6 }] }] };
  const never = () => new Promise(() => {});
  test("R54 I-1: a stalled run waits for the sync hook's timeout + grace (not the async one's) and counts only the sync hook", async () => {
    const H = harness({ hooks: MIXED, runHook: never, lookupNever: true, exitGraceMs: 200 });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    const t0 = Date.now();
    await v1.dispose();
    const took = Date.now() - t0;
    expect(took).toBeGreaterThanOrEqual(1000);
    expect(took).toBeLessThan(2500); // the full-list deadline would be 6 s + grace
    const f = H.disk().failures.list();
    expect(f.length).toBe(1);
    const late = H.logs.filter((l) => /still running at exit/.test(l));
    expect(late.length).toBe(1);
    expect(late[0].match(/\(Stop\)/g).length).toBe(1); // one id named, the sync hook's
  });
  test("R54 I-1: at a hard exit the same stalled run records only the sync hook", async () => {
    const H = harness({ hooks: MIXED, runHook: never, lookupNever: true });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    await sleep(50);
    H.exit();
    expect(H.disk().failures.list().length).toBe(1);
    const pend = H.logs.filter((l) => /pending at exit/.test(l));
    expect(pend.length).toBe(1);
    expect(pend[0].match(/\(Stop\)/g).length).toBe(1);
  });
  test("R54 I-1: a run with only async Stop hooks is still tracked (grace deadline), so its hooks get spawned before the cancel step; nothing counted", async () => {
    const H = harness({ hooks: STOP({ async: true }), runHook: never, lookupNever: true, exitGraceMs: 300 });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    const t0 = Date.now();
    await v1.dispose();
    const took = Date.now() - t0;
    expect(took).toBeGreaterThanOrEqual(300); // waited for the run: it was tracked
    expect(took).toBeLessThan(1500);
    expect(H.disk().failures.list().length).toBe(0);
    H.exit();
    expect(H.disk().failures.list().length).toBe(0);
  });
  test("R54 m-1 (RM3): a late Stop run counted by dispose is not counted again by the exit handler", async () => {
    const H = harness({ hooks: STOP({ timeout: 1 }), runHook: never, exitGraceMs: 200 });
    const v1 = await H.make();
    void v1.event(idle("ses_top"));
    await v1.dispose();
    expect(H.disk().failures.list().length).toBe(1);
    H.exit();
    expect(H.disk().failures.list().length).toBe(1);
    expect(H.logs.some((l) => /pending at exit/.test(l))).toBe(false);
  });
  test("R54 m-6: an async SessionEnd hook started during dispose is cancelled too, not left running, not counted", async () => {
    const calls = [];
    const fake = detachedFake(calls);
    const runHook = async (e, input, opts) => (e.async ? fake(e, input, opts) : { status: 0, stdout: "", stderr: "", timedOut: false });
    const H = harness({ hooks: { SessionEnd: [{ hooks: [{ type: "command", command: "end-async", async: true }] }] }, runHook });
    const v1 = await H.make();
    await v1["chat.message"]({ sessionID: "ses_top" }, { message: { id: "msg_1" }, parts: [{ type: "text", text: "hi" }] });
    await v1.dispose();
    expect(calls).toEqual(["end-async"]);
    expect(H.disk().failures.list().length).toBe(0);
  });
});

// R53.1 with the REAL runner: a configured async PostToolUse hook sleeping ~30 s is still running
// when dispose starts; dispose must return within a small bound, kill it, and not count it.
describe("R53.1 real runner", () => {
  const WIN = process.platform === "win32";
  const PROBE = "(Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*29.613*' } | Measure-Object).Count";
  const sleepProcs = () => Number(spawnSync("powershell", ["-NoProfile", "-Command", PROBE], { encoding: "utf8" }).stdout.trim());
  const reap = () => spawnSync("powershell", ["-NoProfile", "-Command", "Get-CimInstance Win32_Process -Filter \"Name='sleep.exe'\" | Where-Object { $_.CommandLine -like '*29.613*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], { stdio: "ignore" });
  test("a detached hook sleeping 30 s: dispose < 10 s, the hook is killed, nothing counted", async () => {
    if (WIN) reap();
    try {
      const hooks = { PostToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "sleep 29.613", async: true }] }] };
      const H = harness({ hooks }); // no runHook: the real core runner
      const v1 = await H.make();
      await v1["tool.execute.after"]({ tool: "bash", sessionID: "ses_top", callID: "c1", args: { command: "ls" } }, { output: "x" });
      await sleep(1500);
      if (WIN) expect(sleepProcs()).toBeGreaterThan(0); // positive control: it is running
      const t0 = Date.now();
      await v1.dispose();
      expect(Date.now() - t0).toBeLessThan(10000);
      await sleep(500);
      if (WIN) expect(sleepProcs()).toBe(0);
      expect(H.logs.some((l) => /detached hook failed/.test(l))).toBe(false);
      expect(H.disk().failures.list().length).toBe(0);
    } finally {
      if (WIN) reap();
    }
  }, 40000);
});
