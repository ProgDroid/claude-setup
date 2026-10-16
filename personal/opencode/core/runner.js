import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { interpret } from "./protocol.js";
import { log } from "./log.js";

const WIN = process.platform === "win32";

// Minor 10: Windows system tools by absolute path under %SystemRoot%\System32 (windir as the
// fallback), never a bare name that a cwd-first lookup could resolve to a planted file. Read per
// call. With neither variable set, the bare name, as before.
export function sysExe(...rel) {
  const root = process.env.SystemRoot || process.env.windir;
  return root ? path.join(root, "System32", ...rel) : rel[rel.length - 1];
}
export const WIN_TOOLS = {
  powershell: () => sysExe("WindowsPowerShell", "v1.0", "powershell.exe"),
  taskkill: () => sysExe("taskkill.exe"),
};

export function findBash() {
  if (!WIN) return "bash";
  const roots = [process.env.ProgramFiles, process.env["ProgramFiles(x86)"], process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, "Programs")].filter(Boolean);
  for (const r of roots) {
    const p = path.join(r, "Git", "bin", "bash.exe");
    if (fs.existsSync(p)) return p;
  }
  return "bash";
}

const fwd = (p) => String(p).replace(/\\/g, "/");
const MAX_TIMEOUT_S = 2_000_000; // setTimeout caps at 2^31-1 ms; above that it fires at once

// Seconds. CC default 600, 30 on UserPromptSubmit. Anything not a positive finite number
// falls back to the default; huge values are clamped.
export function timeoutFor(entry) {
  const def = entry?.event === "UserPromptSubmit" ? 30 : 600;
  const t = Number(entry?.timeout);
  if (!Number.isFinite(t) || t <= 0) return def;
  return Math.min(t, MAX_TIMEOUT_S);
}

function substitute(s, pluginRoot) {
  if (typeof s !== "string" || !pluginRoot) return s;
  return s.replaceAll("${CLAUDE_PLUGIN_ROOT}", fwd(pluginRoot));
}

// cmd.exe quoting: every token double-quoted, the whole wrapped once more and passed with /s so
// the outer pair is stripped; verbatim so Node does not re-escape.
function cmdSpawn(file, args) {
  const q = (t) => `"${String(t).replace(/"/g, '""')}"`;
  return { file: process.env.ComSpec || "cmd.exe", args: ["/d", "/s", "/c", `"${[file, ...args].map(q).join(" ")}"`], verbatim: true };
}

const RUNNABLE = [".exe", ".com", ".cmd", ".bat"];

// PATHEXT order from the env that will run the hook, limited to what plan() can spawn.
function extsFor(env) {
  const key = Object.keys(env).find((k) => k.toLowerCase() === "pathext");
  const list = String((key && env[key]) || ".EXE;.CMD;.BAT;.COM").split(";").map((e) => e.trim().toLowerCase()).filter((e) => RUNNABLE.includes(e));
  return list.length ? list : [".exe", ".cmd", ".bat"];
}

function siblingOf(abs, env) {
  if (path.extname(abs)) return null;
  for (const ext of extsFor(env)) if (fs.existsSync(abs + ext)) return abs + ext;
  return null;
}

// R25: a bare name (no path separator) is looked up on PATH x PATHEXT first.
function resolveOnPath(name, env) {
  const key = Object.keys(env).find((k) => k.toLowerCase() === "path");
  const dirs = String(key ? env[key] : "").split(path.delimiter).filter(Boolean);
  const exts = path.extname(name) ? [""] : extsFor(env);
  for (const d of dirs) for (const e of exts) {
    const f = path.join(d, name + e);
    try { if (fs.statSync(f).isFile()) return f; } catch {}
  }
  return null;
}

