import { describe, test, expect } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { stateStore } from "../core/state.js";
import { log } from "../core/log.js";

const tmp = () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "ccp-state-"));
  return { d, f: path.join(d, "sub", "state.json"), done: () => fs.rmSync(d, { recursive: true, force: true }) };
};

describe("stateStore", () => {
  test("missing file -> fresh; adds persist across stores", () => {
    const t = tmp();
    const a = stateStore(t.f);
    expect(a.seen.has("k")).toBe(false);
    a.seen.add("k");
    expect(a.seen.has("k")).toBe(true);
    expect(a.flush()).toBe(true);
    expect(stateStore(t.f).seen.has("k")).toBe(true);
    t.done();
  });

  test("corrupt, empty and wrong-shape files -> fresh, and overwritten cleanly", () => {
    for (const body of ["{not json", "", "[]", "null", '{"seen":"x","failures":5,"versions":7}']) {
      const t = tmp();
      fs.mkdirSync(path.dirname(t.f), { recursive: true });
      fs.writeFileSync(t.f, body);
      const s = stateStore(t.f);
      expect(s.seen.has("anything")).toBe(false);
      expect(s.failures.drain()).toEqual([]);
      expect(s.versions.cc).toBeUndefined();
      s.seen.add("fresh");
      s.flush();
      expect(JSON.parse(fs.readFileSync(t.f, "utf8")).seen).toEqual(["fresh"]);
      t.done();
    }
  });

  test("two stores adding different keys and flushing -> both persist (merge on flush)", () => {
    const t = tmp();
    const a = stateStore(t.f);
    const b = stateStore(t.f); // both loaded before either flushes
    a.seen.add("from-a");
    b.seen.add("from-b");
    a.flush();
    b.flush();
    const c = stateStore(t.f);
    expect(c.seen.has("from-a")).toBe(true);
    expect(c.seen.has("from-b")).toBe(true);
    t.done();
  });

  test("failures: add, drain returns them, then drain is empty (also after flush and reload)", () => {
    const t = tmp();
    const s = stateStore(t.f);
    s.failures.add("h1", "exit 3");
    s.failures.add("h2", "timeout");
    s.flush();
    const r = stateStore(t.f);
    const got = r.failures.drain();
    expect(got.map((x) => [x.hookId, x.msg])).toEqual([["h1", "exit 3"], ["h2", "timeout"]]);
    expect(r.failures.drain()).toEqual([]);
    r.flush();
    expect(stateStore(t.f).failures.drain()).toEqual([]);
    t.done();
  });

  test("a failure drained by one store is not resurrected by another store's flush", () => {
    const t = tmp();
    const a = stateStore(t.f);
    a.failures.add("h1", "x");
    a.flush();
    const b = stateStore(t.f);
    const c = stateStore(t.f);
    expect(b.failures.drain().length).toBe(1);
    b.flush();
    c.flush(); // c still believes the failure is on disk; its flush must not bring it back
    expect(stateStore(t.f).failures.drain()).toEqual([]);
    t.done();
  });

  test("failures added by two stores both survive", () => {
    const t = tmp();
    const a = stateStore(t.f);
    const b = stateStore(t.f);
    a.failures.add("a", "1");
    b.failures.add("b", "2");
    a.flush();
    b.flush();
    expect(stateStore(t.f).failures.drain().map((x) => x.hookId).sort()).toEqual(["a", "b"]);
    t.done();
  });

  test("versions: set, persist, and a store that set nothing keeps the other's value", () => {
    const t = tmp();
    const a = stateStore(t.f);
    const b = stateStore(t.f);
    a.versions.setCc("2.1.0");
    b.versions.setOc("1.19.0");
    a.flush();
    b.flush();
    const c = stateStore(t.f);
    expect(c.versions.cc).toBe("2.1.0");
    expect(c.versions.oc).toBe("1.19.0");
    c.versions.setCc("2.2.0");
    expect(c.versions.cc).toBe("2.2.0");
    c.flush();
    expect(stateStore(t.f).versions.cc).toBe("2.2.0");
    t.done();
  });

  test("atomic write leaves no temp files and creates the directory", () => {
    const t = tmp();
    const s = stateStore(t.f);
    s.seen.add("x");
    s.flush();
    expect(fs.readdirSync(path.dirname(t.f))).toEqual(["state.json"]);
    t.done();
  });

  test("R2 observed.tools: add/list, persisted, union-merged across stores", () => {
    const t = tmp();
    const a = stateStore(t.f);
    expect(a.observed.tools.list()).toEqual([]);
    a.observed.tools.add("bash");
    a.observed.tools.add("bash");
    a.observed.tools.add("read");
    expect(a.observed.tools.list()).toEqual(["bash", "read"]);
    const b = stateStore(t.f); // loaded before a flushes
    b.observed.tools.add("glob");
    a.flush();
    b.flush();
    expect(stateStore(t.f).observed.tools.list().sort()).toEqual(["bash", "glob", "read"]);
    t.done();
  });

  test("R2 observed.args: set/get, a copy is returned, persisted, per-tool union on flush", () => {
    const t = tmp();
    const a = stateStore(t.f);
    expect(a.observed.args.get("read")).toBeUndefined();
    a.observed.args.set("read", ["filePath"]);
    const got = a.observed.args.get("read");
    expect(got).toEqual(["filePath"]);
    got.push("mutated");
    expect(a.observed.args.get("read")).toEqual(["filePath"]);
    const b = stateStore(t.f);
    b.observed.args.set("read", ["filePath", "offset"]);
    b.observed.args.set("bash", ["command"]);
    a.flush();
    b.flush();
    const c = stateStore(t.f);
    expect(c.observed.args.get("read").sort()).toEqual(["filePath", "offset"]);
    expect(c.observed.args.get("bash")).toEqual(["command"]);
    expect(Object.keys(c.observed.args.all()).sort()).toEqual(["bash", "read"]);
    t.done();
  });

  test("R2 observed: wrong-shaped values on disk are dropped, not thrown", () => {
    const t = tmp();
    fs.mkdirSync(path.dirname(t.f), { recursive: true });
    fs.writeFileSync(t.f, JSON.stringify({ observed: { tools: ["ok", 5, null], args: { read: ["filePath", 3], bad: "x" } } }));
    const s = stateStore(t.f);
    expect(s.observed.tools.list()).toEqual(["ok"]);
    expect(s.observed.args.get("read")).toEqual(["filePath"]);
    expect(s.observed.args.get("bad")).toBeUndefined();
    fs.writeFileSync(t.f, JSON.stringify({ observed: "nope" }));
    expect(stateStore(t.f).observed.tools.list()).toEqual([]);
    t.done();
  });

  test("failures.list() peeks without draining", () => {
    const t = tmp();
    const s = stateStore(t.f);
    s.failures.add("h1", "exit 1");
    expect(s.failures.list().map((f) => f.hookId)).toEqual(["h1"]);
    expect(s.failures.list().length).toBe(1);
    expect(s.failures.drain().length).toBe(1);
    expect(s.failures.list()).toEqual([]);
    t.done();
  });

  test("flush never throws (unwritable target) and reports false", () => {
    const t = tmp();
    fs.mkdirSync(t.f, { recursive: true }); // the state "file" is a directory
    const s = stateStore(t.f);
    s.seen.add("x");
    expect(s.flush()).toBe(false);
    t.done();
  });
});

