import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Corrupt, unreadable or wrong-shaped -> fresh. Never throws.
function readDisk(file) {
  let d;
  try {
    d = JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
  } catch {
    d = undefined;
  }
  if (!isObj(d)) d = {};
  const failures = (Array.isArray(d.failures) ? d.failures : []).filter(
    (f) => isObj(f) && typeof f.id === "string" && typeof f.hookId === "string",
  );
  const obs = isObj(d.observed) ? d.observed : {};
  const strs = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string") : []);
  const args = {};
  if (isObj(obs.args)) for (const [t, names] of Object.entries(obs.args)) if (Array.isArray(names)) args[t] = strs(names);
  return {
    seen: (Array.isArray(d.seen) ? d.seen : []).filter((k) => typeof k === "string"),
    failures,
    versions: isObj(d.versions) ? { ...d.versions } : {},
    observed: { tools: strs(obs.tools), args },
  };
}

function writeAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
    // Windows can refuse a rename while another process has the target open: retry briefly.
    let err;
    for (let i = 0; i < 5; i++) {
      try {
        fs.renameSync(tmp, file);
        return;
      } catch (e) {
        err = e;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 15 * (i + 1)); // brief backoff
      }
    }
    throw err;
  } catch (e) {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      // ignore
    }
    throw e;
  }
}

// Seen-keys, a failure counter, the CC/OC versions and (R2) what OC was observed doing: the
// built-in tool ids from tool.definition and each tool's arg names from tool.execute.before.
// One JSON file. In-memory edits are local until flush(), which RE-READS the file and merges:
// seen and observed are unions (observed args per tool), failures are disk + ours minus
// anything we drained, versions we set override. Concurrent processes therefore don't lose
// each other's keys.
export function stateStore(file) {
  const base = readDisk(file);
  const seen = new Set(base.seen);
  const added = new Set();
  let failures = [...base.failures]; // current local view (undrained)
  const pending = []; // failures added here, not yet on disk
  const drainedIds = new Set();
  const versions = { ...base.versions };
  const versionSets = {};
  const tools = new Set(base.observed.tools);
  const args = new Map(Object.entries(base.observed.args).map(([t, n]) => [t, new Set(n)]));
  let counter = 0;
  const unionArgs = (a, b) => {
    const out = {};
    for (const src of [a, b]) for (const [t, n] of Object.entries(src)) out[t] = [...new Set([...(out[t] ?? []), ...n])];
    return out;
  };
  const argsObj = () => Object.fromEntries([...args].map(([t, n]) => [t, [...n]]));

  return {
    seen: {
      has: (k) => seen.has(k),
      add(k) {
        seen.add(k);
        added.add(k);
      },
    },
    failures: {
      add(hookId, msg) {
        const f = {
          id: `${Date.now().toString(36)}-${process.pid}-${counter++}-${crypto.randomBytes(3).toString("hex")}`,
          hookId: String(hookId),
          msg: String(msg),
          ts: new Date().toISOString(),
        };
        failures.push(f);
        pending.push(f);
      },
      // Non-mutating view, so a caller can report failures and drain only once delivered.
      list() {
        return [...failures];
      },
      drain() {
        const out = failures;
        for (const f of out) drainedIds.add(f.id);
        failures = [];
        pending.length = 0;
        return out;
      },
    },
    versions: {
      get cc() {
        return versions.cc;
      },
      get oc() {
        return versions.oc;
      },
      setCc(v) {
        versions.cc = v;
        versionSets.cc = v;
      },
      setOc(v) {
        versions.oc = v;
        versionSets.oc = v;
      },
    },
    observed: {
      tools: {
        add(id) {
          if (typeof id === "string" && id) tools.add(id);
        },
        list: () => [...tools],
      },
      args: {
        // Replaces this tool's set in memory; flush() unions it with what is on disk.
        set(tool, names) {
          if (typeof tool !== "string" || !Array.isArray(names)) return;
          args.set(tool, new Set(names.filter((n) => typeof n === "string")));
        },
        get: (tool) => (args.has(tool) ? [...args.get(tool)] : undefined),
        all: argsObj,
      },
    },
    flush() {
      try {
        const disk = readDisk(file);
        const mergedSeen = new Set([...disk.seen, ...added]);
        const byId = new Map();
        for (const f of [...disk.failures, ...pending]) if (!drainedIds.has(f.id)) byId.set(f.id, f);
        const mergedFailures = [...byId.values()];
        const mergedVersions = { ...disk.versions, ...versionSets };
        const mergedTools = [...new Set([...disk.observed.tools, ...tools])];
        const mergedArgs = unionArgs(disk.observed.args, argsObj());
        writeAtomic(file, {
          seen: [...mergedSeen],
          failures: mergedFailures,
          versions: mergedVersions,
          observed: { tools: mergedTools, args: mergedArgs },
        });
        // Adopt the merged view; what is on disk is no longer "pending".
        for (const k of mergedSeen) seen.add(k);
        added.clear();
        failures = mergedFailures;
        pending.length = 0;
        Object.assign(versions, mergedVersions);
        for (const t of mergedTools) tools.add(t);
        for (const [t, n] of Object.entries(mergedArgs)) args.set(t, new Set(n));
        return true;
      } catch {
        return false;
      }
    },
  };
}