// D2 (0.12.1): a port of CC 2.1.300's `k3n`, which CC applies to a Windows bash shell-form command
// (`if(mt&&!Ut&&!qt)dn=k3n(dn)`): when the first token, read with quotes and backslash escapes,
// ends in `.sh`, the command becomes `bash <command>`. That is what lets `~/.claude/hooks/x.sh` run
// under a home with a space: a space-free `-c` argument goes on the Windows command line unquoted,
// MSYS expands its leading `~` to the home path before bash starts, and bash then splits it at the
// space (exit 126/127). With the prefix the argument has a space, so it is quoted, and bash does
// the tilde expansion itself, as one word. A space-free command that is not `.sh` (`~/bin/x`) is
// left alone, as CC leaves it (measured: CC's own spawn fails on it the same way).
export function ccWinShellForm(command) {
  const s = String(command ?? "");
  const r = s.trim();
  let tok = "";
  for (let i = 0; i < r.length; ) {
    const c = r[i];
    if (c === '"' || c === "'") {
      const end = r.indexOf(c, i + 1);
      if (end === -1) {
        tok += r.slice(i + 1);
        break;
      }
      tok += r.slice(i + 1, end);
      i = end + 1;
    } else if (c === "\\" && i + 1 < r.length) {
      tok += r[i + 1];
      i += 2;
    } else if (/\s/.test(c)) break;
    else {
      tok += c;
      i++;
    }
  }
  return tok.endsWith(".sh") ? `bash ${s}` : s;
}

// Decide { file, args, verbatim } for an entry (R11 + R25 for exec form on win32).
export function plan(entry, { cwd = process.cwd(), env = process.env } = {}) {
  const root = entry.pluginRoot;
  const command = substitute(entry.command, root);
  if (!Array.isArray(entry.args)) {
    if (entry.shell === "powershell") return { file: "powershell", args: ["-NoProfile", "-Command", command] };
    // R54 m-5: the order differs from CC. Here `${CLAUDE_PLUGIN_ROOT}` is substituted into the text
    // first, then the .sh rewrite reads the result. CC runs k3n on the raw command and lets bash
    // expand the variable from the env. The prefix decision can only differ for an UNQUOTED
    // `${CLAUDE_PLUGIN_ROOT}/x.sh` whose root holds a space, and that fails both ways (bash splits
    // the expanded variable in CC; the first token stops at the space here). Do not rely on this
    // order for anything else.
    return { file: findBash(), args: ["-c", WIN ? ccWinShellForm(command) : command] };
  }
  const args = entry.args.map((a) => substitute(a, root));
  if (!WIN) return { file: command, args };
  const bare = !/[\\/]/.test(command);
  const target = (bare ? resolveOnPath(command, env) : null) ?? siblingOf(path.resolve(cwd, command), env) ?? (bare ? null : command);
  if (!target) return { file: findBash(), args: [command, ...args] };
  const ext = path.extname(target).toLowerCase();
  if (ext === ".exe" || ext === ".com") return { file: target, args };
  if (ext === ".cmd" || ext === ".bat") return cmdSpawn(target, args);
  return { file: findBash(), args: [fwd(command), ...args] }; // extension-less, .sh, anything else
}

// ---- Tree kill -------------------------------------------------------------------------
// taskkill /T follows Windows parent ids, and MSYS (Git Bash) breaks that chain: bin/bash.exe
// re-execs usr/bin/bash.exe, whose children (sh, sleep, python...) hang off an MSYS-side parent.
// So BEFORE killing we snapshot: (1) Win32_Process parent links to find the Windows descendants,
// (2) `ps -W` for MSYS pid/ppid/pgid/winpid. MSYS descendants share their group leader's pgid, so
// every ps row in a group that contains a Windows descendant is swept too.

function capture(cmd, args, ms = 3000) {
  return new Promise((resolve) => {
    let out = "";
    let c;
    try { c = spawn(cmd, args, { stdio: ["ignore", "pipe", "ignore"], windowsHide: true }); } catch { return resolve(""); }
    const t = setTimeout(() => { try { c.kill(); } catch {} resolve(out); }, ms);
    c.stdout.on("data", (d) => (out += d));
    c.on("error", () => { clearTimeout(t); resolve(out); });
    c.on("close", () => { clearTimeout(t); resolve(out); });
  });
}