describe("log", () => {
  test("appends timestamped lines to the OC data dir log and never throws", () => {
    const t = tmp();
    const old = process.env.XDG_DATA_HOME;
    process.env.XDG_DATA_HOME = t.d;
    try {
      expect(log("first")).toBe(true);
      log("second");
      const lines = fs.readFileSync(path.join(t.d, "opencode", "cc-parity.log"), "utf8").trim().split("\n");
      expect(lines.length).toBe(2);
      expect(lines[0]).toMatch(/^\d{4}-\d\d-\d\dT[\d:.]+Z first$/);
      expect(lines[1]).toMatch(/ second$/);
      // unwritable: a file where the data dir should be
      process.env.XDG_DATA_HOME = path.join(t.d, "opencode", "cc-parity.log");
      expect(() => log("nope")).not.toThrow();
      expect(log("nope")).toBe(false); // the write failed, and the caller can tell
      // an explicit file argument wins over the env-derived path
      const f = path.join(t.d, "explicit", "x.log");
      expect(log("here", f)).toBe(true);
      expect(fs.readFileSync(f, "utf8")).toMatch(/ here\n$/);
    } finally {
      if (old === undefined) delete process.env.XDG_DATA_HOME;
      else process.env.XDG_DATA_HOME = old;
      t.done();
    }
  });
});