const SKEW_MS = 1000;

// winTable lines: "<pid> <ppid> <creationEpochMs>". Only processes created at or after the hook's
// spawn (minus skew) can belong to it: a live stranger whose dead parent's PID was reused by the
// hook's bash still names that parent (R27), and is older than the hook. Rows with no creation
// time are treated as old. While the root is alive it is included (exitMs == null).
// R28: once the root has EXITED its PID is free and may belong to a stranger (younger than the
// hook, so no creation check can reject it). Then the root is never killed or walked; only its
// direct children created in [spawn - skew, exitMs] qualify, deeper descendants only through a
// verified member parent, and pgid rows only through a verified member.
export function sweepSet(rootPid, winTable, psTable, spawnMs, exitMs = null) {
  const since = spawnMs - SKEW_MS;
  const created = new Map();
  const kids = new Map();
  for (const l of winTable.split(/\r?\n/)) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/.exec(l);
    if (!m) continue;
    created.set(+m[1], +m[3]);
    if (+m[3] >= since) (kids.get(+m[2]) ?? kids.set(+m[2], []).get(+m[2])).push(+m[1]);
  }
  const fresh = (winpid) => (created.get(winpid) ?? -1) >= since;
  const win = new Set();
  const seed = [];
  if (exitMs == null) {
    win.add(rootPid);
    seed.push(rootPid);
  } else {
    for (const k of kids.get(rootPid) ?? []) if (created.get(k) <= exitMs) { win.add(k); seed.push(k); }
  }
  // R29: a walked child must not be older than its (non-root) parent. One that is older named a
  // dead parent whose PID a hook member later took over, so it is a stranger.
  for (const q = seed; q.length; ) {
    const p = q.shift();
    for (const k of kids.get(p) ?? []) {
      if (win.has(k) || (p !== rootPid && created.get(k) < created.get(p))) continue;
      win.add(k);
      q.push(k);
    }
  }
  const rows = [];
  for (const l of psTable.split(/\r?\n/)) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s/.exec(l);
    if (m && fresh(+m[4])) rows.push({ pid: +m[1], ppid: +m[2], pgid: +m[3], winpid: +m[4] });
  }
  const groups = new Set(rows.filter((r) => win.has(r.winpid) && r.pgid > 1).map((r) => r.pgid));
  const picked = new Set(rows.filter((r) => groups.has(r.pgid)).map((r) => r.pid));
  for (let grew = true; grew; ) {
    grew = false;
    for (const r of rows) if (!picked.has(r.pid) && picked.has(r.ppid)) { picked.add(r.pid); grew = true; }
  }
  for (const r of rows) if (picked.has(r.pid)) win.add(r.winpid);
  for (const self of [process.pid, process.ppid]) win.delete(self);
  if (exitMs != null) win.delete(rootPid);
  return win;
}

// ps.exe only from the Git install that bash.exe lives in; never a cwd-relative path.
function gitPs() {
  const bash = findBash();
  if (!path.isAbsolute(bash)) return null;
  const ps = path.join(path.dirname(bash), "..", "usr", "bin", "ps.exe");
  return fs.existsSync(ps) ? ps : null;
}

const WIN_QUERY = "Get-CimInstance Win32_Process | Where-Object { $_.CreationDate } | ForEach-Object { '{0} {1} {2}' -f $_.ProcessId, $_.ParentProcessId, ([DateTimeOffset]$_.CreationDate).ToUnixTimeMilliseconds() }";

// exitAt() returns the root's exit time (ms) or null. onKill(victims, rootPid) is a test observer.
export async function killTree(child, spawnMs, exitAt = () => null, onKill) {
  if (!WIN) {
    try { if (child.pid) process.kill(-child.pid, "SIGKILL"); } catch {}
    try { child.kill("SIGKILL"); } catch {}
    return;
  }
  const pid = child.pid;
  let tables = null;
  try {
    const ps = gitPs();
    tables = await Promise.all([
      capture(WIN_TOOLS.powershell(), ["-NoProfile", "-Command", WIN_QUERY]),
      ps ? capture(ps, ["-W"]) : Promise.resolve(""),
    ]);
  } catch {}
  // R29: read the exit time AFTER the snapshot, so a root that exited during it counts as exited.
  const exitMs = exitAt();
  let victims = new Set(pid && exitMs == null ? [pid] : []);
  try { if (pid && tables) victims = sweepSet(pid, tables[0], tables[1], spawnMs, exitMs); } catch {}
  try { onKill?.([...victims], pid); } catch {}
  try { child.kill("SIGKILL"); } catch {}
  // No /T: it walks ParentProcessId and so has the same PID-reuse flaw.
  if (victims.size) await capture(WIN_TOOLS.taskkill(), ["/F", ...[...victims].flatMap((p) => ["/PID", String(p)])]);
}

export function runHook(entry, input, opts = {}) {
  const started = Date.now();
  const cwd = opts.cwd ?? process.cwd();
  const env = { ...process.env, ...(opts.env ?? {}), CLAUDE_PROJECT_DIR: opts.projectDir ?? cwd };
  if (entry.pluginRoot) env.CLAUDE_PLUGIN_ROOT = entry.pluginRoot;
  const detached = !!(entry.async || entry.asyncRewake);
  const timeoutS = timeoutFor(entry);
  const base = { status: null, stdout: "", stderr: "", timedOut: false };

  return new Promise((resolve) => {
    let p;
    try {
      p = plan(entry, { cwd, env });
    } catch (e) {
      return resolve({ ...base, durationMs: 0, spawnError: String(e?.message ?? e) });
    }
    let child;
    try {
      child = spawn(p.file, p.args, {
        cwd,
        env,
        stdio: ["pipe", detached ? "ignore" : "pipe", detached ? "ignore" : "pipe"],
        windowsHide: true,
        windowsVerbatimArguments: !!p.verbatim,
        detached: detached || !WIN,
      });
    } catch (e) {
      const res = { ...base, durationMs: Date.now() - started, spawnError: String(e?.message ?? e) };
      if (detached) {
        reportDetached(entry, { ...res, detached: true }, opts);
        return resolve({ ...base, status: 0, detached: true, durationMs: res.durationMs });
      }
      return resolve(res);
    }
    let done = false;
    let killing = false; // set before the kill so the resulting exit/close still counts as a timeout
    let timer;
    let backgrounded = false; // D3: the first stdout line declared the hook async
    let cancelling = false; // R53: cancel() (dispose) is ending a detached hook; not a failure
    const out = [];
    const err = [];
    const text = () => ({ stdout: Buffer.concat(out).toString(), stderr: Buffer.concat(err).toString() });
    const finish = (r) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      const res = { ...base, ...r, ...(killing ? { timedOut: true, status: null } : cancelling ? { cancelled: true, status: null } : {}), durationMs: Date.now() - started };
      if (backgrounded) {
        // The async line was the declaration, not the answer: what follows it is the answer.
        const nl = res.stdout.indexOf("\n");
        reportDetached(entry, { ...res, stdout: nl === -1 ? "" : res.stdout.slice(nl + 1), detached: true, asyncByStdout: true }, opts);
      } else if (detached) reportDetached(entry, res, opts);
      else resolve(res);
    };
    child.on("error", (e) => finish({ ...text(), spawnError: String(e?.message ?? e), detached }));
    child.stdin.on("error", () => {});
    try {
      child.stdin.end(JSON.stringify(input) + "\n");
    } catch {}
    // R28/R29: both paths record the root's exit; killTree reads it after its snapshot.
    let exitMs = null;
    child.on("exit", () => { exitMs = Date.now(); });
    const kill = () => killTree(child, started, () => exitMs, opts.onKill);
    // R53.1: a detached hook's result carries cancel(), which dispose calls for a hook still running
    // at exit, as CC's teardown does (`Qis`: kill, outcome "cancelled"). It goes through the same
    // R23/R27-R29 tree kill, resolves once the kill is done, is idempotent, and reports the outcome
    // as cancelled, never failed. A hook that already finished is left alone.
    let cancelP = null;
    const cancel = () =>
      (cancelP ??= (async () => {
        if (done) return;
        cancelling = true;
        clearTimeout(timer);
        timer = null;
        await kill().catch(() => {});
        try { child.stdout?.destroy(); child.stderr?.destroy(); } catch {}
        finish({ detached: true, ...(backgrounded ? text() : {}) });
      })());
    if (detached) {
      child.unref();
      resolve({ ...base, status: 0, detached: true, durationMs: Date.now() - started, cancel });
      child.on("exit", (code) => finish({ status: code, detached: true }));
      timer = setTimeout(() => {
        killing = true;
        kill().catch(() => {}).then(() => finish({ timedOut: true, detached: true }));
      }, timeoutS * 1000);
      timer.unref?.();
      return;
    }
    // D3 (0.12.1), CC 2.1.300's stdout listener: until checked, the first line of stdout so far,
    // trimmed (`kr(Jr).trim()`, kr = up to the first "\n"), is ignored while it holds no `}`; once it
    // does, it is parsed once, and `{"async":true}` (`"async"in e&&e.async===!0`) backgrounds the hook:
    // the caller gets status 0 at once and the outcome arrives later through onDetached (R26). The
    // pipes stay drained. R53.3: its timeout is cleared then, as CC's `background()` clears it
    // (`this.#C()` -> clearTimeout); it runs until it exits or dispose cancels it. CC only logs
    // `asyncTimeout` (`let q=r.asyncTimeout||15000` feeds a log line and nothing else). A CONFIGURED
    // async hook (above) keeps its R26 timeout.
    let head = "";
    let checked = false;
    child.stdout.on("data", (d) => {
      out.push(d);
      if (checked) return;
      head += d.toString();
      const nl = head.indexOf("\n");
      const first = (nl === -1 ? head : head.slice(0, nl)).trim();
      if (!first.includes("}")) {
        if (nl !== -1) checked = true; // a complete first line without `}` can never qualify
        return;
      }
      checked = true;
      head = "";
      let j;
      try {
        j = JSON.parse(first);
      } catch {
        return;
      }
      if (j === null || typeof j !== "object" || Array.isArray(j) || j.async !== true || done) return;
      backgrounded = true;
      clearTimeout(timer);
      timer = null;
      try { child.unref(); } catch {}
      resolve({ ...base, status: 0, detached: true, asyncByStdout: true, durationMs: Date.now() - started, cancel });
    });
    child.stderr.on("data", (d) => err.push(d));
    child.on("close", (code) => finish({ status: code, ...text() }));
    timer = setTimeout(() => {
      killing = true;
      kill()
        .catch(() => {})
        .then(() => {
          try { child.stdout.destroy(); child.stderr.destroy(); } catch {}
          finish({ timedOut: true, ...text() });
        });
    }, timeoutS * 1000);
  });
}

// R26: a detached hook's eventual outcome. Same failed semantics as interpret(); never throws.
function reportDetached(entry, res, opts) {
  try {
    const failed = res.cancelled ? false : interpret(entry.event, res).failed; // R53.1: cancelled is not failed
    if (typeof opts.onDetached === "function") opts.onDetached({ ...res, failed });
    else if (failed) log(`detached hook failed: ${entry.id ?? entry.command} status=${res.status} timedOut=${res.timedOut} ${res.spawnError ?? ""}`);
  } catch {}
}

export function runAll(entries, input, opts = {}) {
  return Promise.all(entries.map((e) => runHook(e, typeof input === "function" ? input(e) : input, opts)));
}
